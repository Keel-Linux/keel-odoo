# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the
project writes) and 0004 (bats plus kcov for shell; a build and a boot on
LXC as the acceptance test of a recipe).

## Measured 2026-10-18

| File | Test | Coverage | Note |
| --- | --- | --- | --- |
| overlay/usr/lib/inithooks/bin/odoo.py | tests/python/test_odoo_hook.py | 100 percent of lines and branches, coverage.py | the first boot hook; a fake passlib and a fake psql |
| overlay/usr/lib/keel-odoo/follow.py | tests/python/test_follow.py | 100 percent of lines and branches, coverage.py | Odoo follows the writable PostgreSQL |
| conf.d/zz-check | tests/image-check.bats | 100 percent, kcov | every defect alone, and all reported |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats | 100 percent, kcov | with the verdicts of the Odoo login |
| The files of the overlay | tests/layer.bats | grep | the manifest, the units, the preset, the route, odoo.conf |
| Nginx with keel-web's sites | tests/stack.bats | integration | the job `stack`: nginx -t, the routes, the websocket headers, https behind Anubis |
| conf.d/main | the build | integration only | build time script |
| firstboot.d/45odoo | the boot test | integration only | three lines that call odoo.py |
| tests/boot-test.sh | itself | integration only | the thin main of the boot test |

`tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which the workflow
sets to 100, the measured number. It is only ever raised (decision 0006).
