#!/usr/bin/python3
"""Odoo is loaded on every node and serves on the writable node only
(handbook decision 0059).

A standby refuses every write, and Odoo writes at start and in its cron
jobs: Odoo does not even start in a database that is in recovery. So this
process, which is odoo.service, does the slow part of the start on every
node and the last part on one node only:

- it imports Odoo, and the Python code of every installed module (a read
  of the database, which a standby allows). That is most of the time of a
  start: a start with the modules imported needs 0.7 s, and one without
  them 2.5 s. Then it waits. It holds no listener and it writes to no
  database while it waits;
- every POLL_SECONDS it asks PostgreSQL one read only question: is the
  server out of recovery, and is it open for writes? A standby can answer;
- when the answer is yes, and the first boot hook has finished (the file
  READY), it forks a child that runs Odoo. The imports are already there;
- when the answer is no, it stops the child at once. A fenced or old
  primary is in recovery, so it never serves;
- when the server does not answer, it changes nothing, so a restart of
  PostgreSQL does not take Odoo down.

The first boot hook sets the password of the spec before it writes READY.
The image has the password of a fresh Odoo until then, so a failed hook
leaves Odoo off.
"""
import os
import signal
import sys
import time

READY = "/var/lib/keel-odoo/ready"
ODOO_BIN = "/opt/odoo/18.0/odoo-bin"
CONF = "/etc/odoo/odoo.conf"
DATABASE = "odoo"
POLL_SECONDS = 0.2
CONNECT_TIMEOUT = 2
RESTART_DELAY = 1.0
STOP_WAIT_STEPS = 600
STOP_WAIT_SECONDS = 0.1
QUESTION = "SELECT pg_is_in_recovery(), current_setting('transaction_read_only')"
MODULES = "SELECT name FROM ir_module_module WHERE state = 'installed' ORDER BY name"


def is_writable(in_recovery, read_only):
    """True when the server is out of recovery and is open for writes."""
    return not in_recovery and read_only == "off"


def decide(ready, writable, serving):
    """The action for the state: "start", "stop" or None."""
    if writable is False and serving:
        return "stop"
    if writable is True and not serving and ready:
        return "start"
    return None


def is_ready(path=READY):
    return os.path.exists(path)


def connect():
    """A connection on the unix socket: PostgreSQL authenticates the
    operating system user odoo by peer, so there is no password."""
    import psycopg2
    conn = psycopg2.connect(dbname=DATABASE, connect_timeout=CONNECT_TIMEOUT)
    conn.autocommit = True
    return conn


class Poller:
    """The role of PostgreSQL, asked on one connection."""

    def __init__(self, connect_fn):
        self.connect_fn = connect_fn
        self.conn = None
        self.last_error = ""

    def close(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:  # a connection that is broken cannot say more
                pass
            self.conn = None

    def _say(self, message):
        """Say a problem once, not at every poll. <4> is the syslog level
        "warning"."""
        if message == self.last_error:
            return
        self.last_error = message
        if message:
            print("<4>keel-odoo: PostgreSQL gave no answer: %s" % message, file=sys.stderr, flush=True)

    def writable(self):
        """True on a writable primary, False on a standby or a read only
        server, None if the server is silent."""
        try:
            if self.conn is None:
                self.conn = self.connect_fn()
            cursor = self.conn.cursor()
            cursor.execute(QUESTION)
            row = cursor.fetchone()
            cursor.close()
        except Exception as error:  # any failure means "no answer"
            self._say(str(error) or type(error).__name__)
            self.close()
            return None
        self._say("")
        return is_writable(*row)


def installed_modules(conn):
    """The names of the installed modules: a select, which a standby allows."""
    cursor = conn.cursor()
    cursor.execute(MODULES)
    names = [row[0] for row in cursor.fetchall()]
    cursor.close()
    return names


def import_modules(names, load):
    """Import the code of each module. One that does not import is said and
    left to Odoo, which imports it again at the start and fails there."""
    for name in names:
        try:
            load(name)
        except Exception as error:  # the start of Odoo reports it again
            print("<4>keel-odoo: the module %s did not import: %s" % (name, error), file=sys.stderr, flush=True)


class Supervisor:
    def __init__(self, poller, is_ready, start_child, stop_child, child_alive, clock, warm=None):
        self.poller = poller
        self.is_ready = is_ready
        self.start_child = start_child
        self.stop_child = stop_child
        self.child_alive = child_alive
        self.clock = clock
        self.warm = warm
        self.warmed = False
        self.child = None
        self.not_before = 0.0

    def tick(self):
        if self.child is not None and not self.child_alive(self.child):
            print("<4>keel-odoo: the server ended", file=sys.stderr, flush=True)
            self.child = None
            self.not_before = self.clock() + RESTART_DELAY
        writable = self.poller.writable()
        if not self.warmed and writable is not None:
            # once, when the server first answers
            self.warmed = True
            if self.warm is not None:
                self.warm()
        action = decide(self.is_ready(), writable, self.child is not None)
        if action == "start" and self.clock() >= self.not_before:
            # no connection may be open at the fork
            self.poller.close()
            self.child = self.start_child()
            print("<5>keel-odoo: serving", flush=True)
        elif action == "stop":
            self.stop_all()

    def stop_all(self):
        if self.child is None:
            return
        self.stop_child(self.child)
        self.child = None
        print("<5>keel-odoo: stopped, the node is not writable", flush=True)


def stop_child(pid):
    """SIGTERM, then SIGKILL after STOP_WAIT_STEPS * STOP_WAIT_SECONDS."""
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    for _step in range(STOP_WAIT_STEPS):
        done, _status = os.waitpid(pid, os.WNOHANG)
        if done:
            return
        time.sleep(STOP_WAIT_SECONDS)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)


def child_alive(pid):
    try:
        done, _status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        return False
    return done == 0


def preload():  # pragma: no cover
    """The imports that a start of Odoo makes, made once. odoo-bin finds the
    package because its own directory is first on sys.path."""
    sys.path.insert(0, os.path.dirname(ODOO_BIN))
    import odoo  # noqa: F401
    import odoo.cli  # noqa: F401
    import odoo.http  # noqa: F401
    import odoo.modules.registry  # noqa: F401
    import odoo.service.server  # noqa: F401


def warm_modules():  # pragma: no cover
    """Import the code of the installed modules, as the start of Odoo does
    for its registry (odoo.modules.module.load_openerp_module is a no-op for
    a module that is imported already). It parses the configuration and sets
    the addons path first, as odoo.cli.main does."""
    import odoo
    odoo.tools.config.parse_config(["--config", CONF])
    odoo.modules.module.initialize_sys_path()
    conn = connect()
    try:
        names = installed_modules(conn)
    finally:
        conn.close()
    import_modules(names, odoo.modules.module.load_openerp_module)


def run_odoo():  # pragma: no cover
    """The child: Odoo as odoo-bin runs it. The multi process server starts
    the gevent worker with sys.argv[0], so that is odoo-bin."""
    import odoo
    sys.argv = [ODOO_BIN, "--config", CONF]
    code = 0
    try:
        odoo.cli.main()
    except SystemExit as error:
        code = error.code if isinstance(error.code, int) else 1
    finally:
        os._exit(code)


def fork_odoo():  # pragma: no cover
    pid = os.fork()
    if pid == 0:
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        run_odoo()
    return pid


def main():  # pragma: no cover
    os.environ["TZ"] = "UTC"
    preload()
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    signal.signal(signal.SIGINT, lambda *_: stopping.append(True))
    supervisor = Supervisor(Poller(connect), is_ready, fork_odoo, stop_child, child_alive, time.monotonic,
                            warm_modules)
    print("<5>keel-odoo: loaded, waiting for a writable PostgreSQL", flush=True)
    while not stopping:
        supervisor.tick()
        time.sleep(POLL_SECONDS)
    supervisor.stop_all()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
