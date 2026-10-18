"""The first boot hook and the follow script are files of the overlay, not
packages. Each file is
loaded under a name that does not hide the odoo package."""
import importlib.machinery
import importlib.util
import os

import pytest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
HOOK = os.path.join(ROOT, "overlay", "usr", "lib", "inithooks", "bin", "odoo.py")
FOLLOW = os.path.join(ROOT, "overlay", "usr", "lib", "keel-odoo", "follow.py")


def _load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def hook():
    return _load("keel_odoo_hook", HOOK)


@pytest.fixture(scope="session")
def follow():
    return _load("keel_odoo_follow", FOLLOW)
