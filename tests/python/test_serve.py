"""overlay/usr/lib/keel-odoo/serve.py: Odoo is loaded on every node and serves
on the node whose PostgreSQL accepts writes, and on no other node (a standby
refuses every write)."""
import pytest


@pytest.mark.parametrize("ready,writable,serving,action", [
    (True, True, False, "start"),
    (True, True, True, None),
    (True, False, True, "stop"),
    (True, False, False, None),
    (True, None, True, None),
    (True, None, False, None),
    (False, True, False, None),
    (False, False, True, "stop"),
    (False, True, True, None),
])
def test_decide(serve, ready, writable, serving, action):
    assert serve.decide(ready, writable, serving) == action


@pytest.mark.parametrize("row,writable", [
    ((False, "off"), True),
    ((True, "off"), False),
    ((False, "on"), False),
    ((True, "on"), False),
])
def test_a_node_is_writable_only_outside_recovery_and_not_read_only(serve, row, writable):
    assert serve.is_writable(*row) is writable


class FakeCursor:
    def __init__(self, conn):
        self.conn = conn

    def execute(self, sql):
        self.conn.queries.append(sql)
        if self.conn.error:
            raise self.conn.error

    def fetchone(self):
        return self.conn.row

    def close(self):
        pass


class FakeConnection:
    def __init__(self, row=(False, "off"), error=None):
        self.row, self.error, self.queries, self.closed = row, error, [], False

    def cursor(self):
        return FakeCursor(self)

    def close(self):
        self.closed = True


def test_the_poller_asks_one_read_only_question_on_one_connection(serve):
    conns = []

    def connect():
        conns.append(FakeConnection((False, "off")))
        return conns[-1]
    poller = serve.Poller(connect)
    assert poller.writable() is True
    assert poller.writable() is True
    assert len(conns) == 1
    assert len(conns[0].queries) == 2
    assert "pg_is_in_recovery()" in conns[0].queries[0]
    assert "transaction_read_only" in conns[0].queries[0]
    for word in ("INSERT", "UPDATE", "CREATE", "DELETE"):
        assert word not in conns[0].queries[0].upper()


def test_the_poller_says_unknown_when_the_server_does_not_answer(serve, capsys):
    def connect():
        raise OSError("no socket")
    poller = serve.Poller(connect)
    assert poller.writable() is None
    assert poller.writable() is None
    # said once, not at every poll
    assert capsys.readouterr().err.count("no socket") == 1


def test_the_poller_drops_a_broken_connection_and_asks_again(serve, capsys):
    broken = FakeConnection(error=RuntimeError("server closed the connection"))
    good = FakeConnection((True, "off"))
    queue = [broken, good]
    poller = serve.Poller(lambda: queue.pop(0))
    assert poller.writable() is None
    assert broken.closed
    assert poller.writable() is False
    assert "server closed" in capsys.readouterr().err


def test_a_good_answer_clears_the_problem(serve, capsys):
    good = FakeConnection((False, "off"))
    queue = [FakeConnection(error=RuntimeError("down")), good]
    poller = serve.Poller(lambda: queue.pop(0))
    poller.writable()
    poller.writable()
    good.error = RuntimeError("down")
    poller.writable()
    assert capsys.readouterr().err.count("down") == 2


def test_close_with_no_connection_is_safe(serve):
    serve.Poller(lambda: None).close()


class World:
    """A fake machine: the state of the node, and the child that serves."""

    def __init__(self, serve):
        self.serve = serve
        self.ready = True
        self.writable = False
        self.alive = False
        self.now = 100.0
        self.started = 0
        self.stopped = 0
        self.closed = 0

    def supervisor(self):
        outer = self

        class Poller:
            def writable(self):
                return outer.writable

            def close(self):
                outer.closed += 1
        return self.serve.Supervisor(
            poller=Poller(),
            is_ready=lambda: outer.ready,
            start_child=outer.start,
            stop_child=outer.stop,
            child_alive=lambda child: outer.alive,
            clock=lambda: outer.now,
        )

    def start(self):
        self.started += 1
        self.alive = True
        return 4242

    def stop(self, child):
        assert child == 4242
        self.stopped += 1
        self.alive = False


def test_a_standby_waits_and_never_starts_the_server(serve):
    world = World(serve)
    sup = world.supervisor()
    for _ in range(5):
        sup.tick()
    assert world.started == 0


def test_the_server_starts_when_the_node_becomes_writable(serve):
    world = World(serve)
    sup = world.supervisor()
    sup.tick()
    world.writable = True
    sup.tick()
    assert world.started == 1
    # the poll connection is closed before the fork
    assert world.closed == 1
    sup.tick()
    assert world.started == 1


def test_nothing_starts_before_the_first_boot_hook_has_finished(serve):
    world = World(serve)
    world.ready = False
    world.writable = True
    sup = world.supervisor()
    sup.tick()
    assert world.started == 0
    world.ready = True
    sup.tick()
    assert world.started == 1


def test_a_demoted_node_stops_serving_at_the_next_tick(serve):
    world = World(serve)
    world.writable = True
    sup = world.supervisor()
    sup.tick()
    assert world.alive
    world.writable = False
    sup.tick()
    assert world.stopped == 1 and not world.alive
    world.writable = None
    sup.tick()
    world.writable = False
    sup.tick()
    assert world.started == 1 and world.stopped == 1


def test_a_silent_server_changes_nothing(serve):
    world = World(serve)
    world.writable = True
    sup = world.supervisor()
    sup.tick()
    world.writable = None
    sup.tick()
    assert world.alive and world.stopped == 0


def test_a_fenced_old_primary_comes_back_in_recovery_and_stays_off(serve):
    world = World(serve)
    world.writable = True
    sup = world.supervisor()
    sup.tick()
    world.writable = False
    sup.tick()
    for _ in range(10):
        world.now += 1
        sup.tick()
    assert world.started == 1


def test_a_child_that_died_is_started_again_after_a_pause(serve):
    world = World(serve)
    world.writable = True
    sup = world.supervisor()
    sup.tick()
    world.alive = False
    sup.tick()
    assert world.started == 1
    world.now += serve.RESTART_DELAY + 0.1
    sup.tick()
    assert world.started == 2


def test_stop_all_stops_the_child_and_forgets_it(serve):
    world = World(serve)
    world.writable = True
    sup = world.supervisor()
    sup.tick()
    sup.stop_all()
    assert world.stopped == 1
    sup.stop_all()
    assert world.stopped == 1


def test_is_ready_when_the_file_is_there(serve, tmp_path):
    flag = tmp_path / "ready"
    assert serve.is_ready(str(flag)) is False
    flag.write_text("done\n")
    assert serve.is_ready(str(flag)) is True


def test_stop_child_sends_term_and_waits(serve, monkeypatch):
    calls = []
    monkeypatch.setattr(serve.os, "kill", lambda pid, sig: calls.append(("kill", pid, sig)))
    monkeypatch.setattr(serve.os, "waitpid", lambda pid, flags: calls.append(("wait", pid, flags)) or (pid, 0))
    serve.stop_child(77)
    assert calls == [("kill", 77, serve.signal.SIGTERM), ("wait", 77, serve.os.WNOHANG)]


def test_stop_child_kills_a_child_that_ignores_term(serve, monkeypatch):
    calls = []
    results = iter([(0, 0), (0, 0), (77, 0)])
    monkeypatch.setattr(serve.os, "kill", lambda pid, sig: calls.append(sig))
    monkeypatch.setattr(serve.os, "waitpid", lambda pid, flags: next(results))
    monkeypatch.setattr(serve.time, "sleep", lambda s: None)
    monkeypatch.setattr(serve, "STOP_WAIT_STEPS", 2)
    serve.stop_child(77)
    assert calls == [serve.signal.SIGTERM, serve.signal.SIGKILL]


def test_stop_child_ignores_a_child_that_is_gone(serve, monkeypatch):
    def gone(pid, sig):
        raise ProcessLookupError
    monkeypatch.setattr(serve.os, "kill", gone)
    serve.stop_child(77)


def test_child_alive_reaps_a_dead_child(serve, monkeypatch):
    monkeypatch.setattr(serve.os, "waitpid", lambda pid, flags: (0, 0))
    assert serve.child_alive(5) is True
    monkeypatch.setattr(serve.os, "waitpid", lambda pid, flags: (5, 0))
    assert serve.child_alive(5) is False

    def none(pid, flags):
        raise ChildProcessError
    monkeypatch.setattr(serve.os, "waitpid", none)
    assert serve.child_alive(5) is False


def test_connect_uses_the_unix_socket_and_the_odoo_database(serve, monkeypatch):
    seen = {}

    class Conn:
        autocommit = False

    class Psycopg2:
        @staticmethod
        def connect(**kwargs):
            seen.update(kwargs)
            return Conn()
    monkeypatch.setitem(__import__("sys").modules, "psycopg2", Psycopg2)
    conn = serve.connect()
    assert conn.autocommit is True
    assert seen["dbname"] == "odoo"
    assert "host" not in seen and "password" not in seen
    assert seen["connect_timeout"] == serve.CONNECT_TIMEOUT


def test_close_survives_a_connection_that_cannot_close(serve):
    class Broken(FakeConnection):
        def close(self):
            raise RuntimeError("already gone")
    poller = serve.Poller(lambda: Broken())
    poller.writable()
    poller.close()
    assert poller.conn is None


class WarmWorld(World):
    """The world, with a warm step that counts its calls."""

    def __init__(self, serve):
        super().__init__(serve)
        self.warmed = 0

    def supervisor(self):
        sup = super().supervisor()
        sup.warm = self.warm
        return sup

    def warm(self):
        self.warmed += 1


def test_the_modules_are_loaded_once_when_the_server_first_answers(serve):
    world = WarmWorld(serve)
    world.writable = None
    sup = world.supervisor()
    sup.tick()
    sup.tick()
    assert world.warmed == 0
    world.writable = False
    sup.tick()
    sup.tick()
    assert world.warmed == 1


def test_the_warm_step_comes_before_the_first_start(serve):
    world = WarmWorld(serve)
    world.writable = True
    sup = world.supervisor()
    order = []
    sup.warm = lambda: order.append("warm")
    sup.start_child = lambda: order.append("start") or 4242
    sup.tick()
    assert order == ["warm", "start"]


def test_installed_modules_reads_the_names_with_one_select(serve):
    conn = FakeConnection(row=None)
    conn.rows = [("base",), ("web",)]
    conn_cursor = conn.cursor

    class Cursor(FakeCursor):
        def fetchall(self):
            return conn.rows
    conn.cursor = lambda: Cursor(conn)
    assert serve.installed_modules(conn) == ["base", "web"]
    assert "ir_module_module" in conn.queries[0]
    assert "installed" in conn.queries[0]
    for word in ("INSERT", "UPDATE", "CREATE", "DELETE"):
        assert word not in conn.queries[0].upper()
    assert conn_cursor


def test_import_modules_goes_on_after_a_module_that_does_not_import(serve, capsys):
    seen = []

    def load(name):
        if name == "bad":
            raise ImportError("no such thing")
        seen.append(name)
    serve.import_modules(["base", "bad", "web"], load)
    assert seen == ["base", "web"]
    assert "bad" in capsys.readouterr().err


class HttpWorld(World):
    """The world, with a warm request that answers as the script says."""

    def __init__(self, serve):
        super().__init__(serve)
        self.answers = []
        self.requests = 0

    def supervisor(self):
        sup = super().supervisor()
        sup.warm_http = self.warm_http
        return sup

    def warm_http(self):
        self.requests += 1
        return self.answers.pop(0) if self.answers else True


def test_the_first_requests_after_a_start_warm_the_workers(serve):
    world = HttpWorld(serve)
    world.writable = True
    sup = world.supervisor()
    sup.tick()
    assert world.requests == 1
    for _ in range(10):
        sup.tick()
    # WARM_REQUESTS answers in all, and no more
    assert world.requests == serve.WARM_REQUESTS


def test_a_warm_request_that_fails_does_not_count(serve):
    world = HttpWorld(serve)
    world.writable = True
    world.answers = [False, False, True]
    sup = world.supervisor()
    for _ in range(3 + serve.WARM_REQUESTS):
        sup.tick()
    assert world.requests == 3 + serve.WARM_REQUESTS - 1


def test_the_warm_requests_stop_after_the_time_limit(serve):
    world = HttpWorld(serve)
    world.writable = True
    world.answers = [False] * 1000
    sup = world.supervisor()
    sup.tick()
    world.now += serve.WARM_SECONDS + 1
    before = world.requests
    sup.tick()
    sup.tick()
    assert world.requests == before


def test_no_warm_request_goes_to_a_node_that_does_not_serve(serve):
    world = HttpWorld(serve)
    world.writable = False
    sup = world.supervisor()
    for _ in range(5):
        sup.tick()
    assert world.requests == 0


def test_a_new_start_warms_again(serve):
    world = HttpWorld(serve)
    world.writable = True
    sup = world.supervisor()
    for _ in range(serve.WARM_REQUESTS + 2):
        sup.tick()
    first = world.requests
    world.writable = False
    sup.tick()
    world.writable = True
    sup.tick()
    assert world.requests == first + 1


def test_warm_http_asks_the_login_page_on_the_loopback(serve, monkeypatch):
    seen = {}

    class Response:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake(url, timeout):
        seen["url"], seen["timeout"] = url, timeout
        return Response()
    monkeypatch.setattr(serve.urllib.request, "urlopen", fake)
    assert serve.warm_http() is True
    assert seen["url"] == "http://127.0.0.1:8069/web/login"
    assert seen["timeout"] == serve.WARM_TIMEOUT


def test_warm_http_is_false_when_nothing_answers(serve, monkeypatch):
    def fake(url, timeout):
        raise OSError("refused")
    monkeypatch.setattr(serve.urllib.request, "urlopen", fake)
    assert serve.warm_http() is False
