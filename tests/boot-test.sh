#!/bin/bash
# Boot test of this layer (org-plan section 1), modelled on the one in
# keel-nodebb and keel-mariadb: assemble the published layer chain into an LXC rootfs, boot
# it headless from tests/instance.yaml, wait for the first boot to finish,
# then prove the declarative path end to end. The instance description
# declares secrets.db_password from a file; nothing is configured by hand;
# and the test connects to the database as a client, with that password, to
# say whether it arrived. A listening port would prove nothing here: the
# database listens whatever password it ended up with.
#
# It also checks what the panel offers, because batteries included is a
# property of this distribution: the Webmin module for this database is
# installed and Webmin answers over IPv6 on 12321.
#
# Called by the reusable workflow test-appliance.yml after keel pull and
# keel verify; runnable by hand as root on any host with LXC, see
# tests/README.md. It builds nothing: the layers come from the mirror or
# from a directory bt-layer wrote, so the test needs no fab, deck or
# buildtasks. The logic lives in tests/lib/boot-test-lib.sh and is unit
# tested; this file is the thin main that touches the system.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/boot-test-lib.sh
source "$here/lib/boot-test-lib.sh"

bt_parse_args "$@" || { rc=$?; [ "$rc" -eq 2 ] && exit 0; exit 1; }
BT_SPEC=${BT_SPEC:-$here/instance.yaml}
if [ "$(id -u)" -ne 0 ]; then
    echo "boot-test: must run as root (keel assemble, lxc-start)" >&2
    exit 1
fi
for tool in keel lxc-start lxc-info lxc-attach lxc-stop curl; do
    command -v "$tool" >/dev/null || { echo "boot-test: $tool not found" >&2; exit 1; }
done

container_dir=$BT_LXC_PATH/$BT_NAME
log() { printf '%s boot-test: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
lxc() { "lxc-$1" -P "$BT_LXC_PATH" -n "$BT_NAME" "${@:2}"; }

cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ -r "$BT_ROOTFS/var/log/inithooks.log" ]; then
        log "last lines of the container's inithooks log:"
        tail -n 40 "$BT_ROOTFS/var/log/inithooks.log"
    fi
    if [ "$BT_KEEP" -eq 1 ]; then
        log "keeping $BT_NAME under $BT_LXC_PATH (--keep); lxc-attach -P $BT_LXC_PATH -n $BT_NAME"
        return
    fi
    lxc stop -k >/dev/null 2>&1 || true
    rm -rf "$container_dir"
}
trap cleanup EXIT

# 1. Assemble the chain from the layers the build host published.
log "assembling $BT_APPLIANCE from $BT_LAYERS_DIR into $BT_ROOTFS"
lxc stop -k >/dev/null 2>&1 || true
rm -rf "$container_dir"
mkdir -p "$BT_ROOTFS"
keel pull "$BT_APPLIANCE" --source "$BT_LAYERS_DIR" --cache-dir "$BT_CACHE_DIR" --non-interactive
keel assemble "$BT_APPLIANCE" --rootfs "$BT_ROOTFS" --cache-dir "$BT_CACHE_DIR" --non-interactive

# 2. The container marks, the instance description, the secrets it
#    references and the conf the first boot hooks read. bt_mark_container
#    does what buildtasks' container patch does: the marker under
#    /var/lib/turnkey-info that inspect reads to call the machine a
#    container (managed_by: host), and REDIRECT_OUTPUT=true with a
#    drop-in, without which a hook that prints a lot blocks writing to a
#    tty1 nobody reads. The conf is what makes the first boot headless,
#    and without it 30rootpass and 35pgsqlpass wait on a dialog forever.
log "installing the description, the secrets and the conf into $BT_ROOTFS"
bt_mark_container "$BT_ROOTFS"
install -d -m 0700 "$BT_ROOTFS/etc/keel/secrets"
for target in $(bt_secret_targets "$BT_ROOTFS"); do
    bt_random_password > "$target"
    chmod 0600 "$target"
done
for target in $(bt_spec_targets "$BT_ROOTFS"); do
    install -D -m 0600 "$BT_SPEC" "$target"
done
bt_spec_in_rootfs "$BT_SPEC" "$BT_ROOTFS" > "$container_dir/instance-host.yaml"
keel spec apply --spec "$container_dir/instance-host.yaml" \
    --conf "$BT_ROOTFS/etc/inithooks.conf" --non-interactive

# The declared password, as the description names it. Everything below
# uses this and nothing else: no value is read out of the container.
declared_password=$(cat "$BT_ROOTFS/etc/keel/secrets/db_password")

# 3. Boot.
bt_lxc_config "$BT_NAME" "$BT_ROOTFS" "$BT_BRIDGE" > "$container_dir/config"
log "starting $BT_NAME on bridge $BT_BRIDGE"
lxc start -d

# 4. A global IPv6 address from the bridge.
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "a global IPv6 address on $BT_NAME" \
    bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH" > /dev/null
addr=$(bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH")
log "container address $addr"

# 5. First boot finished: 98finalize has cleared RUN_FIRSTBOOT and the
#    machine answers, on the console (confconsole's usage screen) or on
#    SSH. The answer alone is not enough: sshd is up long before the hooks
#    are done, so the flag is what says the first boot ended.
usage_screen() {
    lxc attach -- pgrep -f confconsole > /dev/null 2>&1
}
ssh_answers() {
    local banner
    banner=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1" && read -r -t 5 line <&3 && printf "%s" "$line"' \
        "$addr" "$BT_SSH_PORT" 2>/dev/null) || return 1
    bt_is_ssh_banner "$banner"
}
first_boot_done() {
    bt_firstboot_done_in "$BT_ROOTFS/etc/default/inithooks" || return 1
    usage_screen || ssh_answers
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the first boot of $BT_NAME to finish" \
    first_boot_done
log "first boot finished; ssh root@$addr"

# 6. What the first boot hook reported, quoted here so a failure below is
#    read next to it.
log "the database lines of the container's inithooks log:"
grep -E '35pgsqlpass|36pgsqlverify|40lnpp-check|45odoo|PostgreSQL' "$BT_ROOTFS/var/log/inithooks.log" || true

# 7. The declarative path, end to end: a client connection to the database
#    with the password the description declared. The client runs inside the
#    container over TCP on [::1], because the cluster listens on the
#    loopback of both families and nowhere else, and the password reaches
#    it in the environment so it never appears in the container's process
#    list. --no-password makes psql fail rather than prompt, so a password
#    that did not arrive is an error and not a hung test.
mapfile -t client < <(bt_db_client_argv "$BT_DB_USER" "$BT_DB_HOST" "$BT_DB_PORT")
log "connecting as $BT_DB_USER on [$BT_DB_HOST]:$BT_DB_PORT with the declared password"
answer=$(lxc attach --set-var "PGPASSWORD=$declared_password" -- "${client[@]}") \
    || { echo "boot-test: the database refused the declared password" >&2; exit 1; }
bt_db_verdict "$answer"

# 8. The panel core carries, with the module this layer adds to it.
status=$(lxc attach -- dpkg-query -W -f '${Status}' "$BT_WEBMIN_MODULE" 2>/dev/null || true)
bt_module_verdict "$BT_WEBMIN_MODULE" "$status"
code=""
webmin_answers() {
    code=$(curl -6 -k -s -o /dev/null -w '%{http_code}' \
        "https://[$addr]:$BT_WEBMIN_PORT/" || true)
    [ "$code" = 200 ] || [ "$code" = 401 ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "webmin on https://[$addr]:$BT_WEBMIN_PORT/" \
    webmin_answers
bt_webmin_verdict "$code"

# The check page of decision 0059 over HTTPS: Nginx proxies /keel-check/
# to gunicorn, which systemd starts from its socket at this first request,
# and the page reads PostgreSQL as keel-check.
page=""
check_page_answers() {
    page=$(curl -6 -k -s "https://[$addr]/keel-check/" || true)
    [[ $page == *"Keel LNPP: the stack works"* ]]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the check page on https://[$addr]/keel-check/" \
    check_page_answers || true
bt_check_page_verdict "$page" "$(lxc attach -- hostname)"

# Odoo (decision 0059, step 6). Nginx proxies /web/login to Odoo on the
# loopback. serve.py starts Odoo when the first boot has ended
# and PostgreSQL accepts writes, so the page can need some seconds. Then the
# admin user logs in with the password the description declared (no value is
# read out of the container), and a script bundle of the web client comes
# back with content, which proves that the attachments are in the database.
cookies="$container_dir/odoo.cookies"
declared_app_password=$(cat "$BT_ROOTFS/etc/keel/secrets/app_password")
odoo_code=""
odoo_page=""
odoo_answers() {
    local response
    response=$(curl -6 -k -s -c "$cookies" -w '\n%{http_code}' "https://[$addr]/web/login" || true)
    odoo_code=${response##*$'\n'}
    odoo_page=${response%$'\n'*}
    [ "$odoo_code" = 200 ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "Odoo on https://[$addr]/web/login" \
    odoo_answers || true
bt_odoo_page_verdict "$odoo_code" "$odoo_page"
csrf_token=$(bt_odoo_csrf_token "$odoo_page")
login_headers=$(printf '%s' "$declared_app_password" | curl -6 -k -s -D - -o /dev/null \
    -b "$cookies" -c "$cookies" --data-urlencode "csrf_token=$csrf_token" \
    --data-urlencode login=admin --data-urlencode password@- \
    "https://[$addr]/web/login" || true)
bt_odoo_login_verdict "$login_headers"
asset_path=$(bt_odoo_assets_url "$odoo_page") \
    || { echo "boot-test: the login page names no script bundle" >&2; exit 1; }
read -r asset_code asset_size < <(curl -6 -k -s -b "$cookies" -o /dev/null \
    -w '%{http_code} %{size_download}\n' "https://[$addr]$asset_path" || true)
bt_odoo_assets_verdict "${asset_code-}" "${asset_size-}"

# The bus of Odoo: the gevent worker starts a little after the web worker,
# so an upgrade request to /websocket can need some seconds. Behind Anubis
# the snippet of keel-overlay-anubis 0.1.1 passes the upgrade; this gate
# boots the simple mode, where Nginx passes it. Odoo refuses a handshake
# whose Origin is not the Host (a browser sends one), so the request has one.
websocket_code=""
websocket_answers() {
    websocket_code=$(curl -6 -k -s -o /dev/null --max-time 3 -w '%{http_code}' \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H "Origin: https://[$addr]" \
        -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
        "https://[$addr]/websocket" || true)
    [ "$websocket_code" = 101 ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the websocket on https://[$addr]/websocket" \
    websocket_answers || true
bt_odoo_websocket_verdict "$websocket_code"

# A report prints as PDF with its header and footer: wkhtmltopdf is the
# build with patched qt. The script runs in the container and logs in with
# the password of the spec from the file, not from the arguments.
pdf_text=$(lxc attach -- python3 - < "$here/lib/odoo-pdf.py" || true)
bt_odoo_pdf_verdict "$pdf_text"

# 9. No drift between the declared description and the booted root.
set +e
keel diff --root "$BT_ROOTFS" --spec "$BT_SPEC"
code=$?
set -e
bt_diff_verdict "$code"
log "$BT_APPLIANCE boot test passed"
