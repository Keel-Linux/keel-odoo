#!/usr/bin/env bats
# The first boot hook firstboot.d/45odoo (decision 0004), run for real
# against scratch directories. bin/odoo.py and systemctl are PATH stubs that
# record how they were called; the Python of odoo.py has its own tests
# (tests/python). Nothing here needs root, Odoo or a database.
#
# Whether anybody can answer the console is inithooks' rule (lib/console.sh,
# as for 35pgsqlpass): tty1 of an LXC container is a terminal nobody is
# attached to, so a test of standard input for a terminal is not enough.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$BATS_TEST_DIRNAME/.."
    HOOK="$ROOT/overlay/usr/lib/inithooks/firstboot.d/45odoo"
    scratch="$BATS_TEST_TMPDIR/hook"
    mkdir -p "$scratch/bin" "$scratch/inithooks/bin" "$scratch/inithooks/lib"
    # lib/console.sh is inithooks'. This stand-in has its two functions:
    # INITHOOKS_UNATTENDED says whether anybody can answer the console, and
    # a deferred question is one line in the log and in the record of
    # keel-init.
    cat > "$scratch/inithooks/lib/console.sh" <<'CON'
console_unattended() { [[ "${INITHOOKS_UNATTENDED:-no}" != "no" ]]; }
console_deferred() { echo "INFO: [$1] not asked, nobody can answer ($INITHOOKS_UNATTENDED): $2" >&2; echo "$1" >> "$DEFERRED"; }
CON
    cat > "$scratch/inithooks/bin/odoo.py" <<'PY'
#!/bin/sh
echo "odoo.py $* APP_PASS=${APP_PASS-unset}" >> "$CALLS"
exit "${ODOO_PY_STATUS:-0}"
PY
    chmod +x "$scratch/inithooks/bin/odoo.py"
    printf '#!/bin/sh\necho "systemctl $*" >> "$CALLS"\n' > "$scratch/bin/systemctl"
    chmod +x "$scratch/bin/systemctl"
    PATH="$scratch/bin:$PATH"

    export INITHOOKS_DEFAULT="$scratch/default-inithooks"
    export INITHOOKS_CONF="$scratch/inithooks.conf"
    export CALLS="$scratch/calls"
    export DEFERRED="$scratch/deferred"
    # a console with an operator at it, unless a test says otherwise
    export INITHOOKS_UNATTENDED=no
    cat > "$INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=$INITHOOKS_CONF
INITHOOKS_PATH=$scratch/inithooks
DEF
}

@test "a declared password and domain go to odoo.py, the password in the environment" {
    printf 'export APP_PASS=s3cret-of-the-description\nexport APP_DOMAIN=odoo.example.org\n' > "$INITHOOKS_CONF"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$CALLS")" = "odoo.py --domain=odoo.example.org APP_PASS=s3cret-of-the-description" ]
    [ "$(sed -n 2p "$CALLS")" = "systemctl try-restart odoo.service" ]
    [ ! -f "$DEFERRED" ]
}

@test "a headless first boot with no password asks nothing and leaves the question to keel-init" {
    # BR1 and BR2, 2026-11-06: nobody is attached to tty1 of an LXC
    printf 'export APP_DOMAIN=odoo.example.org\n' > "$INITHOOKS_CONF"
    export INITHOOKS_UNATTENDED="the console has no size, nobody is attached to it"
    run "$HOOK" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"[45odoo] not asked, nobody can answer"* ]]
    [[ "$output" == *"keel-init asks it"* ]]
    [ "$(cat "$DEFERRED")" = 45odoo ]
    [ ! -f "$CALLS" ]
}

@test "the inithooks placeholder DEFAULT is no password" {
    printf 'export APP_PASS=DEFAULT\n' > "$INITHOOKS_CONF"
    export INITHOOKS_UNATTENDED="there is no terminal"
    run "$HOOK" < /dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$DEFERRED")" = 45odoo ]
    [ ! -f "$CALLS" ]
}

@test "at a console with no password (keel-init), odoo.py asks it, and no domain is no option value" {
    # under keel-init the inithooks conf is empty
    rm -f "$INITHOOKS_CONF"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(head -1 "$CALLS")" = "odoo.py --domain= APP_PASS=unset" ]
    [ ! -f "$DEFERRED" ]
}

@test "a failure of odoo.py fails the hook, and Odoo is not restarted" {
    printf 'export APP_PASS=s3cret\n' > "$INITHOOKS_CONF"
    export ODOO_PY_STATUS=1
    run "$HOOK"
    [ "$status" -eq 1 ]
    run ! grep -q systemctl "$CALLS"
}
