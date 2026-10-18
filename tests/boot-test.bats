#!/usr/bin/env bats
# Unit tests of tests/lib/boot-test-lib.sh: argument parsing, address
# discovery from lxc-info, waiting with a deadline, the secret files, the
# database, Webmin and module verdicts, and the diff verdict. Nothing here
# needs root, a network, a database or LXC: lxc-info is a stub first in
# PATH, the clock and sleep are functions.

bats_require_minimum_version 1.5.0

setup() {
    load lib/boot-test-lib.sh
    STUBS=$(mktemp -d)
    PATH=$STUBS:$PATH
}

teardown() {
    rm -rf "$STUBS"
}

stub_lxc_info() {
    # stub_lxc_info OUTPUT: lxc-info prints OUTPUT and records its arguments
    printf '#!/bin/bash\necho "$*" >> "%s/lxc-info.calls"\ncat <<"OUT"\n%s\nOUT\n' "$STUBS" "$1" > "$STUBS/lxc-info"
    chmod +x "$STUBS/lxc-info"
}

# argument parsing

@test "parse_args: the appliance alone takes every default" {
    bt_parse_args odoo
    [ "$BT_APPLIANCE" = odoo ]
    [ "$BT_TIMEOUT" = 900 ]
    [ "$BT_INTERVAL" = 5 ]
    [ "$BT_BRIDGE" = br0 ]
    [ "$BT_LAYERS_DIR" = /mnt/builds/layers ]
    [ "$BT_CACHE_DIR" = /var/cache/keel/layers ]
    [ "$BT_LXC_PATH" = /var/lib/lxc ]
    [ -z "$BT_SPEC" ]
    [ "$BT_KEEP" = 0 ]
    [ "$BT_NAME" = keel-odoo-boot-test ]
    [ "$BT_ROOTFS" = /var/lib/lxc/keel-odoo-boot-test/rootfs ]
}

@test "parse_args: every option is read" {
    bt_parse_args --timeout 60 --interval 2 --bridge lxcbr0 --layers-dir /l \
        --cache-dir /c --lxc-path /x --name lamp-run-7 --spec /s.yaml --keep lamp
    [ "$BT_APPLIANCE" = lamp ]
    [ "$BT_TIMEOUT" = 60 ]
    [ "$BT_INTERVAL" = 2 ]
    [ "$BT_BRIDGE" = lxcbr0 ]
    [ "$BT_LAYERS_DIR" = /l ]
    [ "$BT_CACHE_DIR" = /c ]
    [ "$BT_LXC_PATH" = /x ]
    [ "$BT_SPEC" = /s.yaml ]
    [ "$BT_KEEP" = 1 ]
    [ "$BT_NAME" = lamp-run-7 ]
    [ "$BT_ROOTFS" = /x/lamp-run-7/rootfs ]
}

@test "parse_args: --name is checked as a container name" {
    run bt_parse_args odoo --name "Run 7"
    [ "$status" -eq 1 ]
    [[ $output == *"is not a container name"* ]]
    run bt_parse_args odoo --name -lead
    [ "$status" -eq 1 ]
}

@test "is_container_name" {
    bt_is_container_name keel-odoo-ci-36255612491-1
    bt_is_container_name 7
    run ! bt_is_container_name "keel core"
    run ! bt_is_container_name -x
    run ! bt_is_container_name ""
}

@test "parse_args: the appliance is required" {
    run bt_parse_args --keep
    [ "$status" -eq 1 ]
    [[ $output == *"APPLIANCE is required"* ]]
}

@test "parse_args: one appliance at a time" {
    run bt_parse_args odoo lamp
    [ "$status" -eq 1 ]
    [[ $output == *"one appliance at a time"* ]]
}

@test "parse_args: the keel- prefix and upper case are rejected" {
    run bt_parse_args keel-postgresql
    [ "$status" -eq 1 ]
    [[ $output == *"not an appliance name"* ]]
    run bt_parse_args NodeBB
    [ "$status" -eq 1 ]
}

@test "parse_args: an unknown option fails" {
    run bt_parse_args odoo --verbose
    [ "$status" -eq 1 ]
    [[ $output == *"unknown option --verbose"* ]]
}

@test "parse_args: timeout and interval must be positive integers" {
    run bt_parse_args odoo --timeout 0
    [ "$status" -eq 1 ]
    [[ $output == *"--timeout needs a positive number"* ]]
    run bt_parse_args odoo --interval abc
    [ "$status" -eq 1 ]
    run bt_parse_args odoo --timeout
    [ "$status" -eq 1 ]
}

@test "parse_args: an option with a value refuses an empty one" {
    run bt_parse_args odoo --bridge
    [ "$status" -eq 1 ]
    [[ $output == *"--bridge needs a value"* ]]
    run bt_parse_args odoo --spec ""
    [ "$status" -eq 1 ]
}

@test "parse_args: --help prints the usage and returns 2" {
    run bt_parse_args --help
    [ "$status" -eq 2 ]
    [[ ${lines[0]} == "usage: tests/boot-test.sh APPLIANCE"* ]]
    [[ $output == *"--keep"* ]]
    run bt_parse_args -h
    [ "$status" -eq 2 ]
}

@test "is_positive_int and is_appliance_name" {
    bt_is_positive_int 1
    bt_is_positive_int 900
    run ! bt_is_positive_int 0
    run ! bt_is_positive_int 07
    run ! bt_is_positive_int -5
    run ! bt_is_positive_int ""
    bt_is_appliance_name nginx-php-fastcgi
    run ! bt_is_appliance_name keel-core
    run ! bt_is_appliance_name 9core
    run ! bt_is_appliance_name ""
}

# address discovery

@test "is_global_ipv6: global and ULA yes, link local, loopback, multicast, IPv4 no" {
    bt_is_global_ipv6 2001:db8:1::10
    bt_is_global_ipv6 fd00:1::10
    bt_is_global_ipv6 2001:DB8::1
    run ! bt_is_global_ipv6 fe80::216:3eff:fe00:1
    run ! bt_is_global_ipv6 FEBF::1
    run ! bt_is_global_ipv6 ::1
    run ! bt_is_global_ipv6 ff02::1
    run ! bt_is_global_ipv6 192.0.2.10
    run ! bt_is_global_ipv6 ""
}

@test "global_ipv6: picks the first global address out of lxc-info output" {
    output=$(printf 'IP:             fe80::216:3eff:fe00:1\nIP:             192.0.2.10\nIP:             2001:db8:1::10\nIP:             2001:db8:1::11\n' | bt_global_ipv6)
    [ "$output" = 2001:db8:1::10 ]
}

@test "global_ipv6: ignores lines that are not addresses" {
    output=$(printf 'Name:           keel-odoo-boot-test\nState:          RUNNING\nPID:            4242\nIP:             fd00::10\nLink:           veth0\n' | bt_global_ipv6)
    [ "$output" = fd00::10 ]
}

@test "global_ipv6: returns 1 while only link local or IPv4 addresses exist" {
    run bt_global_ipv6 <<< $'IP:             fe80::1\nIP:             192.0.2.10'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run bt_global_ipv6 < /dev/null
    [ "$status" -eq 1 ]
}

@test "container_ipv6: calls lxc-info with the lxcpath and the name" {
    stub_lxc_info $'Name:           keel-odoo-boot-test\nIP:             fe80::1\nIP:             2001:db8:1::10'
    output=$(bt_container_ipv6 keel-odoo-boot-test /var/lib/lxc)
    [ "$output" = 2001:db8:1::10 ]
    [ "$(cat "$STUBS/lxc-info.calls")" = "-P /var/lib/lxc -n keel-odoo-boot-test -i" ]
}

@test "container_ipv6: fails when lxc-info has no global address yet" {
    stub_lxc_info $'Name:           keel-odoo-boot-test\nState:          RUNNING'
    run bt_container_ipv6 keel-odoo-boot-test /var/lib/lxc
    [ "$status" -eq 1 ]
}

# timeouts

fake_clock() { echo "$FAKE_NOW"; }
fake_sleep() { FAKE_NOW=$(( FAKE_NOW + $1 )); echo "sleep $1" >> "$STUBS/sleeps"; }
succeed_on_third() { CALLS=$(( CALLS + 1 )); [ "$CALLS" -ge 3 ]; }
never() { return 1; }

@test "deadline_passed" {
    run ! bt_deadline_passed 100 30 129
    bt_deadline_passed 100 30 130
    bt_deadline_passed 100 30 500
}

@test "now: the default clock is epoch seconds and BT_CLOCK replaces it" {
    [[ $(bt_now) =~ ^[0-9]{10}$ ]]
    BT_CLOCK=fake_clock FAKE_NOW=42
    [ "$(bt_now)" = 42 ]
}

@test "wait_for: polls at the interval until the command succeeds" {
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000 CALLS=0
    bt_wait_for 60 5 "three calls" succeed_on_third
    [ "$CALLS" -eq 3 ]
    [ "$(cat "$STUBS/sleeps")" = $'sleep 5\nsleep 5' ]
}

@test "wait_for: gives up with a message once the timeout has passed" {
    # shellcheck disable=SC2034  # read by bt_now and bt_wait_for
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000
    run bt_wait_for 12 5 "something that never happens" never
    [ "$status" -eq 1 ]
    [[ $output == *"timeout after 12s waiting for something that never happens"* ]]
    [ "$(wc -l < "$STUBS/sleeps")" -eq 3 ]
}

# readiness and verdicts

@test "is_ssh_banner" {
    bt_is_ssh_banner "SSH-2.0-OpenSSH_10.0p2 Debian-7"
    run ! bt_is_ssh_banner "HTTP/1.1 400 Bad Request"
    run ! bt_is_ssh_banner ""
}

@test "firstboot_done_in: RUN_FIRSTBOOT=false in the rootfs copy of /etc/default/inithooks" {
    printf 'INITHOOKS_CONF=/etc/inithooks.conf\nRUN_FIRSTBOOT=false\n' > "$STUBS/done"
    printf 'RUN_FIRSTBOOT=true\n' > "$STUBS/pending"
    bt_firstboot_done_in "$STUBS/done"
    run ! bt_firstboot_done_in "$STUBS/pending"
    run ! bt_firstboot_done_in "$STUBS/missing"
}

@test "lxc_config: names the container, the rootfs and the bridge" {
    output=$(bt_lxc_config keel-odoo-boot-test /var/lib/lxc/keel-odoo-boot-test/rootfs br0)
    [[ $output == *"lxc.uts.name = keel-odoo-boot-test"* ]]
    [[ $output == *"lxc.rootfs.path = dir:/var/lib/lxc/keel-odoo-boot-test/rootfs"* ]]
    [[ $output == *"lxc.net.0.link = br0"* ]]
    [[ $output == *"lxc.net.0.type = veth"* ]]
}

@test "lxc_config: the apparmor pair a container running systemd needs" {
    output=$(bt_lxc_config keel-odoo-boot-test /r/rootfs br0)
    [[ $output == *"lxc.apparmor.profile = generated"* ]]
    [[ $output == *"lxc.apparmor.allow_nesting = 1"* ]]
}

fake_rootfs() {
    # fake_rootfs [VALUE]: a scratch rootfs with an inithooks defaults file,
    # REDIRECT_OUTPUT set to VALUE (default false), printed on stdout
    local rootfs="$BATS_TEST_TMPDIR/rootfs-$RANDOM"
    mkdir -p "$rootfs/etc/default"
    cat > "$rootfs/$BT_INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=/etc/inithooks.conf
RUN_FIRSTBOOT=true
REDIRECT_OUTPUT=${1-false}
SUDOADMIN=false
DEF
    printf '%s\n' "$rootfs"
}

@test "mark_container: writes the marker the unit conditions and inspect read" {
    rootfs=$(fake_rootfs)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    [ -f "$rootfs/var/lib/turnkey-info/inithooks.service/lxc" ]
}

@test "mark_container: turns REDIRECT_OUTPUT on, so no hook blocks writing to tty1" {
    rootfs=$(fake_rootfs false)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    grep -q '^REDIRECT_OUTPUT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT"
    # the rest of the file is left alone
    grep -q '^RUN_FIRSTBOOT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT"
    grep -q '^SUDOADMIN=false$' "$rootfs/$BT_INITHOOKS_DEFAULT"
}

@test "mark_container: takes the first boot off tty1 with a systemd drop-in" {
    rootfs=$(fake_rootfs)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    dropin="$rootfs/$BT_INITHOOKS_DROPIN"
    [ -f "$dropin" ]
    grep -q '^\[Service\]$' "$dropin"
    grep -q '^StandardOutput=journal$' "$dropin"
    grep -q '^StandardError=journal$' "$dropin"
}

@test "mark_container: a tree that already redirects is left redirecting" {
    rootfs=$(fake_rootfs true)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^REDIRECT_OUTPUT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT")" -eq 1 ]
}

@test "mark_container: a rootfs with no inithooks defaults fails loudly" {
    rootfs="$BATS_TEST_TMPDIR/bare"
    mkdir -p "$rootfs"
    run bt_mark_container "$rootfs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not in the rootfs"* ]]
}

@test "mark_container: defaults that declare no REDIRECT_OUTPUT fail loudly" {
    rootfs=$(fake_rootfs)
    grep -v REDIRECT_OUTPUT "$rootfs/$BT_INITHOOKS_DEFAULT" > "$rootfs/trimmed"
    mv "$rootfs/trimmed" "$rootfs/$BT_INITHOOKS_DEFAULT"
    run bt_mark_container "$rootfs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares no REDIRECT_OUTPUT"* ]]
}

@test "spec_targets: both paths the first boot reads, under the rootfs" {
    output=$(bt_spec_targets /r)
    [ "$output" = $'/r/etc/keel/instance.yaml\n/r/etc/inithooks.yaml' ]
}

@test "secret_targets: the two secret files the spec references" {
    output=$(bt_secret_targets /r)
    [ "$output" = $'/r/etc/keel/secrets/root_password\n/r/etc/keel/secrets/db_password\n/r/etc/keel/secrets/app_password' ]
}

@test "webmin_verdict: the login page or a challenge is an answer" {
    run bt_webmin_verdict 200
    [ "$status" -eq 0 ]
    [[ $output == *"webmin answered 200 on port 12321"* ]]
    run bt_webmin_verdict 401
    [ "$status" -eq 0 ]
    run bt_webmin_verdict 000
    [ "$status" -eq 1 ]
    [[ $output == *"not 200 or 401"* ]]
    run bt_webmin_verdict 502
    [ "$status" -eq 1 ]
    run bt_webmin_verdict
    [ "$status" -eq 1 ]
    [[ $output == *"answered ''"* ]]
}

@test "module_verdict: the database module must be installed on the machine" {
    run bt_module_verdict webmin-postgresql "install ok installed"
    [ "$status" -eq 0 ]
    [[ $output == *"webmin-postgresql is installed"* ]]
    run bt_module_verdict webmin-postgresql "install ok unpacked"
    [ "$status" -eq 1 ]
    [[ $output == *"is 'install ok unpacked'"* ]]
    run bt_module_verdict webmin-postgresql
    [ "$status" -eq 1 ]
    [[ $output == *"is ''"* ]]
}

@test "db_verdict: the probe answer passes, anything else is a refusal" {
    run bt_db_verdict 1
    [ "$status" -eq 0 ]
    [[ $output == *"postgres authenticated on [::1]:5432 with the declared password"* ]]
    run bt_db_verdict $'\n1\n'
    [ "$status" -eq 0 ]
    run bt_db_verdict "psql: error: connection failed: password authentication failed"
    [ "$status" -eq 1 ]
    [[ $output == *"did not reach the database"* ]]
    run bt_db_verdict
    [ "$status" -eq 1 ]
    [[ $output == *"answered ''"* ]]
}

@test "db_client_argv: the client call, with no password on the line" {
    output=$(bt_db_client_argv postgres ::1 5432)
    [ "$output" = $'psql\n--username=postgres\n--host=::1\n--port=5432\n--dbname=postgres\n--no-password\n--tuples-only\n--no-align\n--quiet\n--command=SELECT 1' ]
    [[ $output != *"PGPASSWORD"* ]]
    [[ $output == *"--no-password"* ]]
}

@test "db_client_argv: another database can be named" {
    output=$(bt_db_client_argv postgres ::1 5432 template1)
    [[ $output == *"--dbname=template1"* ]]
}

@test "db_client_argv: an empty user, host, database or a bad port fails" {
    run ! bt_db_client_argv "" ::1 5432
    run ! bt_db_client_argv postgres "" 5432
    run ! bt_db_client_argv postgres ::1 ""
    run ! bt_db_client_argv postgres ::1 fivefourthreetwo
    run ! bt_db_client_argv postgres ::1 5432 ""
}

@test "spec_in_rootfs: secret references are pointed inside the rootfs" {
    printf 'secrets:\n  root_password:\n    file: /etc/keel/secrets/root_password\ntls:\n  acme:\n    enabled: false\n' > "$STUBS/spec"
    output=$(bt_spec_in_rootfs "$STUBS/spec" /r/rootfs)
    [[ $output == *"file: /r/rootfs/etc/keel/secrets/root_password"* ]]
    [[ $output == *"enabled: false"* ]]
    [[ $output != *"file: /etc/keel"* ]]
}

@test "random_password: 24 alphanumeric characters from the random source" {
    output=$(bt_random_password)
    [[ $output =~ ^[A-Za-z0-9]{24}$ ]]
    printf 'ab!!cd%%%%efghijklmnopqrstuvwxyz0123456789' > "$STUBS/random"
    output=$(BT_RANDOM_SOURCE=$STUBS/random bt_random_password)
    [ "$output" = abcdefghijklmnopqrstuvwx ]
}

@test "random_password: a source too poor to fill the password fails loudly" {
    printf '!!!!short!!!!' > "$STUBS/poor"
    BT_RANDOM_SOURCE="$STUBS/poor"
    run bt_random_password
    [ "$status" -eq 1 ]
    [[ $output == *"gave only 5 usable characters"* ]]
}

@test "diff_verdict: 0 and 13 pass, everything else fails with a message" {
    run bt_diff_verdict 0
    [ "$status" -eq 0 ]
    [ "$output" = "keel diff: no drift" ]
    run bt_diff_verdict 13
    [ "$status" -eq 0 ]
    [[ $output == *"could not be observed offline"* ]]
    run bt_diff_verdict 14
    [ "$status" -eq 1 ]
    [[ $output == *"drift found"* ]]
    run bt_diff_verdict 2
    [ "$status" -eq 1 ]
    [[ $output == *"unreadable or invalid (exit 2)"* ]]
    run bt_diff_verdict 3
    [ "$status" -eq 1 ]
    run bt_diff_verdict 127
    [ "$status" -eq 1 ]
    [[ $output == *"failed with exit 127"* ]]
}

# the check page of decision 0059: Nginx reached Python, Python read from
# PostgreSQL, the server is writable and the first boot wrote its row
PAGE_OK='<h1>Keel LNPP: the stack works</h1>
<tr><th>Host</th><td>lnpp</td></tr>
<tr><th>Python</th><td>Python 3.13.5</td></tr>
<tr><th>PostgreSQL</th><td>PostgreSQL 17.6 (Debian 17.6-0+deb13u1) on x86_64</td></tr>
<tr><th>Role of the server</th><td>writable (a primary, or a standalone server)</td></tr>
<tr><td>lnpp</td><td>2026-10-16 07:00:00+00</td></tr>'

@test "check_page_verdict: the page with every layer and the row of the host passes" {
    run bt_check_page_verdict "$PAGE_OK" lnpp
    [ "$status" -eq 0 ]
    [[ $output == *"the check page answers: Python 3.13.5, PostgreSQL 17.6"* ]]
}

@test "check_page_verdict: a page without Python, PostgreSQL, the role or the row fails" {
    for missing in "Python 3" "PostgreSQL 17" "writable" "<td>lnpp</td><td>"; do
        run bt_check_page_verdict "${PAGE_OK//$missing/}" lnpp
        [ "$status" -eq 1 ]
        [[ $output == *"the check page does not show"* ]]
    done
}

@test "check_page_verdict: a 503 or an empty answer fails" {
    run bt_check_page_verdict "The database does not answer." lnpp
    [ "$status" -eq 1 ]
    run bt_check_page_verdict "" lnpp
    [ "$status" -eq 1 ]
}

# Odoo: the login page, the CSRF token, the login and the web client

LOGIN_PAGE='<html><head><title>Login | Odoo</title></head><body>
<form method="post"><input type="hidden" name="csrf_token" value="a1b2c3d4e5.1792000000.f6e5d4c3b2a1"/>
<input name="login"/></form></body></html>'

@test "odoo_page_verdict: 200 and an Odoo login form is an answer" {
    run bt_odoo_page_verdict 200 "$LOGIN_PAGE"
    [ "$status" -eq 0 ]
    [[ $output == *"the Odoo login page answers 200"* ]]
}

@test "odoo_page_verdict: a code other than 200 fails, 502 says Odoo is not up" {
    run bt_odoo_page_verdict 502 "$LOGIN_PAGE"
    [ "$status" -eq 1 ]
    [[ $output == *"answered '502'"* ]]
    run bt_odoo_page_verdict "" ""
    [ "$status" -eq 1 ]
}

@test "odoo_page_verdict: a page without the login form fails" {
    run bt_odoo_page_verdict 200 "<html>Not found</html>"
    [ "$status" -eq 1 ]
    [[ $output == *"no Odoo login form"* ]]
}

@test "odoo_csrf_token: the value of the hidden field" {
    run bt_odoo_csrf_token "$LOGIN_PAGE"
    [ "$status" -eq 0 ]
    [ "$output" = "a1b2c3d4e5.1792000000.f6e5d4c3b2a1" ]
}

@test "odoo_csrf_token: a page without the field fails" {
    run bt_odoo_csrf_token "<html></html>"
    [ "$status" -eq 1 ]
    run bt_odoo_csrf_token ""
    [ "$status" -eq 1 ]
}

LOGIN_OK=$'HTTP/1.1 303 SEE OTHER\r\nLocation: /odoo\r\nSet-Cookie: session_id=abc; Expires=Tue, 20 Oct 2026 00:00:00 GMT; HttpOnly; Path=/\r\n'

@test "odoo_login_verdict: a redirect away from the login page with a session cookie is a login" {
    run bt_odoo_login_verdict "$LOGIN_OK"
    [ "$status" -eq 0 ]
    [[ $output == *"the admin user logged in with the declared password"* ]]
}

@test "odoo_login_verdict: a redirect back to the login page is a refusal" {
    run bt_odoo_login_verdict $'HTTP/1.1 303 SEE OTHER\r\nLocation: /web/login?error=1\r\n'
    [ "$status" -eq 1 ]
    [[ $output == *"did not log in"* ]]
}

@test "odoo_login_verdict: a 200 page, no cookie, or nothing fails" {
    run bt_odoo_login_verdict $'HTTP/1.1 200 OK\r\nSet-Cookie: session_id=abc\r\n'
    [ "$status" -eq 1 ]
    run bt_odoo_login_verdict $'HTTP/1.1 303 SEE OTHER\r\nLocation: /odoo\r\n'
    [ "$status" -eq 1 ]
    run bt_odoo_login_verdict ""
    [ "$status" -eq 1 ]
}

@test "odoo_assets_verdict: the web client script is served with content" {
    run bt_odoo_assets_verdict 200 5000
    [ "$status" -eq 0 ]
    [[ $output == *"5000 bytes"* ]]
}

@test "odoo_assets_verdict: a small body or another code fails" {
    run bt_odoo_assets_verdict 200 12
    [ "$status" -eq 1 ]
    run bt_odoo_assets_verdict 404 5000
    [ "$status" -eq 1 ]
    run bt_odoo_assets_verdict "" ""
    [ "$status" -eq 1 ]
}

@test "odoo_assets_url: the first asset bundle of the login page" {
    run bt_odoo_assets_url $'<script src="/web/assets/1/abcdef/web.assets_frontend.min.js"></script>\n<link href="/web/assets/2/x/other.css"/>'
    [ "$status" -eq 0 ]
    [ "$output" = "/web/assets/1/abcdef/web.assets_frontend.min.js" ]
    run bt_odoo_assets_url "<html></html>"
    [ "$status" -eq 1 ]
}
