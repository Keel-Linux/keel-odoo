#!/bin/bash
# manifest-root.sh ROOT MANIFEST: a scratch root that keel's manifest
# validator can resolve MANIFEST in. It holds the appliance manifests of
# Core, Web and LNPP, the overlay manifests of common, MANIFEST itself, and
# an empty unit file for every unit that one of them names, and an empty
# executable for every hook path under /usr/lib. KEEL_MANIFEST_SOURCES
# names a directory with checkouts of keel-core, keel-web, keel-lnpp and
# common. A test helper: not shipped.
set -euo pipefail
root=$1 manifest=$2
src=${KEEL_MANIFEST_SOURCES:?KEEL_MANIFEST_SOURCES names the checkouts of keel-core, keel-web, keel-lnpp and common}
apps="$root/usr/share/keel/appliances"
overlays="$root/usr/share/keel/overlays"
units="$root/usr/lib/systemd/system"
mkdir -p "$apps" "$overlays" "$units"
cp "$src/keel-core/packages/keel-core/manifest.yaml" "$apps/core.yaml"
cp "$src/keel-web/packages/keel-web/manifest.yaml" "$apps/web.yaml"
cp "$src/keel-lnpp/overlay/usr/share/keel/appliances/lnpp.yaml" "$apps/lnpp.yaml"
cp "$manifest" "$apps/"
for file in "$src"/common/packages/*/manifest.yaml; do
    name=$(sed -n 's/^name: *//p' "$file" | head -1)
    cp "$file" "$overlays/$name.yaml"
done
grep -rhoE 'unit: *[A-Za-z0-9@._-]+\.service' "$apps" "$overlays" \
    | sed 's/unit: *//' | sort -u | while read -r unit; do
    : > "$units/$unit"
    case "$unit" in
        *@?*.service) : > "$units/${unit%%@*}@.service" ;;
    esac
done
grep -rhoE '/usr/lib/[A-Za-z0-9/._-]+' "$apps" "$overlays" | sort -u | while read -r hook; do
    case "$hook" in */systemd/*) continue ;; esac
    mkdir -p "$root$(dirname "$hook")"
    install -m 0755 /dev/null "$root$hook"
done
