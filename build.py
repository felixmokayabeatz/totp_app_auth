#!/usr/bin/env python3
"""Wrapper that launches the real build script from otp_auth_app/build.py."""

from __future__ import annotations

import importlib.util
import os
import stat
import sys
from pathlib import Path


def ensure_inner_script_executable(script_path: Path) -> None:
    """Make the inner build script executable on POSIX systems."""
    if os.name != "posix":
        return

    current_mode = script_path.stat().st_mode
    desired_mode = current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    if desired_mode != current_mode:
        script_path.chmod(desired_mode)


def load_inner_build_script():
    """Load the inner build script as a module from its file path."""
    project_root = Path(__file__).resolve().parent
    script_path = project_root / "otp_auth_app" / "build.py"

    if not script_path.exists():
        raise FileNotFoundError(f"Inner build script not found: {script_path}")

    ensure_inner_script_executable(script_path)

    spec = importlib.util.spec_from_file_location("otp_auth_app_build", script_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Could not load module spec for {script_path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, script_path


def main() -> int:
    module, script_path = load_inner_build_script()

    os.chdir(script_path.parent)

    if hasattr(module, "main_menu"):
        module.main_menu()
        return 0

    raise AttributeError(f"{script_path} does not define main_menu()")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n\nBuild cancelled. Goodbye!")
        raise SystemExit(0)
