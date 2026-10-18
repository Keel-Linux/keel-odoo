#!/usr/bin/env bats
# The files that the Odoo layer ships (handbook decision 0059): the
# appliance manifest, the units, the Nginx route and the configuration.
# keel's own schema check runs on a booted machine (tests/stack.bats); these
# checks keep the files from drifting, with no dependency beyond grep.

bats_require_minimum_version 1.5.0

OVERLAY=overlay
MANIFEST=$OVERLAY/usr/share/keel/appliances/odoo.yaml
ODOO_UNIT=$OVERLAY/usr/lib/systemd/system/odoo.service
FOLLOW_UNIT=$OVERLAY/usr/lib/systemd/system/keel-odoo-follow.service
TIMER=$OVERLAY/usr/lib/systemd/system/keel-odoo-follow.timer
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

@test "manifest: no process, because the follow script is the only supervisor of Odoo" {
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

@test "odoo.service: its own user, from /opt/odoo, no Install section" {
    grep -qx "User=odoo" "$ODOO_UNIT"
    grep -qx "Group=odoo" "$ODOO_UNIT"
    grep -q "^ExecStart=/usr/bin/python3 /opt/odoo/18.0/odoo-bin --config /etc/odoo/odoo.conf$" "$ODOO_UNIT"
    # Debian's presets enable every unit that has an Install section.
    run ! grep -q "^\[Install\]" "$ODOO_UNIT"
}

@test "odoo.service: no write access outside the data directory, no privileges" {
    grep -qx "ProtectSystem=strict" "$ODOO_UNIT"
    grep -qx "ReadWritePaths=/var/lib/odoo" "$ODOO_UNIT"
    grep -qx "ProtectHome=yes" "$ODOO_UNIT"
    grep -qx "PrivateTmp=yes" "$ODOO_UNIT"
    grep -qx "NoNewPrivileges=yes" "$ODOO_UNIT"
}

@test "odoo.service: a start that fails again and again is not rate limited, the timer decides" {
    grep -qx "StartLimitIntervalSec=0" "$ODOO_UNIT"
    grep -qx "Restart=no" "$ODOO_UNIT"
}

@test "follow service and timer: a oneshot as root, every 3 seconds, enabled by the timer" {
    grep -qx "Type=oneshot" "$FOLLOW_UNIT"
    grep -qx "ExecStart=/usr/bin/python3 /usr/lib/keel-odoo/follow.py" "$FOLLOW_UNIT"
    grep -qx "LogLevelMax=notice" "$FOLLOW_UNIT"
    grep -qx "OnUnitActiveSec=3s" "$TIMER"
    grep -qx "OnBootSec=10s" "$TIMER"
    grep -qx "WantedBy=timers.target" "$TIMER"
}

@test "preset: the timer is on and Odoo is off" {
    grep -qx "enable keel-odoo-follow.timer" "$PRESET"
    grep -qx "disable odoo.service" "$PRESET"
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

@test "odoo.conf: nothing writes into /opt" {
    grep -qx "data_dir = /var/lib/odoo" "$CONF"
    grep -qx "addons_path = /opt/odoo/18.0/addons,/opt/odoo/extra-addons" "$CONF"
}

@test "coraza: a CRS plugin that ends 930130 on the path of the Odoo routes only" {
    grep -q 'id:10100,' "$CRS"
    grep -q 'ctl:ruleRemoveTargetById=930130;REQUEST_FILENAME' "$CRS"
    # the model is a plain name: no slash and no dot segment can reach the exclusion
    grep -qF '^/web/dataset/(?:call_kw|call_button)/[a-z0-9_.]+/[a-z0-9_]+$' "$CRS"
    # one rule, and it does not switch the rule off for arguments or headers
    run grep -c '^SecRule' "$CRS"
    [ "$output" = 1 ]
    run ! grep -q 'ruleRemoveById=' "$CRS"
}

@test "hook: a thin wrapper that hands the spec's values to odoo.py" {
    grep -q 'bin/odoo.py" --pass="\$APP_PASS" --domain="\$APP_DOMAIN"' "$HOOK"
}

@test "services screen: the Odoo address and the check page" {
    run grep -c "Odoo:" "$OVERLAY/etc/confconsole/services.txt"
    [ "$output" = 2 ]
    run grep -c "keel-check" "$OVERLAY/etc/confconsole/services.txt"
    [ "$output" = 2 ]
}

@test "no Apache anywhere in the layer" {
    run ! grep -rIl "apache2\|a2enmod\|a2ensite" "$OVERLAY" conf.d/main plan Makefile
}
