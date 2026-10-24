# Tests

What a test means for a layer recipe is written in `COVERAGE.md`: the
recipe builds, the result boots in an LXC container, its first boot
completes headless from an instance spec, the admin user of Odoo logs in
with the password that the spec declared, and the machine matches the
spec.

## Layout

- `boot-test.sh`, `lib/boot-test-lib.sh`, `boot-test.bats`: the boot test.
  It has the steps of the boot test of keel-lnpp (database password,
  Webmin, the check page at `/keel-check/`, `keel diff`) and the Odoo
  steps: `/web/login` answers with its form, the admin user logs in with
  `secrets.app_password`, a script bundle of the web client comes back
  with content, the websocket answers 101, and a report prints as PDF with
  its header and footer (`lib/odoo-pdf.py`) (the bundles are attachments, stored in the database). The
  image build per merge (decision 0061) runs it.
- `layer.bats`: the files of the overlay, with grep.
- `manifest.bats`, `lib/manifest-root.sh`: the state the manifest replicates
  (0050), and keel's own validator when `KEEL_SRC` names a checkout of keel
  and `KEEL_MANIFEST_SOURCES` names the checkouts of keel-core, keel-web,
  keel-lnpp and common.
- `image-check.bats`: `conf.d/zz-check` against a scratch tree named by
  `KEEL_CONF_ROOT`: a good tree, then each defect alone.
- `python/`: the first boot hook and `serve.py` under pytest.
- `stack.bats`: Nginx with keel-web's real sites and two stub servers on
  the ports of Odoo, as root, only where `KEEL_ODOO_STACK_TEST=1` and
  `KEEL_WEB_SRC` names a checkout of keel-web.
- `coverage.sh`: the bats suite under kcov.

## Run them

No root, no network:

    bats tests/
    COVERAGE_THRESHOLD=100 tests/coverage.sh
    python3 -m pytest -q tests/python

The handbook keeps the evidence of each run on the real platform
(decision 0053).
