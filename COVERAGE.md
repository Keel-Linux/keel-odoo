# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the
project writes) and 0004 (bats plus kcov for shell; a build and a boot on
LXC as the acceptance test of a recipe).

## Measured 2026-11-10

| File | Test | Coverage | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/bin/odoo.py | tests/python/test_odoo_hook.py | 100 percent of lines and branches, coverage.py | the first boot hook; a fake passlib and a fake psql |
| overlay/usr/lib/keel-odoo/serve.py | tests/python/test_serve.py | 100 percent of lines and branches, coverage.py | Odoo serves on the writable node only; the process start and the signals are integration only |
| conf.d/zz-check | tests/image-check.bats | 100 percent (68/68), kcov | every defect alone, and all reported; no part of lnpp's check page, its service unit and its user too; each path that odoo.yaml replicates is a directory, and odoo owns the filestore; the cache of the asset bundles, its route and its directory |
| overlay/usr/lib/inithooks/firstboot.d/45odoo | tests/hook.bats (5 tests) | 100 percent (10/10), kcov | a declared password, a headless boot that defers to keel-init, a console, a failure of odoo.py |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats | 100 percent (208/208), kcov | with the verdicts of the Odoo login, the websocket, the PDF and no check page |
| The files of the overlay | tests/layer.bats | grep | the manifest, the units, the preset, the route, odoo.conf |
| `overlay/usr/share/keel/appliances/odoo.yaml` | `tests/manifest.bats` (10 tests) | grep and keel validate | the state it replicates (0050), against odoo.conf; keel validates it and the three specs with no warning when `KEEL_SRC` names a checkout of keel; the contract's instance has the example's shape |
| Nginx with keel-web's sites | tests/stack.bats | integration | the job `stack`: nginx -t, the routes, the websocket headers, https behind Anubis, the bundles without cookies, the cache of the front with a stub of Anubis |
| conf.d/main | the build | integration only | build time script |
| tests/boot-test.sh | itself | integration only | the thin main of the boot test |

`tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which the workflow
sets to 100, the measured number. It is only ever raised (decision 0006).
