#!/usr/bin/env bats
# The files that the Odoo layer ships (handbook decision 0059): the
# appliance manifest, the units, the Nginx route and the configuration.
# keel's own schema check runs on a booted machine (tests/stack.bats); these
# checks keep the files from drifting, with no dependency beyond grep.

bats_require_minimum_version 1.5.0

OVERLAY=overlay
MANIFEST=$OVERLAY/usr/share/keel/appliances/odoo.yaml
ODOO_UNIT=$OVERLAY/usr/lib/systemd/system/odoo.service
SERVE=$OVERLAY/usr/lib/keel-odoo/serve.py
FRONT=$OVERLAY/etc/nginx/keel-front.d/60-keel-odoo.conf
CRS_AFTER=$OVERLAY/etc/coreruleset/plugins/keel-odoo-after.conf
PRESET=$OVERLAY/usr/lib/systemd/system-preset/20-keel-odoo.preset
ROUTE=$OVERLAY/etc/nginx/keel-default.d/60-keel-odoo.conf
MAP=$OVERLAY/etc/nginx/conf.d/keel-odoo.conf
CONF=$OVERLAY/etc/odoo/odoo.conf
HOOK=$OVERLAY/usr/lib/inithooks/firstboot.d/45odoo
CRS=$OVERLAY/etc/coreruleset/plugins/keel-odoo-before.conf

@test "manifest: odoo, version 1, an appliance on lnpp" {
    grep -qx "manifest_version: 1" "$MANIFEST"
    grep -qx "kind: appliance" "$MANIFEST"
    grep -qx "name: odoo" "$MANIFEST"
    grep -qx "base: lnpp" "$MANIFEST"
}

@test "manifest: no process, because serve.py is the only supervisor of Odoo" {
    run ! grep -q "^processes:" "$MANIFEST"
    run ! grep -q "^checks:" "$MANIFEST"
}

@test "manifest: no overlay of its own, so the chain is Core's, Web's and LNPP's" {
    run ! grep -q "^overlays:" "$MANIFEST"
}

@test "manifest: no tabs, no CRLF" {
    run ! grep -q $'[\t\r]' "$MANIFEST"
}

@test "the image ships no other appliance manifest, so odoo is the one on top" {
    run ls "$OVERLAY/usr/share/keel/appliances"
    [ "$output" = odoo.yaml ]
}

@test "odoo.service: its own user, runs serve.py, enabled on every node" {
    grep -qx "User=odoo" "$ODOO_UNIT"
    grep -qx "Group=odoo" "$ODOO_UNIT"
    grep -qx "ExecStart=/usr/bin/python3 /usr/lib/keel-odoo/serve.py" "$ODOO_UNIT"
    grep -qx "WantedBy=multi-user.target" "$ODOO_UNIT"
    grep -qx "enable odoo.service" "$PRESET"
    run ! grep -q "keel-odoo-follow" "$PRESET"
}

@test "serve.py: the child runs odoo-bin of the pinned path and the config of the layer" {
    grep -qx 'ODOO_BIN = "/opt/odoo/18.0/odoo-bin"' "$SERVE"
    grep -qx 'CONF = "/etc/odoo/odoo.conf"' "$SERVE"
    # the gate is read only, and a read only server is not writable
    grep -q "pg_is_in_recovery()" "$SERVE"
    grep -q "transaction_read_only" "$SERVE"
}

@test "the follow timer, its service and its script are gone" {
    run ! ls "$OVERLAY/usr/lib/systemd/system/keel-odoo-follow.timer"
    run ! ls "$OVERLAY/usr/lib/systemd/system/keel-odoo-follow.service"
    run ! ls "$OVERLAY/usr/lib/keel-odoo/follow.py"
}

@test "odoo.service: no kernel tunables, no capabilities, only the address families it uses" {
    grep -qx "ProtectKernelTunables=yes" "$ODOO_UNIT"
    grep -qx "ProtectKernelModules=yes" "$ODOO_UNIT"
    grep -qx "ProtectControlGroups=yes" "$ODOO_UNIT"
    grep -qx "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" "$ODOO_UNIT"
    grep -qx "CapabilityBoundingSet=" "$ODOO_UNIT"
    grep -qx "LockPersonality=yes" "$ODOO_UNIT"
    grep -qx "RestrictSUIDSGID=yes" "$ODOO_UNIT"
}

@test "odoo.service: no write access outside the data directory, no privileges" {
    grep -qx "ProtectSystem=strict" "$ODOO_UNIT"
    grep -qx "ReadWritePaths=/var/lib/odoo" "$ODOO_UNIT"
    grep -qx "ProtectHome=yes" "$ODOO_UNIT"
    grep -qx "PrivateTmp=yes" "$ODOO_UNIT"
    grep -qx "NoNewPrivileges=yes" "$ODOO_UNIT"
}

@test "odoo.service: a start that fails again and again is not rate limited, serve.py decides" {
    grep -qx "StartLimitIntervalSec=0" "$ODOO_UNIT"
    grep -qx "Restart=on-failure" "$ODOO_UNIT"
}

@test "odoo.service: a stop reaches serve.py first, and it stops Odoo" {
    grep -qx "KillMode=mixed" "$ODOO_UNIT"
    grep -qx "TimeoutStopSec=60" "$ODOO_UNIT"
}

@test "route: the catch-all is a regular expression, because location / and location ^~ / clash with keel-web's" {
    grep -q '^location ~ \^/ {$' "$ROUTE"
    run ! grep -qE '^location (\^~ )?/ \{$' "$ROUTE"
}

@test "route: HTTP to 8069 and the websocket to 8072, on the loopback" {
    grep -q "proxy_pass http://127.0.0.1:8069;" "$ROUTE"
    grep -q "proxy_pass http://127.0.0.1:8072;" "$ROUTE"
    grep -q '^location \^~ /websocket {$' "$ROUTE"
    grep -q 'proxy_set_header Upgrade \$http_upgrade;' "$ROUTE"
    grep -q 'proxy_set_header Connection \$keel_odoo_connection;' "$ROUTE"
}

@test "route: the protocol that Odoo sees is https behind the socket of Anubis" {
    grep -q 'proxy_set_header X-Forwarded-Proto \$keel_odoo_proto;' "$ROUTE"
    grep -q 'default \$scheme;' "$MAP"
    grep -q '~^unix: https;' "$MAP"
}

@test "route: the map for the websocket header" {
    grep -q 'map \$http_upgrade \$keel_odoo_connection' "$MAP"
}

@test "odoo.conf: proxy mode, loopback only, no database list, peer authentication" {
    grep -qx "proxy_mode = True" "$CONF"
    grep -qx "http_interface = 127.0.0.1" "$CONF"
    grep -qx "list_db = False" "$CONF"
    grep -qx "db_user = odoo" "$CONF"
    # no db_host and no db_password: the unix socket and the peer method
    run ! grep -qE "^(db_host|db_password|db_port)" "$CONF"
}

@test "odoo.conf: the master password is empty, which Odoo reads as forbidden" {
    grep -qx "admin_passwd =" "$CONF"
}

@test "odoo.conf: workers, so the websocket has its own port" {
    grep -qx "workers = 2" "$CONF"
    grep -qx "gevent_port = 8072" "$CONF"
}

# Attachments are in the database and a commit waits for the synchronous
# standby (0054). Over a link of 250 ms and 1.5 % loss an upload of 4 MiB
# needs more than 120 s, and Odoo killed the worker at its default limit
# ("WorkerHTTP timeout after 120s"), so the front answered 413 after 123 s.
@test "odoo.conf: a worker may run as long as the front and the route wait" {
    grep -qx "limit_time_real = 720" "$CONF"
    grep -q 'proxy_read_timeout 720s;' "$ROUTE"
}

@test "odoo.conf: nothing writes into /opt" {
    grep -qx "data_dir = /var/lib/odoo" "$CONF"
    grep -qx "addons_path = /opt/odoo/18.0/addons,/opt/odoo/extra-addons" "$CONF"
}

@test "coraza: a CRS plugin that ends 930130 on the path of the Odoo routes only" {
    grep -q 'id:10100,' "$CRS"
    grep -q 'ctl:ruleRemoveTargetById=930130;REQUEST_FILENAME' "$CRS"
    # two rules (10100 and 10102), and none switches a whole rule off
    run grep -c '^SecRule' "$CRS"
    [ "$output" = 2 ]
    run ! grep -q 'ruleRemoveById=' "$CRS"
}

# keel-overlay-coraza 0.1.4 refuses a JSON body of more than 256 KiB
# (Keel-Linux/common#61). Odoo sends an attachment as base64 inside a
# JSON-RPC call.
@test "coraza: a JSON-RPC call to Odoo may be 16 MiB, and no more, and only a POST or PUT of JSON" {
    grep -q 'id:10102,' "$CRS"
    grep -q 'ctl:requestBodyLimit=16777216' "$CRS"
    run bash -c "grep -vE '^\s*#' '$CRS' | grep -E 'requestBodyAccess|requestBodyLimit=[0-9]{9,}'"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'requestBodyLimit' <(grep -vE '^\s*#' "$CRS"))" = 1 ]
    grep -q '"@rx \^(?:POST|PUT)\$"' "$CRS"
    grep -q '"@rx \^application/json"' "$CRS"
}

@test "coraza: the rule of the limit matches the JSON-RPC routes and nothing else" {
    rx=$(sed -n 's/^    SecRule REQUEST_FILENAME "@rx \(.*\)" "chain"$/\1/p' "$CRS")
    [ -n "$rx" ]
    check() { python3 -c 'import re, sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$rx" "$1"; }
    check /web/dataset/call_kw/ir.attachment/create
    check /web/dataset/call_button/res.partner/action_archive
    check /jsonrpc
    run ! check /web/binary/upload_attachment
    run ! check /other/jsonrpc
    run ! check /jsonrpc/x
}

@test "coraza: the base64 fields of a JSON-RPC call are not read by the Core Rule Set, and only they" {
    # one static update of the rules that carry the tag of the Core Rule Set
    run grep -c '^SecRuleUpdateTargetByTag' "$CRS_AFTER"
    [ "$output" = 1 ]
    grep -q '^SecRuleUpdateTargetByTag "OWASP_CRS" "!ARGS:/' "$CRS_AFTER"
    rx=$(sed -n 's|^SecRuleUpdateTargetByTag "OWASP_CRS" "!ARGS:/\(.*\)/"$|\1|p' "$CRS_AFTER")
    [ -n "$rx" ]
    check() { python3 -c 'import re, sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$rx" "$1"; }
    check json.params.args.0.datas
    check json.params.args.0.image_1920
    check json.params.args.0.0.db_datas
    check json.params.kwargs.values.raw
    run ! check json.params.args.0.name
    run ! check json.params.args.0.comment
    run ! check json.params.model
    run ! check json.name
    run ! check args.0.datas
    run ! check json.params.args.0.datas_fname_x
}

# Attachments are in the database and a commit waits for the synchronous
# standby (0054). Over a link of 250 ms and 1.5 % loss an upload of 10 MiB
# needs minutes, and the front waited 60 s for Anubis (504 after 63 s).
@test "front: the front waits as long as the route does for a slow upload" {
    grep -qx 'proxy_read_timeout 720s;' "$FRONT"
    grep -qx 'proxy_send_timeout 720s;' "$FRONT"
    grep -q 'proxy_read_timeout 720s;' "$ROUTE"
    grep -q 'proxy_send_timeout 720s;' "$ROUTE"
}

@test "front: the front site takes an upload as the route does, in keel-front.d" {
    grep -qx 'client_max_body_size 256m;' "$FRONT"
    grep -q 'keel-web 0.3.2' "$FRONT"
    grep -q 'keel-overlay-coraza 0.1.4' "$FRONT"
    grep -q 'client_max_body_size 256m;' "$ROUTE"
}

@test "coraza: the exclusion matches the Odoo routes and no path that is a file" {
    rx=$(sed -n 's/^SecRule REQUEST_FILENAME "@rx \(.*\)" \\$/\1/p' "$CRS")
    [ -n "$rx" ]
    check() { python3 -c 'import re, sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$rx" "$1"; }
    check /web/dataset/call_kw/res.config.settings/get_views
    check /web/dataset/call_kw/res.users.settings/set_res_users_settings
    check /web/dataset/call_button/res.partner/action_archive
    run ! check /web/dataset/call_kw/../makefile
    run ! check /web/dataset/call_kw/.../x
    run ! check /web/dataset/call_kw/res..settings/get_views
    run ! check /web/dataset/call_kw/.settings/get_views
    run ! check /web/dataset/call_kw/res.config.settings/get_views/extra
    run ! check /web/dataset/call_kw/res.config.settings/../../.git/config
    run ! check /other/web/dataset/call_kw/res.config.settings/get_views
    run ! check /.git/config
}

@test "hook: the password goes in the environment, the domain in the arguments" {
    grep -qx 'export APP_PASS' "$HOOK"
    grep -q 'bin/odoo.py" --domain="\$APP_DOMAIN"' "$HOOK"
    run ! grep -q -- '--pass=' "$HOOK"
    grep -qx 'systemctl try-restart odoo.service' "$HOOK"
}

@test "services screen: the Odoo address and the check page" {
    run grep -c "Odoo:" "$OVERLAY/etc/confconsole/services.txt"
    [ "$output" = 2 ]
    run grep -c "keel-check" "$OVERLAY/etc/confconsole/services.txt"
    [ "$output" = 2 ]
}

@test "the spec of the boot test names no appliance, because the host of the test does not know odoo" {
    run ! grep -q '^appliance:' tests/instance.yaml
}

@test "no Apache anywhere in the layer" {
    run ! grep -rIl "apache2\|a2enmod\|a2ensite" "$OVERLAY" conf.d/main plan Makefile
}

@test "build: wkhtmltopdf is the pinned upstream build with patched qt, checked by digest" {
    grep -q '^WKHTMLTOX_URL=https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/' conf.d/main
    grep -qE '^echo "[0-9a-f]{64}  \$WKHTMLTOX_DEB" \| sha256sum --check --status$' conf.d/main
    grep -q "wkhtmltopdf --version | grep -q 'with patched qt'" conf.d/main
    # the libraries of its Depends line come from Debian, through the plan
    for lib in xfonts-75dpi xfonts-base libjpeg62-turbo libssl3t64 fontconfig libxrender1; do
        grep -qx "$lib" plan/main
    done
}

@test "build: a report fetches its style sheets from the loopback, not from the public address" {
    grep -q "'report.url', 'http://127.0.0.1:8069'" conf.d/main
}

@test "build: Odoo is enabled on every node, and the front site must include keel-front.d" {
    grep -qx 'systemctl enable odoo.service' conf.d/main
    run ! grep -q 'keel-odoo-follow' conf.d/main
    grep -q 'keel-front.d/\*.conf' conf.d/main
}
