#!/usr/bin/python3
"""Odoo follows the writable PostgreSQL (handbook decision 0059).

A standby refuses every write, and Odoo writes at start and in its cron
jobs. So Odoo runs on the node whose PostgreSQL accepts writes, and on no
other node. keel-odoo-follow.timer runs this script every few seconds:

- writable and Odoo stopped: start Odoo;
- in recovery and Odoo running: stop Odoo;
- the server does not answer: change nothing, so a restart of PostgreSQL
  does not take Odoo down;
- the first boot hook has not finished (no file READY): do not start Odoo.
  The image has the password of a fresh Odoo until the hook sets the
  password of the spec, so a failed hook leaves Odoo off.

This script is the only supervisor of odoo.service, so the unit is not a
process of the appliance manifest (Monit would start it on a standby).
"""
import os
import subprocess
import sys

READY = "/var/lib/keel-odoo/ready"
LAST_ERROR = "/run/keel-odoo-follow.error"
SERVICE = "odoo.service"
PSQL_TIMEOUT = 5


def decide(ready, writable, active):
    """The action for the state: "start", "stop" or None."""
    if writable is False and active:
        return "stop"
    if writable is True and not active and ready:
        return "start"
    return None


def is_ready(path=READY):
    return os.path.exists(path)


def report(message, path=None):
    """Say a problem once, not every 3 seconds: <4> is the syslog level
    "warning". An empty message clears the last one."""
    path = path or LAST_ERROR
    try:
        with open(path) as handle:
            last = handle.read()
    except FileNotFoundError:
        last = ""
    if message == last:
        return
    with open(path, "w") as handle:
        handle.write(message)
    if message:
        print("<4>keel-odoo-follow: %s" % message, file=sys.stderr)


def pg_writable():
    """True on a primary, False on a standby, None if the server is silent."""
    argv = ["psql", "-X", "-At", "-d", "odoo", "-c", "SELECT pg_is_in_recovery()"]
    # user= changes the user of the child with no PAM session, so the journal
    # gets no "session opened" lines every few seconds. PostgreSQL
    # authenticates the user odoo by peer on the unix socket.
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=PSQL_TIMEOUT,
                                user="odoo", group="odoo")
    except subprocess.TimeoutExpired:
        report("PostgreSQL did not answer in %d s" % PSQL_TIMEOUT)
        return None
    answer = result.stdout.strip()
    if result.returncode != 0 or answer not in ("t", "f"):
        report("PostgreSQL gave no answer to the odoo user: %s" % (result.stderr.strip() or answer or "nothing"))
        return None
    report("")
    return answer == "f"


def odoo_active():
    return subprocess.run(["systemctl", "is-active", "--quiet", SERVICE]).returncode == 0


def main():
    action = decide(is_ready(), pg_writable(), odoo_active())
    if action is None:
        return 0
    argv = ["systemctl", action, SERVICE]
    if action == "start":
        argv.insert(2, "--no-block")
    # <5> is the syslog level "notice", which LogLevelMax=notice of the unit keeps
    print("<5>keel-odoo-follow: %s %s" % (action, SERVICE))
    return 0 if subprocess.run(argv).returncode == 0 else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
