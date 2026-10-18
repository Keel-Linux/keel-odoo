"""overlay/usr/lib/keel-odoo/follow.py: Odoo runs on the node whose PostgreSQL
accepts writes, and on no other node (a standby refuses every write)."""
import subprocess

import pytest


@pytest.mark.parametrize("firstboot,writable,active,action", [
    (False, True, False, "start"),
    (False, True, True, None),
    (False, False, True, "stop"),
    (False, False, False, None),
    (False, None, True, None),
    (False, None, False, None),
    (True, True, False, None),
    (True, False, True, "stop"),
    (True, True, True, None),
])
def test_decide(follow, firstboot, writable, active, action):
    assert follow.decide(firstboot, writable, active) == action


def test_firstboot_is_running_while_the_flag_is_true(follow, tmp_path):
    flag = tmp_path / "inithooks"
    flag.write_text("RUN_FIRSTBOOT=true\n")
    assert follow.firstboot_running(str(flag)) is True
    flag.write_text("RUN_FIRSTBOOT=false\n")
    assert follow.firstboot_running(str(flag)) is False


def test_firstboot_is_not_running_without_the_file(follow, tmp_path):
    assert follow.firstboot_running(str(tmp_path / "none")) is False


def _run(returncode, out="", err=""):
    def fake(argv, **kwargs):
        fake.argv = argv
        fake.kwargs = kwargs
        return subprocess.CompletedProcess(argv, returncode, stdout=out, stderr=err)
    return fake


def test_writable_reads_pg_is_in_recovery(follow, monkeypatch):
    fake = _run(0, "f\n")
    monkeypatch.setattr(follow.subprocess, "run", fake)
    assert follow.pg_writable() is True
    # the child runs as odoo with no PAM session, and the server sees a peer
    assert fake.kwargs["user"] == "odoo" and fake.kwargs["group"] == "odoo"
    assert fake.argv[0] == "psql"
    monkeypatch.setattr(follow.subprocess, "run", _run(0, "t\n"))
    assert follow.pg_writable() is False


def test_writable_is_unknown_when_the_server_does_not_answer(follow, monkeypatch):
    monkeypatch.setattr(follow.subprocess, "run", _run(2, "", "could not connect"))
    assert follow.pg_writable() is None
    monkeypatch.setattr(follow.subprocess, "run", _run(0, "garbage\n"))
    assert follow.pg_writable() is None


def test_writable_is_unknown_when_psql_times_out(follow, monkeypatch):
    def fake(argv, **kwargs):
        raise subprocess.TimeoutExpired(argv, 5)
    monkeypatch.setattr(follow.subprocess, "run", fake)
    assert follow.pg_writable() is None


def test_active_asks_systemd(follow, monkeypatch):
    monkeypatch.setattr(follow.subprocess, "run", _run(0))
    assert follow.odoo_active() is True
    monkeypatch.setattr(follow.subprocess, "run", _run(3))
    assert follow.odoo_active() is False


def test_main_starts_odoo_on_a_writable_node(follow, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(follow, "firstboot_running", lambda path=None: False)
    monkeypatch.setattr(follow, "pg_writable", lambda: True)
    monkeypatch.setattr(follow, "odoo_active", lambda: False)
    monkeypatch.setattr(follow.subprocess, "run", lambda argv, **kw: calls.append(argv) or subprocess.CompletedProcess(argv, 0))
    assert follow.main() == 0
    assert calls == [["systemctl", "start", "--no-block", "odoo.service"]]
    assert "start" in capsys.readouterr().out


def test_main_stops_odoo_on_a_standby(follow, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(follow, "firstboot_running", lambda path=None: False)
    monkeypatch.setattr(follow, "pg_writable", lambda: False)
    monkeypatch.setattr(follow, "odoo_active", lambda: True)
    monkeypatch.setattr(follow.subprocess, "run", lambda argv, **kw: calls.append(argv) or subprocess.CompletedProcess(argv, 0))
    assert follow.main() == 0
    assert calls == [["systemctl", "stop", "odoo.service"]]
    assert "stop" in capsys.readouterr().out


def test_main_does_nothing_when_nothing_changes(follow, monkeypatch, capsys):
    monkeypatch.setattr(follow, "firstboot_running", lambda path=None: False)
    monkeypatch.setattr(follow, "pg_writable", lambda: True)
    monkeypatch.setattr(follow, "odoo_active", lambda: True)
    monkeypatch.setattr(follow.subprocess, "run", lambda *a, **k: pytest.fail("systemctl must not run"))
    assert follow.main() == 0
    assert capsys.readouterr().out == ""


def test_main_fails_when_systemctl_fails(follow, monkeypatch, capsys):
    monkeypatch.setattr(follow, "firstboot_running", lambda path=None: False)
    monkeypatch.setattr(follow, "pg_writable", lambda: True)
    monkeypatch.setattr(follow, "odoo_active", lambda: False)
    monkeypatch.setattr(follow.subprocess, "run", lambda argv, **kw: subprocess.CompletedProcess(argv, 1))
    assert follow.main() == 1
