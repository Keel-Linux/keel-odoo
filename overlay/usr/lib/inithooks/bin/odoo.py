#!/usr/bin/python3
"""Set the Odoo admin password, the master password and the base URL

Options:
    --pass=      the password of the admin user and the master password;
                 unless given, the variable APP_PASS, else ask on the
                 console (a headless first boot must give it:
                 secrets.app_password of the spec, rendered to APP_PASS)
    --domain=    the domain of the site; sets and freezes web.base.url

The hook also renews the secrets that every image shares (database.secret
and database.uuid) and makes sure that attachments are stored in the
database, so a failover of the pair keeps them (handbook decision 0059).
Odoo is not running while the first boot hooks run.
"""

import base64
import getopt
import hashlib
import os
import re
import subprocess
import sys

CONF = "/etc/odoo/odoo.conf"
# The file that tells keel-odoo-follow.timer that the first boot hook has
# finished: until it exists, Odoo does not start, so a failed hook never
# leaves Odoo running with the password of the image.
READY = "/var/lib/keel-odoo/ready"
DATABASE = "odoo"
SERVICE_USER = "odoo"
# Odoo 18: odoo/tools/config.py, crypt_context
PBKDF2_ROUNDS = 600_000
HASH_RE = re.compile(r"^\$pbkdf2-sha512\$[0-9]+\$[A-Za-z0-9./]+\$[A-Za-z0-9./]+$")
DOMAIN_RE = re.compile(
    r"^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?$")


class HookError(Exception):
    """A failure that the hook reports on stderr and ends with exit 1."""


def usage(message=None):
    if message:
        print("Error:", message, file=sys.stderr)
    print("Syntax: %s [options]" % sys.argv[0], file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(1)


def parse_args(argv):
    try:
        opts, _ = getopt.gnu_getopt(argv, "h", ["help", "pass=", "domain="])
    except getopt.GetoptError as error:
        usage(error)
    password = None
    domain = None
    for opt, val in opts:
        if opt in ("-h", "--help"):
            usage()
        elif opt == "--pass":
            password = val
        else:
            domain = val
    return password, domain


def given(value):
    """The value, or None for an empty one or the inithooks placeholder."""
    if not value or value.upper() == "DEFAULT":
        return None
    return value


def ab64(data):
    """passlib's alphabet: base64 with "." for "+", and no padding."""
    return base64.b64encode(data).decode().rstrip("=").replace("+", ".")


def hash_password(password):
    """The hash that Odoo 18 stores, in passlib's format: PBKDF2-SHA512,
    600000 rounds, a random salt. hashlib makes it, so the hook needs no
    other library, and Odoo's passlib verifies it."""
    if not password:
        raise HookError("the password is empty")
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha512", password.encode(), salt, PBKDF2_ROUNDS)
    return "$pbkdf2-sha512$%d$%s$%s" % (PBKDF2_ROUNDS, ab64(salt), ab64(digest))


def base_url(domain):
    if not DOMAIN_RE.match(domain):
        raise HookError("%r is not a domain name or an address with an optional port" % domain)
    return "https://" + domain


def set_option(text, key, value):
    """Set key in the [options] text: replace its line, or add one."""
    line = "%s = %s" % (key, value)
    pattern = re.compile(r"^%s\s*=.*$" % re.escape(key), re.MULTILINE)
    if pattern.search(text):
        return pattern.sub(lambda _: line, text, count=1)
    if text and not text.endswith("\n"):
        text += "\n"
    return text + line + "\n"


def write_conf(path, text):
    """Replace the file in one step, with its mode and owner. The new file
    has its final mode from the start."""
    info = os.stat(path)
    temporary = path + ".new"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, info.st_mode & 0o7777)
    try:
        os.fchmod(descriptor, info.st_mode & 0o7777)
        os.fchown(descriptor, info.st_uid, info.st_gid)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(text)
    except BaseException:
        os.unlink(temporary)
        raise
    os.replace(temporary, path)


def sql_script(password_hash, url, first=True):
    """The statements of the hook. The hash and the URL are checked before
    they go into the text, and psql quotes them as literals. With first
    false (a later run of the hook) the secrets are kept."""
    if not HASH_RE.match(password_hash):
        raise HookError("the password hash does not have the form of Odoo's hash")
    if url is not None and ("'" in url or "\\" in url or "\n" in url):
        raise HookError("the URL has a character that a SQL literal cannot hold")
    lines = ["\\set pw '%s'" % password_hash]
    lines.append("UPDATE res_users SET password = :'pw' WHERE login = 'admin';")
    if first:
        # every image has the same secrets: renewed once, at the first run
        lines.append(
            "UPDATE ir_config_parameter SET value = gen_random_uuid()::text, write_date = now() "
            "WHERE key IN ('database.secret', 'database.uuid');")
    parameters = [("ir_attachment.location", "'db'")]
    if url is not None:
        lines.insert(1, "\\set url '%s'" % url)
        parameters += [("web.base.url", ":'url'"), ("web.base.url.freeze", "'True'")]
    for key, value in parameters:
        lines.append(
            "INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date) "
            "VALUES ('%s', %s, 1, 1, now(), now()) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, write_date = now();" % (key, value))
    return "\n".join(lines) + "\n"


def run_psql(script):
    """Run the script as the odoo user: PostgreSQL authenticates the user by
    peer on the unix socket, so no password is used. The script goes to
    stdin, so the hash is not in the process list."""
    argv = ["runuser", "-u", SERVICE_USER, "--", "psql", "-X", "-q", "-At",
            "-v", "ON_ERROR_STOP=1", "-d", DATABASE]
    try:
        result = subprocess.run(argv, input=script, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as error:
        raise HookError("psql failed: %s" % (error.stderr or "").strip()) from error
    return result.stdout


def load_dialog():
    from libinithooks.dialog_wrapper import Dialog
    return Dialog


def read_password(password, interactive):
    password = given(password) or given(os.environ.get("APP_PASS"))
    if password:
        return password
    if not interactive:
        raise HookError(
            "no password: set secrets.app_password in the spec (it renders to APP_PASS), "
            "or run this hook on a console")
    dialog = load_dialog()("Keel Linux - First boot configuration")
    return dialog.get_password(
        "Odoo password",
        "Enter the password for the Odoo 'admin' user. It is also the master password.",
        blacklist=["\\", "/"])


def in_recovery():
    """True on a standby: it takes no write, and the primary has the rows."""
    return run_psql("SELECT pg_is_in_recovery();").strip() == "t"


def mark_ready():
    os.makedirs(os.path.dirname(READY), mode=0o755, exist_ok=True)
    with open(READY, "w") as handle:
        handle.write("the first boot hook of Odoo has finished\n")


def main(argv, interactive):
    try:
        password, domain = parse_args(argv)
        password = read_password(password, interactive)
        domain = given(domain)
        url = base_url(domain) if domain else None
        password_hash = hash_password(password)
        if in_recovery():
            print("odoo: PostgreSQL is a standby: the database is the primary's; only the master password is set")
        else:
            run_psql(sql_script(password_hash, url, first=not os.path.exists(READY)))
            # The row must hold the hash: UPDATE says nothing when no row matches.
            check = "\\set pw '%s'\nSELECT count(*) FROM res_users WHERE login = 'admin' AND password = :'pw';\n" % password_hash
            if run_psql(check).strip() != "1":
                raise HookError("the admin user of the %s database does not hold the new password" % DATABASE)
        with open(CONF) as handle:
            text = handle.read()
        write_conf(CONF, set_option(text, "admin_passwd", password_hash))
        mark_ready()
    except HookError as error:
        print("odoo: %s" % error, file=sys.stderr)
        return 1
    return 0


def run(argv):
    return main(argv, interactive=sys.stdin.isatty())


if __name__ == "__main__":  # pragma: no cover
    sys.exit(run(sys.argv[1:]))
