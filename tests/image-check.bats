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
    printf '#!/bin/sh\necho "wkhtmltopdf 0.12.6.1 (with patched qt)"\n' > "$T/usr/local/bin/wkhtmltopdf"
    chmod +x "$T/usr/local/bin/wkhtmltopdf"
    : > "$T/opt/odoo/18.0/odoo-bin" && chmod +x "$T/opt/odoo/18.0/odoo-bin"
    echo "odoo 18.0" > "$T/opt/odoo/REVISION"
    cp "$BATS_TEST_DIRNAME/../overlay/etc/odoo/odoo.conf" "$T/etc/odoo/"
    cp "$BATS_TEST_DIRNAME/../overlay/etc/nginx/keel-default.d/60-keel-odoo.conf" \
        "$T/etc/nginx/keel-default.d/"
    for name in core web lnpp odoo; do : > "$T/usr/share/keel/appliances/$name.yaml"; done
    printf 'root:x:0:0:root:/root:/bin/bash\nodoo:x:998:998::/var/lib/odoo:/usr/sbin/nologin\n' > "$T/etc/passwd"
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
