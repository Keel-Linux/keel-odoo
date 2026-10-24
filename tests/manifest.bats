#!/usr/bin/env bats
# The state the appliance manifest of Keel Odoo replicates (handbook
# decision 0050, amendment of 2026-10-20): the filestore under the data_dir
# of /etc/odoo/odoo.conf and the run-time addons path of addons_path. The
# grep and yaml checks need nothing; the last two tests run keel's own
# validator when KEEL_SRC names a checkout of Keel-Linux/keel and
# KEEL_MANIFEST_SOURCES names the checkouts of keel-core, keel-web,
# keel-lnpp and common (tests/lib/manifest-root.sh).

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MANIFEST="$REPO/overlay/usr/share/keel/appliances/odoo.yaml"
}

manifest() {
    python3 -c 'import sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$MANIFEST" "$1"
}

@test "manifest: the overlay ships it" {
    [ -f "$MANIFEST" ]
}

@test "manifest: an appliance named odoo, version 1, on lnpp" {
    [ "$(manifest 'm["manifest_version"]')" = 1 ]
    [ "$(manifest 'm["kind"]')" = appliance ]
    [ "$(manifest 'm["name"]')" = odoo ]
    [ "$(manifest 'm["base"]')" = lnpp ]
}

@test "manifest: the state it replicates is the filestore and the run-time addons (0050)" {
    [ "$(manifest 'm["state"]["replicate"]')" = "['/var/lib/odoo/filestore', '/opt/odoo/extra-addons']" ]
}

@test "manifest: the replicated paths are those odoo.conf names" {
    # the filestore is data_dir plus filestore: the data_dir of the image
    grep -qx "data_dir = /var/lib/odoo" "$REPO/overlay/etc/odoo/odoo.conf"
    # the run-time half of addons_path, where an addon installed from the
    # interface lands; the other half is the shipped code of the layer
    grep -qx "addons_path = /opt/odoo/18.0/addons,/opt/odoo/extra-addons" "$REPO/overlay/etc/odoo/odoo.conf"
}

@test "manifest: sessions are inside no replicated path, so no exclude is declared" {
    [ "$(manifest 'm["state"].get("exclude")')" = None ]
}

@test "manifest: no tabs, no CRLF" {
    run ! grep -q $'[\t\r]' "$MANIFEST"
}

@test "manifest: keel validates it and resolves it along lnpp, web and core" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run "$REPO/tests/lib/manifest-root.sh" "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    run env PYTHONPATH="$KEEL_SRC" python3 -m keel manifest validate --root "$BATS_TEST_TMPDIR/root" odoo
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "manifest: the example specs and the boot test's spec hold against it" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run "$REPO/tests/lib/manifest-root.sh" "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    for spec in keel/instance.example.yaml keel/instance.pair.example.yaml tests/instance.yaml; do
        run env PYTHONPATH="$KEEL_SRC" python3 -m keel spec validate --spec "$REPO/$spec" \
            --no-secret-files --root "$BATS_TEST_TMPDIR/root"
        echo "$spec: $output"
        [ "$status" -eq 0 ]
    done
}
