"""overlay/usr/lib/keel-odoo/follow.py: Odoo runs on the node whose PostgreSQL
accepts writes, and on no other node (a standby refuses every write)."""
import subprocess

import pytest


@pytest.mark.parametrize("ready,writable,active,action", [
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
def test_decide(follow, ready, writable, active, action):
    assert follow.decide(ready, writable, active) == action


def test_ready_when_the_file_is_there(follow, tmp_path):
    flag = tmp_path / "ready"
    assert follow.is_ready(str(flag)) is False
    flag.write_text("done\n")
    assert follow.is_ready(str(flag)) is True


def test_report_says_a_problem_once(follow, tmp_path, capsys):
    path = str(tmp_path / "last")
    follow.report("PostgreSQL is down", path)
    follow.report("PostgreSQL is down", path)
    assert capsys.readouterr().err == "<4>keel-odoo-follow: PostgreSQL is down\n"
    follow.report("PostgreSQL is slow", path)
    assert "slow" in capsys.readouterr().err


def test_report_with_no_message_clears_the_last_problem(follow, tmp_path, capsys):
    path = str(tmp_path / "last")
    follow.report("", path)
    assert not (tmp_path / "last").exists()
    follow.report("down", path)
    capsys.readouterr()
    follow.report("", path)
    assert capsys.readouterr().err == ""
    follow.report("down", path)
    assert "down" in capsys.readouterr().err


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


def test_writable_is_unknown_when_the_server_does_not_answer(follow, monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(follow, "LAST_ERROR", str(tmp_path / "last"))
    monkeypatch.setattr(follow.subprocess, "run", _run(2, "", "could not connect"))
    assert follow.pg_writable() is None
    assert "could not connect" in capsys.readouterr().err
    monkeypatch.setattr(follow.subprocess, "run", _run(0, "garbage\n"))
    assert follow.pg_writable() is None
    assert "garbage" in capsys.readouterr().err
    monkeypatch.setattr(follow.subprocess, "run", _run(1, "", ""))
    assert follow.pg_writable() is None
    assert "nothing" in capsys.readouterr().err


def test_a_good_answer_clears_the_problem(follow, monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(follow, "LAST_ERROR", str(tmp_path / "last"))
    monkeypatch.setattr(follow.subprocess, "run", _run(2, "", "down"))
    follow.pg_writable()
    capsys.readouterr()
    monkeypatch.setattr(follow.subprocess, "run", _run(0, "f\n"))
    assert follow.pg_writable() is True
    monkeypatch.setattr(follow.subprocess, "run", _run(2, "", "down"))
    follow.pg_writable()
    assert "down" in capsys.readouterr().err


def test_writable_is_unknown_when_psql_times_out(follow, monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(follow, "LAST_ERROR", str(tmp_path / "last"))

    def fake(argv, **kwargs):
        raise subprocess.TimeoutExpired(argv, 5)
    monkeypatch.setattr(follow.subprocess, "run", fake)
    assert follow.pg_writable() is None
    assert "did not answer" in capsys.readouterr().err


def test_active_asks_systemd(follow, monkeypatch):
    monkeypatch.setattr(follow.subprocess, "run", _run(0))
    assert follow.odoo_active() is True
    monkeypatch.setattr(follow.subprocess, "run", _run(3))
    assert follow.odoo_active() is False


def test_main_starts_odoo_on_a_writable_node(follow, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(follow, "is_ready", lambda path=None: True)
    monkeypatch.setattr(follow, "pg_writable", lambda: True)
    monkeypatch.setattr(follow, "odoo_active", lambda: False)
    monkeypatch.setattr(follow.subprocess, "run", lambda argv, **kw: calls.append(argv) or subprocess.CompletedProcess(argv, 0))
    assert follow.main() == 0
    assert calls == [["systemctl", "start", "--no-block", "odoo.service"]]
    assert "start" in capsys.readouterr().out


def test_main_stops_odoo_on_a_standby(follow, monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(follow, "is_ready", lambda path=None: True)
    monkeypatch.setattr(follow, "pg_writable", lambda: False)
    monkeypatch.setattr(follow, "odoo_active", lambda: True)
    monkeypatch.setattr(follow.subprocess, "run", lambda argv, **kw: calls.append(argv) or subprocess.CompletedProcess(argv, 0))
    assert follow.main() == 0
    assert calls == [["systemctl", "stop", "odoo.service"]]
    assert "stop" in capsys.readouterr().out


def test_main_does_nothing_when_nothing_changes(follow, monkeypatch, capsys):
    monkeypatch.setattr(follow, "is_ready", lambda path=None: True)
    monkeypatch.setattr(follow, "pg_writable", lambda: True)
    monkeypatch.setattr(follow, "odoo_active", lambda: True)
    monkeypatch.setattr(follow.subprocess, "run", lambda *a, **k: pytest.fail("systemctl must not run"))
    assert follow.main() == 0
    assert capsys.readouterr().out == ""


def test_main_fails_when_systemctl_fails(follow, monkeypatch, capsys):
    monkeypatch.setattr(follow, "is_ready", lambda path=None: True)
    monkeypatch.setattr(follow, "pg_writable", lambda: True)
    monkeypatch.setattr(follow, "odoo_active", lambda: False)
    monkeypatch.setattr(follow.subprocess, "run", lambda argv, **kw: subprocess.CompletedProcess(argv, 1))
    assert follow.main() == 1
