#!/bin/bash
# Pure helpers of tests/boot-test.sh (decision 0004: logic apart from
# effect). Same shape as the one in keel-core, keel-nodebb and keel-mariadb, with the
# checks this layer adds: a client connection to the database with the
# password the instance description declared, the Webmin module for that
# database, and Webmin answering over IPv6. Nothing here starts a
# container, writes outside a path it is given or opens a socket. The two
# functions that run a command, bt_now and bt_container_ipv6, take it from
# the environment or from PATH so a test can replace it. Sourced by
# boot-test.sh and by tests/boot-test.bats.
# shellcheck disable=SC2034  # the BT_* variables are read by the caller

BT_DEFAULT_TIMEOUT=900
BT_DEFAULT_INTERVAL=5
BT_DEFAULT_BRIDGE=br0
BT_DEFAULT_LAYERS_DIR=/mnt/builds/layers
BT_DEFAULT_CACHE_DIR=/var/cache/keel/layers
BT_DEFAULT_LXC_PATH=/var/lib/lxc
BT_SSH_PORT=22
BT_PASSWORD_LENGTH=24
BT_RANDOM_BYTES=1024
# The secrets tests/instance.yaml references, one file each under
# etc/keel/secrets in the rootfs: the root account, the database
# account and the Odoo account (the admin user and the master password).
BT_SECRETS="root_password db_password app_password"
# The panel core carries and this layer adds a module to.
BT_ODOO_MIN_ASSET_BYTES=1000
BT_WEBMIN_PORT=12321
BT_WEBMIN_MODULE=webmin-postgresql
# The database connection the test proves. The client runs inside the
# container, because the cluster listens on the loopback of both families
# and nowhere else: an appliance above this layer talks to it from the same
# machine, and opening it to the network is that appliance's decision, not
# this layer's.
BT_DB_USER="postgres"
BT_DB_HOST=::1
BT_DB_PORT=5432
BT_DB_NAME=postgres
BT_DB_PROBE_QUERY="SELECT 1"
BT_DB_PROBE_ANSWER=1
# Where the first boot reads the instance description. inithooks reads
# etc/inithooks.yaml (hook 00declarative), keel reads etc/keel/instance.yaml;
# the final name is a maintainer decision (brief section 11), so the test
# installs the same file at both until then.
BT_SPEC_PATHS="etc/keel/instance.yaml etc/inithooks.yaml"
# What marks the tree as a container build, relative to the rootfs: the
# marker file bt-container writes, the inithooks defaults whose
# REDIRECT_OUTPUT it sets, and the drop-in that keeps the first boot off
# tty1. See bt_mark_container.
BT_CONTAINER_MARKER="var/lib/turnkey-info/inithooks.service/lxc"
BT_INITHOOKS_DEFAULT="etc/default/inithooks"
BT_INITHOOKS_DROPIN="etc/systemd/system/inithooks.service.d/container.conf"

bt_usage() {
    cat <<USAGE
usage: tests/boot-test.sh APPLIANCE [options]

Assembles the layer chain of APPLIANCE (odoo) into an LXC rootfs, boots
it headless from tests/instance.yaml, waits for the first boot to finish,
connects to the database with the password the description declared,
checks the Webmin module and Webmin over IPv6, and checks that keel diff
reports no drift. Root only.

options:
  --timeout SECONDS     give up after this long per wait (default $BT_DEFAULT_TIMEOUT)
  --interval SECONDS    poll interval (default $BT_DEFAULT_INTERVAL)
  --bridge NAME         bridge the container joins (default $BT_DEFAULT_BRIDGE)
  --layers-dir DIR|URL  where the layers are published: a directory, or an
                        http(s) URL such as https://mirror.keellinux.org/layers
                        (default $BT_DEFAULT_LAYERS_DIR)
  --cache-dir DIR       keel layer cache (default $BT_DEFAULT_CACHE_DIR)
  --lxc-path DIR        lxcpath for the test container (default $BT_DEFAULT_LXC_PATH)
  --name NAME           container name (default keel-APPLIANCE-boot-test)
  --spec FILE           instance spec (default tests/instance.yaml)
  --keep                leave the container running for inspection
  -h, --help            this text
USAGE
}

bt_is_positive_int() {
    [[ ${1-} =~ ^[1-9][0-9]*$ ]]
}

bt_is_appliance_name() {
    # The name bt-layer and the workflow use: no keel- prefix, lower case.
    [[ ${1-} =~ ^[a-z][a-z0-9-]*$ ]] && [[ $1 != keel-* ]]
}

bt_container_name() {
    printf 'keel-%s-boot-test\n' "$1"
}

bt_is_container_name() {
    # What LXC accepts and what the CI cleanup command allows: lower case
    # letters, digits, dot and dash, starting with a letter or a digit.
    [[ ${1-} =~ ^[a-z0-9][a-z0-9.-]*$ ]]
}

# Sets BT_APPLIANCE, BT_TIMEOUT, BT_INTERVAL, BT_BRIDGE, BT_LAYERS_DIR,
# BT_CACHE_DIR, BT_LXC_PATH, BT_SPEC, BT_KEEP, BT_NAME and BT_ROOTFS.
# Returns 0 when parsed, 2 after printing the usage, 1 on a bad argument
# (message on stderr).
bt_parse_args() {
    BT_APPLIANCE=""
    BT_TIMEOUT=$BT_DEFAULT_TIMEOUT
    BT_INTERVAL=$BT_DEFAULT_INTERVAL
    BT_BRIDGE=$BT_DEFAULT_BRIDGE
    BT_LAYERS_DIR=$BT_DEFAULT_LAYERS_DIR
    BT_CACHE_DIR=$BT_DEFAULT_CACHE_DIR
    BT_LXC_PATH=$BT_DEFAULT_LXC_PATH
    BT_NAME=""
    BT_SPEC=""
    BT_KEEP=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout|--interval)
                bt_is_positive_int "${2-}" || {
                    echo "boot-test: $1 needs a positive number of seconds" >&2
                    return 1
                }
                [ "$1" = --timeout ] && BT_TIMEOUT=$2 || BT_INTERVAL=$2
                shift
                ;;
            --bridge|--layers-dir|--cache-dir|--lxc-path|--name|--spec)
                [ -n "${2-}" ] || {
                    echo "boot-test: $1 needs a value" >&2
                    return 1
                }
                case "$1" in
                    --bridge) BT_BRIDGE=$2 ;;
                    --layers-dir) BT_LAYERS_DIR=$2 ;;
                    --cache-dir) BT_CACHE_DIR=$2 ;;
                    --lxc-path) BT_LXC_PATH=$2 ;;
                    --name) BT_NAME=$2 ;;
                    --spec) BT_SPEC=$2 ;;
                esac
                shift
                ;;
            --keep) BT_KEEP=1 ;;
            -h|--help)
                bt_usage
                return 2
                ;;
            -*)
                echo "boot-test: unknown option $1" >&2
                return 1
                ;;
            *)
                if [ -n "$BT_APPLIANCE" ]; then
                    echo "boot-test: one appliance at a time ($BT_APPLIANCE, $1)" >&2
                    return 1
                fi
                BT_APPLIANCE=$1
                ;;
        esac
        shift
    done
    if [ -z "$BT_APPLIANCE" ]; then
        echo "boot-test: APPLIANCE is required (core, lamp, ...)" >&2
        return 1
    fi
    if ! bt_is_appliance_name "$BT_APPLIANCE"; then
        echo "boot-test: '$BT_APPLIANCE' is not an appliance name (lower case, no keel- prefix)" >&2
        return 1
    fi
    BT_NAME=${BT_NAME:-$(bt_container_name "$BT_APPLIANCE")}
    if ! bt_is_container_name "$BT_NAME"; then
        echo "boot-test: '$BT_NAME' is not a container name (lower case, digits, dot, dash)" >&2
        return 1
    fi
    BT_ROOTFS=$BT_LXC_PATH/$BT_NAME/rootfs
    return 0
}

bt_is_global_ipv6() {
    # Global unicast, which includes ULA (fc00::/7); not link local
    # (fe80::/10), loopback or multicast. IPv4 has no colon.
    local addr=${1,,}
    [[ $addr == *:* ]] || return 1
    [[ $addr == fe[89ab]?:* ]] && return 1
    [[ $addr == ::1 ]] && return 1
    [[ $addr == ff* ]] && return 1
    return 0
}

bt_global_ipv6() {
    # stdin: the output of lxc-info -i ("IP:  ADDRESS" per line). Prints
    # the first global IPv6 address; returns 1 when there is none yet.
    local label addr _
    while read -r label addr _; do
        [ "$label" = "IP:" ] || continue
        if bt_is_global_ipv6 "$addr"; then
            printf '%s\n' "$addr"
            return 0
        fi
    done
    return 1
}

bt_container_ipv6() {
    # bt_container_ipv6 NAME LXCPATH: the container's first global IPv6.
    lxc-info -P "$2" -n "$1" -i 2>/dev/null | bt_global_ipv6
}

bt_now() {
    ${BT_CLOCK:-date +%s}
}

bt_deadline_passed() {
    # bt_deadline_passed START TIMEOUT NOW
    [ $(( $3 - $1 )) -ge "$2" ]
}

bt_wait_for() {
    # bt_wait_for TIMEOUT INTERVAL DESCRIPTION COMMAND [ARGS...]
    # Runs COMMAND until it succeeds; returns 1 once TIMEOUT seconds passed.
    local timeout=$1 interval=$2 what=$3 start now
    shift 3
    start=$(bt_now)
    until "$@"; do
        now=$(bt_now)
        if bt_deadline_passed "$start" "$timeout" "$now"; then
            echo "boot-test: timeout after ${timeout}s waiting for $what" >&2
            return 1
        fi
        ${BT_SLEEP:-sleep} "$interval"
    done
}

bt_is_ssh_banner() {
    [[ ${1-} == SSH-2.0-* ]]
}

bt_firstboot_done_in() {
    # bt_firstboot_done_in FILE: FILE is the rootfs copy of
    # /etc/default/inithooks; 98finalize sets RUN_FIRSTBOOT=false at the end.
    [ -r "$1" ] && grep -q '^RUN_FIRSTBOOT=false' "$1"
}

bt_lxc_config() {
    # bt_lxc_config NAME ROOTFS BRIDGE: an LXC config for a plain rootfs
    # directory on a bridge; the address comes from the bridge (SLAAC or
    # DHCPv6), the spec declares managed_by: host.
    # The apparmor pair is not decoration. Under the stock container
    # profile systemd cannot give a unit a mount namespace, so every unit
    # with ProtectSystem or ProtectHome fails with status=226/NAMESPACE
    # before its own first line runs. Measured in the container this test
    # builds: systemd-journald, systemd-logind, systemd-sysusers,
    # systemd-sysctl and tmp.mount all failed that way, which is why
    # 15regen-sslcert and 95secupdates failed beside the database, and why
    # the container had no journal to read when it was asked why. The
    # cluster itself survived it, because postgresql@.service asks for no
    # namespace; keel-mariadb's database did not. A generated profile with
    # nesting allowed is what a container running systemd needs, and it is
    # what the appliance containers on the build host have carried all
    # along.
    cat <<CONFIG
lxc.uts.name = $1
lxc.rootfs.path = dir:$2
lxc.include = /usr/share/lxc/config/common.conf
lxc.arch = amd64
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
lxc.net.0.type = veth
lxc.net.0.link = $3
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.start.auto = 0
CONFIG
}

bt_mark_container() {
    # bt_mark_container ROOTFS: make the tree look like the container build
    # buildtasks produces, which is two things, both from its
    # patches/container/conf:
    #
    #   the marker under /var/lib/turnkey-info, which inithooks' unit
    #   conditions read and which `keel inspect` reads to call the machine a
    #   container (network.managed_by: host), and
    #
    #   REDIRECT_OUTPUT=true in /etc/default/inithooks, which sends first
    #   boot output to the log with a tail on the active console instead of
    #   writing it straight to tty1,
    #
    # and a drop-in that keeps the first boot off tty1.
    #
    # The last two are not cosmetic. The layer ships the plain appliance
    # inithooks.service, which runs the hooks with StandardOutput=tty on
    # /dev/tty1; the unit a container image gets instead logs to syslog and
    # the console. Nothing reads tty1 in a container nobody has attached to,
    # so a hook that prints more than the terminal buffer holds blocks in
    # the write and never returns. keel-nodebb found it the hard way, with
    # `./nodebb setup` asleep in n_tty_write and a first boot that never
    # finished; this is the same function, so the next hook that prints a
    # lot does not find it again.
    local rootfs=$1 defaults=$1/$BT_INITHOOKS_DEFAULT
    install -D -m 0644 /dev/null "$rootfs/$BT_CONTAINER_MARKER" || return 1
    if [ ! -f "$defaults" ]; then
        echo "boot-test: $defaults is not in the rootfs" >&2
        return 1
    fi
    sed -i '/REDIRECT_OUTPUT/ s/=.*/=true/' "$defaults" || return 1
    if ! grep -q '^REDIRECT_OUTPUT=true$' "$defaults"; then
        echo "boot-test: $defaults declares no REDIRECT_OUTPUT to set" >&2
        return 1
    fi
    install -D -m 0644 /dev/stdin "$rootfs/$BT_INITHOOKS_DROPIN" <<DROPIN || return 1
[Service]
StandardOutput=journal
StandardError=journal
DROPIN
}

bt_spec_targets() {
    # bt_spec_targets ROOTFS: the paths the spec is installed at.
    local relative
    for relative in $BT_SPEC_PATHS; do
        printf '%s/%s\n' "$1" "$relative"
    done
}

bt_spec_in_rootfs() {
    # bt_spec_in_rootfs SPEC ROOTFS: the spec with its secret references
    # pointed inside ROOTFS, printed on stdout. `keel spec apply` runs on
    # the host and resolves a secret path against the host, so the copy it
    # reads has to name the files this test wrote into the container.
    sed -E "s#^([[:space:]]*file:[[:space:]]*)(/etc/keel/secrets/)#\1$2\2#" "$1"
}

bt_random_password() {
    # A fixed block is read first and filtered afterwards. The other way
    # round, "tr < source | head -c N", leaves tr killed by SIGPIPE when
    # head has its N characters, and the set -o pipefail of boot-test.sh
    # turns that into exit 141 before the container is ever started.
    local pool source=${BT_RANDOM_SOURCE:-/dev/urandom}
    pool=$(head -c "$BT_RANDOM_BYTES" "$source" | LC_ALL=C tr -dc 'A-Za-z0-9')
    if [ "${#pool}" -lt "$BT_PASSWORD_LENGTH" ]; then
        echo "boot-test: $source gave only ${#pool} usable characters" >&2
        return 1
    fi
    printf '%s\n' "${pool:0:BT_PASSWORD_LENGTH}"
}

bt_secret_targets() {
    # bt_secret_targets ROOTFS: the secret files the spec references.
    local name
    for name in $BT_SECRETS; do
        printf '%s/etc/keel/secrets/%s\n' "$1" "$name"
    done
}

bt_webmin_verdict() {
    # bt_webmin_verdict CODE: Webmin comes from core and is the panel this
    # layer adds its database module to, so the boot test checks that it
    # answers over IPv6 on 12321. It asks for credentials, so 200 (the
    # login page) and 401 are both an answer; 000 is curl failing to
    # connect at all.
    case "${1-}" in
        200|401)
            echo "boot-test: webmin answered $1 on port $BT_WEBMIN_PORT"
            ;;
        *)
            echo "boot-test: webmin answered '${1-}' on port $BT_WEBMIN_PORT, not 200 or 401" >&2
            return 1
            ;;
    esac
}

bt_module_verdict() {
    # bt_module_verdict PACKAGE STATUS: the Webmin module for this
    # database must be installed on the booted machine, not only in the
    # plan. Batteries included is a property of the distribution, so a
    # panel without its database module is a failed boot test.
    if [ "${2-}" = "install ok installed" ]; then
        echo "boot-test: $1 is installed"
        return 0
    fi
    echo "boot-test: $1 is '${2-}', not 'install ok installed'" >&2
    return 1
}

bt_db_verdict() {
    # bt_db_verdict OUTPUT: what the database client printed when it
    # connected with the declared password and ran the probe query. The
    # whole point of this appliance is that a declared password reaches
    # the database, so the answer is the verdict: anything other than the
    # single row the query asks for means the connection did not happen or
    # did not authenticate.
    local output
    output=$(printf '%s' "${1-}" | tr -d '[:space:]')
    if [ "$output" = "$BT_DB_PROBE_ANSWER" ]; then
        echo "boot-test: $BT_DB_USER authenticated on [$BT_DB_HOST]:$BT_DB_PORT with the declared password"
        return 0
    fi
    echo "boot-test: the database client answered '${1-}', not '$BT_DB_PROBE_ANSWER': the declared password did not reach the database" >&2
    return 1
}

bt_db_client_argv() {
    # bt_db_client_argv USER HOST PORT [DATABASE]: the client command the
    # boot test runs inside the container, one argument per line. The
    # password is not here: it goes through PGPASSWORD in the environment,
    # so it never appears in the container's process list. --no-password
    # makes psql fail instead of prompting, so a password that did not
    # arrive is an error and not a hung test.
    local user=$1 host=$2 port=$3 database=${4-$BT_DB_NAME}
    [ -n "$user" ] && [ -n "$host" ] && [ -n "$database" ] || return 1
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' psql "--username=$user" "--host=$host" "--port=$port" \
        "--dbname=$database" --no-password --tuples-only --no-align --quiet \
        "--command=$BT_DB_PROBE_QUERY"
}
bt_diff_verdict() {
    # bt_diff_verdict CODE: interprets the exit code of keel diff
    # (docs/diff.md of the keel repository). 0 and 13 mean no drift.
    case "$1" in
        0) echo "keel diff: no drift"; return 0 ;;
        13) echo "keel diff: no drift, but a declared field could not be observed offline (see the report above)"; return 0 ;;
        14) echo "keel diff: drift found" >&2; return 1 ;;
        2|3) echo "keel diff: the spec is unreadable or invalid (exit $1)" >&2; return 1 ;;
        *) echo "keel diff: failed with exit $1" >&2; return 1 ;;
    esac
}

bt_check_page_verdict() {
    # bt_check_page_verdict BODY HOST: the check page of decision 0059 at
    # /keel-check/ over HTTPS shows each layer of the stack: the title,
    # Python, PostgreSQL, a writable server, and the row the first boot of
    # HOST wrote.
    local body=${1-} host=${2-} want
    for want in "Keel LNPP: the stack works" "<td>Python 3." \
            "<td>PostgreSQL 17" "<td>writable" "<td>$host</td><td>"; do
        if [[ $body != *"$want"* ]]; then
            echo "boot-test: the check page does not show '$want'" >&2
            return 1
        fi
    done
    local python server
    python=$(grep -o 'Python 3\.[0-9.]*' <<< "$body" | head -1)
    server=$(grep -o 'PostgreSQL 17[0-9.]*' <<< "$body" | head -1)
    echo "boot-test: the check page answers: $python, $server, writable, the row of $host"
}

bt_odoo_page_verdict() {
    # bt_odoo_page_verdict CODE BODY: /web/login over HTTPS. Nginx proxies
    # to Odoo on the loopback, and serve.py starts Odoo when the
    # first boot ends and PostgreSQL accepts writes. 502 means Nginx is up
    # and Odoo is not.
    local code=${1-} body=${2-}
    if [ "$code" != 200 ]; then
        echo "boot-test: the Odoo login page answered '$code', not 200" >&2
        return 1
    fi
    if [[ $body != *'name="csrf_token"'* ]]; then
        echo "boot-test: the page at /web/login has no Odoo login form" >&2
        return 1
    fi
    echo "boot-test: the Odoo login page answers 200 with its form"
}

bt_odoo_csrf_token() {
    # bt_odoo_csrf_token BODY: the value of the hidden csrf_token field.
    local token
    token=$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' <<< "${1-}" | head -1)
    [ -n "$token" ] || return 1
    printf '%s\n' "$token"
}

bt_odoo_login_verdict() {
    # bt_odoo_login_verdict HEADERS: the response headers of the login
    # POST. A login is a redirect (303) that does not go back to the login
    # page, with a session cookie.
    local headers=${1-}
    if grep -qi '^HTTP/[0-9.]* 303' <<< "$headers" \
            && grep -qi '^Location:' <<< "$headers" \
            && ! grep -i '^Location:' <<< "$headers" | grep -q '/web/login' \
            && grep -qi '^Set-Cookie: session_id=' <<< "$headers"; then
        echo "boot-test: the admin user logged in with the declared password"
        return 0
    fi
    echo "boot-test: the admin user did not log in with the declared password" >&2
    return 1
}

bt_odoo_assets_url() {
    # bt_odoo_assets_url BODY: the path of the first script bundle that the
    # login page names. The bundles are attachments, stored in the database.
    local path
    path=$(grep -o '/web/assets/[^"]*\.js' <<< "${1-}" | head -1) || true
    [ -n "$path" ] || return 1
    printf '%s\n' "$path"
}

bt_odoo_assets_verdict() {
    # bt_odoo_assets_verdict CODE SIZE: the bundle comes from the database,
    # so a body with content proves that the attachment is there.
    local code=${1-} size=${2-}
    if [ "$code" = 200 ] && [[ $size =~ ^[0-9]+$ ]] && [ "$size" -ge "$BT_ODOO_MIN_ASSET_BYTES" ]; then
        echo "boot-test: the web client script is served, $size bytes"
        return 0
    fi
    echo "boot-test: the web client script answered '$code' with '$size' bytes" >&2
    return 1
}

bt_odoo_websocket_verdict() {
    # bt_odoo_websocket_verdict CODE: an upgrade request to /websocket. The
    # gevent worker answers 101 when the bus is up.
    local code=${1-}
    if [ "$code" = 101 ]; then
        echo "boot-test: the websocket upgrade answers 101"
        return 0
    fi
    echo "boot-test: the websocket upgrade answered '$code', not 101" >&2
    return 1
}

bt_odoo_pdf_verdict() {
    # bt_odoo_pdf_verdict TEXT: the text of a report that Odoo printed with
    # wkhtmltopdf (tests/lib/odoo-pdf.py). A build of wkhtmltopdf without
    # patched qt prints the body and no header and no footer.
    local text=${1-}
    if [ -z "$text" ]; then
        echo "boot-test: the report has no text: no PDF came back" >&2
        return 1
    fi
    if [[ $text != *KEEL-BODY-TEXT* ]]; then
        echo "boot-test: the report has no body text" >&2
        return 1
    fi
    # the extractor puts the words of the footer on one line or on four
    if ! tr -s '[:space:]' ' ' <<< "$text" | grep -qE 'Page 1 / 1'; then
        echo "boot-test: the report has no page number: the footer did not print" >&2
        return 1
    fi
    echo "boot-test: the report printed as PDF with its header and footer"
}
