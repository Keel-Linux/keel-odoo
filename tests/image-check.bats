#!/usr/bin/env bats
# Unit tests of conf.d/zz-check, the check that fails the build of the
# odoo layer when the image is not what decision 0059 says. It runs against
# a scratch tree named by KEEL_CONF_ROOT: a good tree first, then each
# defect alone.

bats_require_minimum_version 1.5.0

setup() {
    CHECK="$BATS_TEST_DIRNAME/../conf.d/zz-check"
    T="$BATS_TEST_TMPDIR/root"
    export KEEL_CONF_ROOT="$T"
    mkdir -p "$T/etc/systemd/system/multi-user.target.wants" "$T/etc/odoo" \
        "$T/etc/nginx/keel-default.d" "$T/usr/share/keel/appliances" \
        "$T/opt/odoo/18.0" \
        "$T/usr/local/bin" "$T/usr/lib/keel-odoo" "$T/etc/nginx/keel-front.d" \
        "$T/etc/coreruleset/plugins"
    : > "$T/etc/nginx/keel-front.d/60-keel-odoo.conf"
    mkdir -p "$T/etc/nginx/snippets"
    printf 'proxy_set_header Upgrade $http_upgrade;\nproxy_set_header Connection $keel_anubis_connection;\nproxy_pass http://[::1]:8923;\n' \
        > "$T/etc/nginx/snippets/keel-anubis.conf"
    : > "$T/etc/coreruleset/plugins/keel-odoo-before.conf"
    : > "$T/etc/coreruleset/plugins/keel-odoo-after.conf"
    ln -s /usr/lib/systemd/system/odoo.service \
        "$T/etc/systemd/system/multi-user.target.wants/odoo.service"
    : > "$T/usr/lib/keel-odoo/serve.py"
    mkdir -p "$T/usr/lib/python3/dist-packages/keel"
    printf 'FALLBACK_VERSION = "0.23.49"\n' > "$T/usr/lib/python3/dist-packages/keel/__init__.py"
    printf '#!/bin/sh\necho "wkhtmltopdf 0.12.6.1 (with patched qt)"\n' > "$T/usr/local/bin/wkhtmltopdf"
    chmod +x "$T/usr/local/bin/wkhtmltopdf"
    : > "$T/opt/odoo/18.0/odoo-bin" && chmod +x "$T/opt/odoo/18.0/odoo-bin"
    echo "odoo 18.0" > "$T/opt/odoo/REVISION"
    cp "$BATS_TEST_DIRNAME/../overlay/etc/odoo/odoo.conf" "$T/etc/odoo/"
    cp "$BATS_TEST_DIRNAME/../overlay/etc/nginx/keel-default.d/60-keel-odoo.conf" \
        "$T/etc/nginx/keel-default.d/"
    for name in core web lnpp; do : > "$T/usr/share/keel/appliances/$name.yaml"; done
    # the real manifest: the check reads the paths it replicates
    cp "$BATS_TEST_DIRNAME/../overlay/usr/share/keel/appliances/odoo.yaml" \
        "$T/usr/share/keel/appliances/"
    mkdir -p "$T/var/lib/odoo/filestore" "$T/opt/odoo/extra-addons"
    : > "$T/etc/nginx/keel-front.d/61-keel-odoo-assets.conf"
    : > "$T/etc/nginx/keel-default.d/59-keel-odoo-assets.conf"
    mkdir -p "$T/var/cache/nginx/keel-odoo-assets"
    # the owner of the scratch tree stands for odoo and for www-data
    printf 'root:x:0:0:root:/root:/bin/bash\nodoo:x:%s:%s::/var/lib/odoo:/usr/sbin/nologin\nwww-data:x:%s:%s::/var/www:/usr/sbin/nologin\n' \
        "$(id -u)" "$(id -g)" "$(id -u)" "$(id -g)" > "$T/etc/passwd"
}

@test "a good tree passes" {
    run "$CHECK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Apache in the image fails the build" {
    mkdir -p "$T/usr/sbin" && : > "$T/usr/sbin/apache2"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: Apache is in the image"* ]]
}

@test "an apache2 unit fails the build too" {
    mkdir -p "$T/usr/lib/systemd/system" && : > "$T/usr/lib/systemd/system/apache2.service"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL: Apache is in the image"* ]]
}

@test "no Odoo fails the build" {
    rm "$T/opt/odoo/18.0/odoo-bin"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"odoo-bin is not in the image"* ]]
}

@test "no recorded revision fails the build" {
    rm "$T/opt/odoo/REVISION"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"REVISION is not in the image"* ]]
}

@test "a git directory in the checkout fails the build" {
    mkdir "$T/opt/odoo/18.0/.git"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *".git is in the image"* ]]
}

@test "no odoo user fails the build" {
    sed -i '/^odoo:/d' "$T/etc/passwd"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"odoo is not a system user"* ]]
}

@test "an odoo user with a shell fails the build" {
    sed -i 's|/usr/sbin/nologin|/bin/bash|' "$T/etc/passwd"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"odoo has a shell"* ]]
}

@test "a database password in odoo.conf fails the build" {
    echo "db_password = x" >> "$T/etc/odoo/odoo.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"names a database password or host"* ]]
}

@test "a master password in the image fails the build" {
    sed -i 's/^admin_passwd =.*/admin_passwd = admin/' "$T/etc/odoo/odoo.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"holds a master password"* ]]
}

@test "odoo.service not enabled fails the build: nothing would load Odoo" {
    rm "$T/etc/systemd/system/multi-user.target.wants/odoo.service"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"odoo.service is not enabled"* ]]
}

@test "the serve script missing fails the build" {
    rm "$T/usr/lib/keel-odoo/serve.py"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"serve.py is not in the image"* ]]
}

@test "a follow timer left in the image fails the build: two supervisors of Odoo" {
    mkdir -p "$T/etc/systemd/system/timers.target.wants"
    ln -s /usr/lib/systemd/system/keel-odoo-follow.timer \
        "$T/etc/systemd/system/timers.target.wants/keel-odoo-follow.timer"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-odoo-follow.timer is enabled"* ]]
}

@test "no wkhtmltopdf fails the build" {
    rm "$T/usr/local/bin/wkhtmltopdf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"wkhtmltopdf is not in the image"* ]]
}

@test "a wkhtmltopdf without patched qt fails the build: headers and footers do not print" {
    printf '#!/bin/sh\necho "wkhtmltopdf 0.12.6"\n' > "$T/usr/local/bin/wkhtmltopdf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"wkhtmltopdf is not the build with patched qt"* ]]
}

@test "no body limit for the front site fails the build: an upload would stop at 1 MB behind Anubis" {
    rm "$T/etc/nginx/keel-front.d/60-keel-odoo.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the body limit of the front site"* ]]
}

@test "an Anubis snippet that does not pass the Upgrade header fails the build: the bus of Odoo would not work" {
    printf 'proxy_pass http://[::1]:8923;\n' > "$T/etc/nginx/snippets/keel-anubis.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not pass the Upgrade header"* ]]
}

@test "a keel older than 0.23.49 fails the build: the stop of PostgreSQL could wait for an idle client" {
    printf 'FALLBACK_VERSION = "0.23.48"\n' > "$T/usr/lib/python3/dist-packages/keel/__init__.py"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel 0.23.48 is older than 0.23.49"* ]]
}

@test "a newer keel passes, with the version compared as numbers" {
    printf 'FALLBACK_VERSION = "0.23.100"\n' > "$T/usr/lib/python3/dist-packages/keel/__init__.py"
    run "$CHECK"
    [ "$status" -eq 0 ]
}

@test "no keel package fails the build" {
    rm "$T/usr/lib/python3/dist-packages/keel/__init__.py"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the version of keel is not in the image"* ]]
}

@test "a missing rule file fails the build" {
    rm "$T/etc/coreruleset/plugins/keel-odoo-after.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-odoo-after.conf is not in the image"* ]]
}

@test "no route in the include directory fails the build" {
    rm "$T/etc/nginx/keel-default.d/60-keel-odoo.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"route of Odoo is not in keel-web's include directory"* ]]
}

@test "no odoo manifest fails the build" {
    rm "$T/usr/share/keel/appliances/odoo.yaml"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"odoo.yaml is not in the image"* ]]
}

@test "a database layer manifest on top fails the build" {
    : > "$T/usr/share/keel/appliances/postgresql.yaml"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"postgresql.yaml is in the image"* ]]
}

@test "every defect is reported, not only the first" {
    rm "$T/opt/odoo/18.0/odoo-bin" "$T/opt/odoo/REVISION"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"odoo-bin"* ]]
    [[ "$output" == *"REVISION"* ]]
}

# The stack check of lnpp is not part of the Odoo product (BR1 and BR2,
# 2026-11-06, the commissioning test): its first boot hook made the test
# database keel_check, and its page /keel-check/ showed the stack to
# anybody who asked.
@test "the first boot hook of lnpp's check page fails the build" {
    mkdir -p "$T/usr/lib/inithooks/firstboot.d"
    : > "$T/usr/lib/inithooks/firstboot.d/40lnpp-check"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"40lnpp-check is in the image"* ]]
}

@test "the route of lnpp's check page fails the build" {
    : > "$T/etc/nginx/keel-default.d/50-keel-lnpp.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"50-keel-lnpp.conf is in the image"* ]]
}

@test "the application of lnpp's check page fails the build" {
    mkdir -p "$T/usr/share/keel-lnpp/app"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/usr/share/keel-lnpp is in the image"* ]]
}

@test "the socket of lnpp's check page fails the build, and so does the socket left enabled" {
    mkdir -p "$T/usr/lib/systemd/system" "$T/etc/systemd/system/sockets.target.wants"
    : > "$T/usr/lib/systemd/system/keel-lnpp-check.socket"
    ln -s /usr/lib/systemd/system/keel-lnpp-check.socket \
        "$T/etc/systemd/system/sockets.target.wants/keel-lnpp-check.socket"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/usr/lib/systemd/system/keel-lnpp-check.socket is in the image"* ]]
    [[ "$output" == *"sockets.target.wants/keel-lnpp-check.socket is in the image"* ]]
}

# Until keel-lnpp 19.0-9 lnpp's manifest named the page as a process, so its
# service unit stayed in the Odoo image with nothing that could start it,
# and Monit sent a critical alert on each node (release A3, 2026-11-10).
@test "the service unit of lnpp's check page fails the build: nothing can start it" {
    mkdir -p "$T/usr/lib/systemd/system"
    : > "$T/usr/lib/systemd/system/keel-lnpp-check.service"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/usr/lib/systemd/system/keel-lnpp-check.service is in the image"* ]]
}

@test "the user of lnpp's check page fails the build: no process of Odoo runs as it" {
    printf 'keel-check:x:997:997::/nonexistent:/usr/sbin/nologin\n' >> "$T/etc/passwd"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"keel-check is a user of the image"* ]]
}

# keel writes the marker of a file sync folder only where the path is
# there, and the file sync unit can write only a path that is there when
# it starts. With no filestore in the image the folder of each node of a
# pair was in error, "folder path missing" (release A3, 2026-11-10).
@test "no filestore in the image fails the build: the file sync folder of a pair would be in error" {
    rmdir "$T/var/lib/odoo/filestore"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/var/lib/odoo/filestore is not a directory of the image"* ]]
    [[ "$output" != *"/opt/odoo/extra-addons"* ]]
}

@test "no directory of the run-time addons fails the build too: the manifest replicates it" {
    rmdir "$T/opt/odoo/extra-addons"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/opt/odoo/extra-addons is not a directory of the image"* ]]
}

@test "a replicated path that is a file fails the build" {
    rmdir "$T/opt/odoo/extra-addons" && : > "$T/opt/odoo/extra-addons"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/opt/odoo/extra-addons is not a directory of the image"* ]]
}

# keel's schema allows an entry {path: P, unless: S} beside a plain path.
@test "a replicated path written as a mapping is required too" {
    sed -i 's|^    - /opt/odoo/extra-addons$|    - {path: /opt/odoo/extra-addons, unless: database}|' \
        "$T/usr/share/keel/appliances/odoo.yaml"
    run "$CHECK"
    [ "$status" -eq 0 ]
    rmdir "$T/opt/odoo/extra-addons"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/opt/odoo/extra-addons is not a directory of the image"* ]]
}

@test "a manifest that cannot be read fails the build, and the later defects are reported too" {
    printf 'state: [unclosed\n' > "$T/usr/share/keel/appliances/odoo.yaml"
    : > "$T/usr/share/keel/appliances/postgresql.yaml"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"odoo.yaml: state.replicate cannot be read"* ]]
    [[ "$output" == *"postgresql.yaml is in the image"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "a filestore that odoo does not own fails the build: Odoo could not write a file" {
    sed -i 's/^odoo:x:[0-9]*:/odoo:x:4243:/' "$T/etc/passwd"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/var/lib/odoo/filestore is not owned by odoo"* ]]
}

@test "a manifest that replicates nothing passes: there is no path to require" {
    sed -i '/^state:/,$d' "$T/usr/share/keel/appliances/odoo.yaml"
    rmdir "$T/var/lib/odoo/filestore" "$T/opt/odoo/extra-addons"
    run "$CHECK"
    [ "$status" -eq 0 ]
}

@test "no cache of the asset bundles in the front fails the build: behind Anubis a style sheet can get the challenge" {
    rm "$T/etc/nginx/keel-front.d/61-keel-odoo-assets.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the cache of the asset bundles is not in keel-front.d"* ]]
}

@test "no route of the asset bundles fails the build: Odoo would set a cookie, and nothing is stored" {
    rm "$T/etc/nginx/keel-default.d/59-keel-odoo-assets.conf"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the route of the asset bundles is not in keel-web's include directory"* ]]
}

@test "no cache directory fails the build: nginx -t would fail" {
    rmdir "$T/var/cache/nginx/keel-odoo-assets"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/var/cache/nginx/keel-odoo-assets is not in the image"* ]]
}

@test "a cache directory that www-data does not own fails the build" {
    sed -i 's/^www-data:x:[0-9]*:/www-data:x:4242:/' "$T/etc/passwd"
    run "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not owned by www-data"* ]]
}
