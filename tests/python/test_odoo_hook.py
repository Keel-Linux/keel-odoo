"""The first boot hook of the Odoo layer (overlay/usr/lib/inithooks/bin/odoo.py).

The hook sets the password of the admin user and the master password,
renews the secrets that the image shares, and freezes the base URL. Nothing
here needs Odoo, PostgreSQL or passlib to run a real hash: subprocess and
the file system are given by the tests.
"""
import os
import stat
import subprocess

import pytest

HASH = "$pbkdf2-sha512$600000$abcDEF123./$xyz789ABC./"


def test_hash_has_the_form_of_odoos_hash_and_verifies(hook):
    hashed = hook.hash_password("s3cret pass")
    assert hook.HASH_RE.match(hashed)
    _, scheme, rounds, salt, digest = hashed.split("$")
    assert (scheme, rounds) == ("pbkdf2-sha512", "600000")
    # verify it again with hashlib: passlib's alphabet is base64 with "." for "+"
    import base64
    import hashlib

    def unab64(text):
        return base64.b64decode(text.replace(".", "+") + "=" * (-len(text) % 4))

    again = hashlib.pbkdf2_hmac("sha512", b"s3cret pass", unab64(salt), 600000)
    assert unab64(digest) == again


def test_two_hashes_of_one_password_differ_by_salt(hook):
    assert hook.hash_password("same") != hook.hash_password("same")


def test_hash_is_what_passlib_accepts(hook):
    passlib = pytest.importorskip("passlib.context")
    hashed = hook.hash_password("s3cret pass")
    assert passlib.CryptContext(["pbkdf2_sha512"]).verify("s3cret pass", hashed)


def test_hash_refuses_an_empty_password(hook):
    with pytest.raises(hook.HookError, match="empty"):
        hook.hash_password("")


@pytest.mark.parametrize("value", [None, "", "DEFAULT", "default"])
def test_placeholder_values_count_as_not_given(hook, value):
    assert hook.given(value) is None


def test_a_given_value_is_kept(hook):
    assert hook.given("odoo.example.org") == "odoo.example.org"


@pytest.mark.parametrize("domain,url", [
    ("odoo.example.org", "https://odoo.example.org"),
    ("odoo.example.org:8443", "https://odoo.example.org:8443"),
    ("[2001:db8::1]", "https://[2001:db8::1]"),
])
def test_base_url_from_a_good_domain(hook, domain, url):
    assert hook.base_url(domain) == url


@pytest.mark.parametrize("domain", [
    "a b", "x'; drop table res_users;--", "https://odoo.example.org", "-bad.example", "ex/ample",
])
def test_base_url_refuses_a_bad_domain(hook, domain):
    with pytest.raises(hook.HookError, match="domain"):
        hook.base_url(domain)


def test_parse_args_takes_pass_and_domain(hook):
    assert hook.parse_args(["--pass=abc", "--domain=odoo.example.org"]) == ("abc", "odoo.example.org")


def test_parse_args_defaults_to_nothing(hook):
    assert hook.parse_args([]) == (None, None)


def test_parse_args_help_and_unknown_option_exit_1(hook, capsys):
    for argv in (["--help"], ["--nope"]):
        with pytest.raises(SystemExit) as exit_info:
            hook.parse_args(argv)
        assert exit_info.value.code == 1
    assert "Syntax" in capsys.readouterr().err


def test_set_option_replaces_the_line(hook):
    text = "[options]\ndb_name = odoo\nadmin_passwd =\nproxy_mode = True\n"
    assert hook.set_option(text, "admin_passwd", HASH) == (
        "[options]\ndb_name = odoo\nadmin_passwd = " + HASH + "\nproxy_mode = True\n")


def test_set_option_appends_a_missing_key(hook):
    assert hook.set_option("[options]\ndb_name = odoo\n", "admin_passwd", HASH).endswith(
        "admin_passwd = " + HASH + "\n")


def test_set_option_appends_to_a_file_without_final_newline(hook):
    assert hook.set_option("[options]\ndb_name = odoo", "k", "v") == "[options]\ndb_name = odoo\nk = v\n"


def test_set_option_does_not_touch_a_commented_key(hook):
    text = "[options]\n# admin_passwd = old\nadmin_passwd =\n"
    assert hook.set_option(text, "admin_passwd", "new") == "[options]\n# admin_passwd = old\nadmin_passwd = new\n"


def test_write_conf_keeps_mode_and_owner(hook, tmp_path):
    path = tmp_path / "odoo.conf"
    path.write_text("old\n")
    os.chmod(path, 0o640)
    hook.write_conf(str(path), "new\n")
    assert path.read_text() == "new\n"
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o640
    assert os.stat(path).st_uid == os.getuid()
    assert [p.name for p in tmp_path.iterdir()] == ["odoo.conf"]


def test_write_conf_creates_the_new_file_with_the_final_mode(hook, tmp_path, monkeypatch):
    path = tmp_path / "odoo.conf"
    path.write_text("old\n")
    os.chmod(path, 0o640)
    modes = []
    real_fchmod = os.fchmod
    monkeypatch.setattr(hook.os, "fchmod", lambda fd, mode: (modes.append(stat.S_IMODE(os.fstat(fd).st_mode)), real_fchmod(fd, mode)))
    hook.write_conf(str(path), "new\n")
    assert modes == [0o640]


def test_write_conf_removes_its_temporary_file_on_failure(hook, tmp_path, monkeypatch):
    path = tmp_path / "odoo.conf"
    path.write_text("old\n")

    def fail(fd, uid, gid):
        raise PermissionError("no")

    monkeypatch.setattr(hook.os, "fchown", fail)
    with pytest.raises(PermissionError):
        hook.write_conf(str(path), "new\n")
    assert path.read_text() == "old\n"
    assert [p.name for p in tmp_path.iterdir()] == ["odoo.conf"]


def test_script_sets_hash_secrets_attachments_and_url(hook):
    script = hook.sql_script(HASH, "https://odoo.example.org")
    assert "\\set pw '" + HASH + "'" in script
    assert "\\set url 'https://odoo.example.org'" in script
    assert "UPDATE res_users SET password = :'pw' WHERE login = 'admin';" in script
    assert "gen_random_uuid()" in script
    assert "'database.secret'" in script and "'database.uuid'" in script
    assert "'ir_attachment.location'" in script and "'db'" in script
    assert "'web.base.url.freeze'" in script


def test_a_later_run_keeps_the_secrets(hook):
    script = hook.sql_script(HASH, None, first=False)
    assert "gen_random_uuid" not in script
    assert "UPDATE res_users SET password" in script


def test_script_without_a_domain_leaves_the_url_alone(hook):
    script = hook.sql_script(HASH, None)
    assert "web.base.url" not in script


def test_script_refuses_a_hash_that_is_not_a_hash(hook):
    with pytest.raises(hook.HookError, match="hash"):
        hook.sql_script("x'; drop table res_users; --", None)


def test_script_refuses_a_url_with_a_quote(hook):
    with pytest.raises(hook.HookError, match="URL"):
        hook.sql_script(HASH, "https://a'b")


def test_run_psql_runs_as_the_odoo_user_with_the_script_on_stdin(hook, monkeypatch):
    seen = {}

    def fake_run(argv, **kwargs):
        seen.update(argv=argv, **kwargs)
        return subprocess.CompletedProcess(argv, 0, stdout="1\n", stderr="")

    monkeypatch.setattr(hook.subprocess, "run", fake_run)
    out = hook.run_psql("select 1;")
    assert out == "1\n"
    assert seen["argv"][:4] == ["runuser", "-u", "odoo", "--"]
    assert "ON_ERROR_STOP=1" in seen["argv"]
    assert seen["input"] == "select 1;"
    assert HASH not in " ".join(seen["argv"])


def test_run_psql_reports_the_error(hook, monkeypatch):
    def fake_run(argv, **kwargs):
        raise subprocess.CalledProcessError(3, argv, output="", stderr="FATAL: no database")

    monkeypatch.setattr(hook.subprocess, "run", fake_run)
    with pytest.raises(hook.HookError, match="FATAL: no database"):
        hook.run_psql("select 1;")


def test_read_password_prefers_the_given_one(hook):
    assert hook.read_password("abc", interactive=False) == "abc"


def test_read_password_takes_the_environment_next(hook, monkeypatch):
    monkeypatch.setenv("APP_PASS", "from the environment")
    assert hook.read_password(None, interactive=False) == "from the environment"
    assert hook.read_password("DEFAULT", interactive=False) == "from the environment"
    assert hook.read_password("given", interactive=False) == "given"


def test_read_password_headless_without_a_password_fails_clearly(hook, monkeypatch):
    monkeypatch.delenv("APP_PASS", raising=False)
    with pytest.raises(hook.HookError, match="APP_PASS"):
        hook.read_password(None, interactive=False)
    with pytest.raises(hook.HookError, match="APP_PASS"):
        hook.read_password("DEFAULT", interactive=False)


def test_read_password_asks_on_a_console(hook, monkeypatch):
    monkeypatch.delenv("APP_PASS", raising=False)
    asked = {}

    class Dialog:
        def __init__(self, title):
            asked["title"] = title

        def get_password(self, title, text, blacklist=()):
            asked["blacklist"] = blacklist
            return "typed"

    monkeypatch.setattr(hook, "load_dialog", lambda: Dialog)
    assert hook.read_password(None, interactive=True) == "typed"
    assert "Keel Linux" in asked["title"]


def test_load_dialog_names_the_inithooks_class(hook, monkeypatch):
    import sys
    import types
    fake = types.ModuleType("libinithooks.dialog_wrapper")
    fake.Dialog = object
    monkeypatch.setitem(sys.modules, "libinithooks", types.ModuleType("libinithooks"))
    monkeypatch.setitem(sys.modules, "libinithooks.dialog_wrapper", fake)
    assert hook.load_dialog() is object


def _hook_environment(hook, monkeypatch, tmp_path, recovery="f\n", check="1\n"):
    conf = tmp_path / "odoo.conf"
    conf.write_text("[options]\nadmin_passwd =\n")
    ready = tmp_path / "state" / "ready"
    calls = []

    def fake_run_psql(script):
        calls.append(script)
        if "pg_is_in_recovery" in script:
            return recovery
        return check if "SELECT count(*)" in script else ""

    monkeypatch.setattr(hook, "CONF", str(conf))
    monkeypatch.setattr(hook, "READY", str(ready))
    monkeypatch.setattr(hook, "run_psql", fake_run_psql)
    monkeypatch.setattr(hook, "hash_password", lambda password: HASH)
    monkeypatch.delenv("APP_PASS", raising=False)
    return conf, ready, calls


def test_main_runs_the_statements_writes_the_conf_and_marks_the_end(hook, monkeypatch, tmp_path):
    conf, ready, calls = _hook_environment(hook, monkeypatch, tmp_path)
    assert hook.main(["--pass=abc", "--domain=odoo.example.org"], interactive=False) == 0
    assert len(calls) == 3
    assert "pg_is_in_recovery" in calls[0]
    assert "web.base.url" in calls[1] and "gen_random_uuid" in calls[1]
    assert "FROM res_users" in calls[2]
    assert conf.read_text() == "[options]\nadmin_passwd = " + HASH + "\n"
    assert ready.exists()


def test_main_takes_the_password_from_the_environment(hook, monkeypatch, tmp_path):
    conf, ready, calls = _hook_environment(hook, monkeypatch, tmp_path)
    monkeypatch.setenv("APP_PASS", "from the environment")
    assert hook.main(["--domain=odoo.example.org"], interactive=False) == 0
    assert ready.exists()


def test_a_second_run_keeps_the_secrets_that_the_first_renewed(hook, monkeypatch, tmp_path):
    conf, ready, calls = _hook_environment(hook, monkeypatch, tmp_path)
    assert hook.main(["--pass=abc"], interactive=False) == 0
    assert hook.main(["--pass=abc"], interactive=False) == 0
    assert "gen_random_uuid" in calls[1]
    assert "gen_random_uuid" not in calls[4]


def test_a_standby_gets_the_master_password_and_no_sql(hook, monkeypatch, tmp_path, capsys):
    conf, ready, calls = _hook_environment(hook, monkeypatch, tmp_path, recovery="t\n")
    assert hook.main(["--pass=abc"], interactive=False) == 0
    assert len(calls) == 1
    assert "standby" in capsys.readouterr().out
    assert conf.read_text() == "[options]\nadmin_passwd = " + HASH + "\n"
    assert ready.exists()


def test_main_fails_when_the_admin_row_did_not_take_the_hash(hook, monkeypatch, tmp_path, capsys):
    conf, ready, calls = _hook_environment(hook, monkeypatch, tmp_path, check="0\n")
    assert hook.main(["--pass=abc"], interactive=False) == 1
    assert "admin user" in capsys.readouterr().err
    assert conf.read_text() == "[options]\nadmin_passwd =\n"
    assert not ready.exists()


def test_mark_ready_makes_the_directory(hook, monkeypatch, tmp_path):
    monkeypatch.setattr(hook, "READY", str(tmp_path / "a" / "b" / "ready"))
    hook.mark_ready()
    assert (tmp_path / "a" / "b" / "ready").read_text().startswith("the first boot hook")


def test_main_reports_a_headless_run_without_a_password(hook, capsys, monkeypatch):
    monkeypatch.delenv("APP_PASS", raising=False)
    assert hook.main([], interactive=False) == 1
    assert "APP_PASS" in capsys.readouterr().err


def test_entry_point_uses_the_terminal_test(hook, monkeypatch):
    monkeypatch.setattr(hook.sys.stdin, "isatty", lambda: False)
    monkeypatch.setattr(hook, "main", lambda argv, interactive: (argv, interactive))
    assert hook.run(["--pass=x"]) == (["--pass=x"], False)
