#!/usr/bin/python3
"""Odoo follows the writable PostgreSQL (handbook decision 0059).

A standby refuses every write, and Odoo writes at start and in its cron
jobs. So Odoo runs on the node whose PostgreSQL accepts writes, and on no
other node. keel-odoo-follow.timer runs this script every few seconds:

- writable and Odoo stopped: start Odoo;
- in recovery and Odoo running: stop Odoo;
- the server does not answer: change nothing, so a restart of PostgreSQL
  does not take Odoo down;
- the first boot is still running: do not start Odoo, because the first
  boot hooks change the database that Odoo would load.

This script is the only supervisor of odoo.service, so the unit is not a
process of the appliance manifest (Monit would start it on a standby).
"""
import subprocess
import sys

INITHOOKS_DEFAULT = "/etc/default/inithooks"
SERVICE = "odoo.service"
PSQL_TIMEOUT = 5


def decide(firstboot, writable, active):
    """The action for the state: "start", "stop" or None."""
    if writable is False and active:
        return "stop"
    if writable is True and not active and not firstboot:
        return "start"
    return None


def firstboot_running(path=INITHOOKS_DEFAULT):
    try:
        with open(path) as handle:
            return any(line.strip() == "RUN_FIRSTBOOT=true" for line in handle)
    except FileNotFoundError:
        return False


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
        return None
    answer = result.stdout.strip()
    if result.returncode != 0 or answer not in ("t", "f"):
        return None
    return answer == "f"


def odoo_active():
    return subprocess.run(["systemctl", "is-active", "--quiet", SERVICE]).returncode == 0


def main():
    action = decide(firstboot_running(), pg_writable(), odoo_active())
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
