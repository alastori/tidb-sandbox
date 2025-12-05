import importlib.util
import sys
from pathlib import Path

from typing import Optional

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parents[1]


def _load_script_module(module_filename: str, module_name: str):
    module_path = SCRIPTS_DIR / f"{module_filename}.py"
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


# Ensure env_utils is available under its canonical import name
ENV_UTILS_MODULE = _load_script_module("env_utils", "env_utils")


@pytest.fixture
def load_module():
    def _loader(module_filename: str, alias: Optional[str] = None):
        name = alias or f"test_{module_filename}"
        if name in sys.modules:
            del sys.modules[name]
        return _load_script_module(module_filename, name)

    return _loader


__all__ = ["SCRIPTS_DIR", "load_module", "ENV_UTILS_MODULE"]


def pytest_configure(config):
    config.addinivalue_line("markers", "integration: opt-in tests that start Docker containers")
