
from __future__ import annotations

import os
import shutil
import subprocess
import platform
import sys
import json
import glob
import re
import tarfile
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_DIR = SCRIPT_DIR
PROJECT_DIR = str(SCRIPT_DIR)
FINAL_BUILDS_DIR = WORKSPACE_DIR / "final_builds"
BUILD_LOGS_DIR = SCRIPT_DIR / "build_logs"
CONFIG_FILE = str(WORKSPACE_DIR / "build_config.json")
PUBSPEC_FILE = SCRIPT_DIR / "pubspec.yaml"
APP_BUILD_INFO_FILE = SCRIPT_DIR / "lib" / "config" / "app_build_info.dart"
INNO_SCRIPT_DIR = WORKSPACE_DIR / "inno_script"
VC_REDIST_DIR = WORKSPACE_DIR / "vc_redist"
INNO_SCRIPT_SEEDS = [
    INNO_SCRIPT_DIR / "BeatzLock v1.iss",
    INNO_SCRIPT_DIR / "BeatzLock.iss",
    WORKSPACE_DIR / "BeatzLock v1.iss",
    WORKSPACE_DIR / "BeatzLock.iss",
]

LINUX_DIR = str(FINAL_BUILDS_DIR / "linux")
FEDORA_DIR = str(FINAL_BUILDS_DIR / "fedora")
WINDOWS_DIR = str(FINAL_BUILDS_DIR / "windows")
ANDROID_DIR = str(FINAL_BUILDS_DIR / "android")
BUILD_TOOLS_DIR = WORKSPACE_DIR / ".build_tools" / "bin"
RPM_BUILD_DIR = WORKSPACE_DIR / "rpm_pkg"

APP_NAME = "BeatzLock"
DEB_PACKAGE_NAME = "beatzlock"
RPM_PACKAGE_NAME = "beatzlock"
RPM_ARCH = "x86_64"
RPM_LICENSE = "LicenseRef-Proprietary"
LINUX_APPLICATION_ID = "com.beatzlock.auth"
APP_MAINTAINER = "Felix Mokaya <info@example.com>"
APP_DESCRIPTION = "BeatzLock OTP Authentication App"

class Colors:
    """ANSI color codes for terminal output"""
    if platform.system() == "Windows":
        pass
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    PURPLE = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    END = '\033[0m'

def print_color(text, color=Colors.WHITE):
    """Print colored text (works on both Windows and Linux)"""
    if hasattr(sys.stdout, 'isatty') and sys.stdout.isatty():
        print(f"{color}{text}{Colors.END}")
    else:
        print(text)

def load_flutter_version():
    """Read version and build number from pubspec.yaml."""
    version_line_prefix = "version:"
    try:
        for line in PUBSPEC_FILE.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith(version_line_prefix):
                raw_version = stripped.split(":", 1)[1].strip()
                if "+" in raw_version:
                    semver, build_number = raw_version.split("+", 1)
                else:
                    semver, build_number = raw_version, "1"
                return raw_version, semver, build_number
    except FileNotFoundError:
        pass

    raise FileNotFoundError(f"Unable to read Flutter version from {PUBSPEC_FILE}")

APP_FULL_VERSION = ""
APP_VERSION = ""
APP_BUILD_NUMBER = ""
APP_ARTIFACT_VERSION = ""
SUPPORTED_BUILD_LOG_PLATFORMS = ("windows", "linux", "fedora", "android")
RPM_BASED_LINUX_IDS = {
    "fedora",
    "rhel",
    "centos",
    "rocky",
    "almalinux",
    "ol",
    "opensuse",
    "opensuse-leap",
    "opensuse-tumbleweed",
    "sles",
}
DEB_BASED_LINUX_IDS = {"debian", "ubuntu", "kali", "linuxmint", "pop"}


def get_platform_version_dir(platform_name: str) -> Path:
    """Return final_builds/<platform>/<version>/ for released artifacts."""
    return FINAL_BUILDS_DIR / platform_name / APP_ARTIFACT_VERSION


def get_build_log_dir(platform_name: str) -> Path:
    """Return otp_auth_app/build_logs/<platform>/ for incremental JSON logs."""
    return BUILD_LOGS_DIR / platform_name


def read_os_release() -> dict[str, str]:
    """Read Linux distribution metadata from /etc/os-release."""
    os_release_path = Path("/etc/os-release")
    if platform.system() != "Linux" or not os_release_path.exists():
        return {}

    values: dict[str, str] = {}
    for line in os_release_path.read_text(encoding="utf-8").splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"')
    return values


def get_linux_distribution_id() -> str:
    """Return the lower-case Linux distribution ID when available."""
    return read_os_release().get("ID", "").lower()


def is_rpm_based_linux() -> bool:
    """Detect Fedora/RHEL/openSUSE style distributions."""
    distro_id = get_linux_distribution_id()
    if distro_id in RPM_BASED_LINUX_IDS:
        return True
    return shutil.which("dnf") is not None or shutil.which("zypper") is not None


def get_linux_desktop_install_commands(include_rpm=False) -> list[str]:
    """Return install commands for the current Linux packaging family."""
    distro_id = get_linux_distribution_id()

    if distro_id in RPM_BASED_LINUX_IDS or shutil.which("dnf"):
        packages = [
            "clang",
            "cmake",
            "gcc-c++",
            "gtk3-devel",
            "libsecret-devel",
            "libstdc++-devel",
            "libwebp-devel",
            "mesa-libGLU",
            "ninja-build",
            "pkgconf-pkg-config",
        ]
        if include_rpm:
            packages.extend([
                "desktop-file-utils",
                "patchelf",
                "rpm-build",
                "rpmdevtools",
                "xdg-utils",
            ])
        return [f"sudo dnf install -y {' '.join(packages)}"]

    if distro_id in DEB_BASED_LINUX_IDS or shutil.which("apt"):
        packages = [
            "clang",
            "cmake",
            "libgtk-3-dev",
            "libsecret-1-dev",
            "libstdc++-12-dev",
            "libwebp-dev",
            "libglu1-mesa",
            "ninja-build",
            "pkg-config",
        ]
        if include_rpm:
            packages.extend(["desktop-file-utils", "patchelf", "rpm", "xdg-utils"])
        return [
            "sudo apt update",
            f"sudo apt install -y {' '.join(packages)}",
        ]

    packages = (
        "clang cmake gcc-c++ gtk3-devel libstdc++-devel libwebp-devel "
        "mesa-libGLU ninja-build pkg-config"
    )
    if include_rpm:
        packages += " desktop-file-utils patchelf rpm-build rpmdevtools xdg-utils"
    return [f"Install these packages with your distro package manager: {packages}"]


def sanitize_rpm_value(value: str, fallback: str) -> str:
    """Keep RPM Version/Release values inside rpm's accepted character set."""
    sanitized = re.sub(r"[^A-Za-z0-9._+~]", "_", value.strip())
    return sanitized or fallback


def get_versioned_inno_script_path() -> Path:
    return INNO_SCRIPT_DIR / f"beatzlock_{APP_ARTIFACT_VERSION}.iss"


def get_windows_app_dir() -> Path:
    return get_platform_version_dir("windows") / "app"


def get_windows_installer_dir() -> Path:
    return get_platform_version_dir("windows")


def get_windows_installer_path() -> Path:
    return get_windows_installer_dir() / f"beatzlock_{APP_ARTIFACT_VERSION}_x64.exe"


def to_inno_path(path: Path) -> str:
    return str(path).replace("/", "\\")


def remove_tree_force(path: Path) -> None:
    """Remove generated build folders, including read-only Windows files."""
    def handle_remove_error(function, failed_path, _exc_info):
        os.chmod(failed_path, 0o700)
        function(failed_path)

    shutil.rmtree(path, onerror=handle_remove_error)


def find_inno_setup_script() -> Path | None:
    candidates = []
    candidates.append(get_versioned_inno_script_path())
    candidates.extend(sorted(INNO_SCRIPT_DIR.glob("beatzlock_*.iss"), reverse=True))
    candidates.extend(INNO_SCRIPT_SEEDS)
    candidates.extend(sorted(WORKSPACE_DIR.glob("beatzlock_*.iss"), reverse=True))

    seen = set()
    for candidate in candidates:
        normalized = str(candidate).lower()
        if normalized in seen:
            continue
        seen.add(normalized)
        if candidate.exists():
            return candidate

    return None


def refresh_version_context(announce=False):
    """Reload version info from pubspec.yaml."""
    global APP_FULL_VERSION, APP_VERSION, APP_BUILD_NUMBER, APP_ARTIFACT_VERSION

    app_full_version, app_version, app_build_number = load_flutter_version()
    app_artifact_version = f"{app_version}_{app_build_number}"

    APP_FULL_VERSION = app_full_version
    APP_VERSION = app_version
    APP_BUILD_NUMBER = app_build_number
    APP_ARTIFACT_VERSION = app_artifact_version
    sync_app_build_info()

    if announce:
        print_color(f"Using app version: {APP_FULL_VERSION}", Colors.GREEN)

def sync_app_build_info():
    """Keep the bundled fallback version in sync with pubspec.yaml."""
    if not APP_BUILD_INFO_FILE.exists():
        return False

    original_text = APP_BUILD_INFO_FILE.read_text(encoding="utf-8")
    updated_lines = []
    saw_version = False
    saw_build_number = False

    for line in original_text.splitlines():
        stripped = line.strip()
        indent = line[: len(line) - len(line.lstrip())]

        if stripped.startswith("static const String version = '"):
            updated_lines.append(
                f"{indent}static const String version = '{APP_VERSION}';"
            )
            saw_version = True
            continue

        if stripped.startswith("static const String buildNumber = '"):
            updated_lines.append(
                f"{indent}static const String buildNumber = '{APP_BUILD_NUMBER}';"
            )
            saw_build_number = True
            continue

        updated_lines.append(line)

    if not saw_version or not saw_build_number:
        return False

    updated_text = "\n".join(updated_lines) + "\n"
    if updated_text != original_text:
        APP_BUILD_INFO_FILE.write_text(updated_text, encoding="utf-8")

    return True


refresh_version_context()

def get_linux_bundle_binary_name(bundle_path: Path) -> str:
    """Return the main executable name produced by the Flutter Linux bundle."""
    for entry in bundle_path.iterdir():
        if entry.is_file() and os.access(entry, os.X_OK):
            return entry.name
    raise FileNotFoundError(f"No executable found in Linux bundle: {bundle_path}")


def get_linux_bundle_path() -> Path:
    """Return Flutter's release bundle path for Linux x64 desktop builds."""
    return SCRIPT_DIR / "build/linux/x64/release/bundle"


def write_linux_desktop_file(destination: Path, linux_binary_name: str) -> None:
    """Copy the desktop entry and keep launcher paths aligned with the package."""
    desktop_file_source = SCRIPT_DIR / "linux/runner/resources" / f"{LINUX_APPLICATION_ID}.desktop"
    if not desktop_file_source.exists():
        raise FileNotFoundError(f"Linux desktop file not found: {desktop_file_source}")

    replacements = {
        "Exec=": f"Exec=/usr/local/{APP_NAME}/{linux_binary_name}",
        "Icon=": f"Icon={LINUX_APPLICATION_ID}",
        "Comment=": f"Comment={APP_DESCRIPTION}",
        "StartupWMClass=": f"StartupWMClass={LINUX_APPLICATION_ID}",
    }
    updated_lines = []
    for line in desktop_file_source.read_text(encoding="utf-8").splitlines():
        replacement = next(
            (
                replacement
                for prefix, replacement in replacements.items()
                if line.startswith(prefix)
            ),
            None,
        )
        updated_lines.append(replacement if replacement is not None else line)

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")


def sync_inno_setup_script(script_path: Path):
    """Update the Inno script for the current version and output folder."""
    if not script_path.exists():
        return False

    app_source_dir = to_inno_path(get_windows_app_dir())
    output_dir = to_inno_path(get_windows_installer_dir())
    vc_redist_path = to_inno_path(VC_REDIST_DIR / "VC_redist.x64.exe")
    setup_icon_path = to_inno_path(
        SCRIPT_DIR / "windows" / "runner" / "resources" / "app_icon.ico"
    )

    lines = script_path.read_text(encoding="utf-8").splitlines()
    updated_lines = []
    saw_app_version_define = False
    saw_artifact_define = False
    saw_close_applications = False
    saw_restart_applications = False
    saw_dll_wildcard = False
    setup_section_index = None

    for index, line in enumerate(lines):
        stripped = line.strip()

        if stripped == "[Setup]":
            setup_section_index = len(updated_lines)

        if stripped.startswith('#define MyAppVersion "'):
            updated_lines.append(f'#define MyAppVersion "{APP_FULL_VERSION}"')
            saw_app_version_define = True
            continue

        if stripped.startswith('#define MyAppArtifactVersion "'):
            updated_lines.append(f'#define MyAppArtifactVersion "{APP_ARTIFACT_VERSION}"')
            saw_artifact_define = True
            continue

        if stripped.startswith("AppVersion="):
            updated_lines.append("AppVersion={#MyAppVersion}")
            continue

        if stripped.startswith("AppVerName="):
            updated_lines.append("AppVerName={#MyAppName} {#MyAppVersion}")
            continue

        if stripped.startswith("SetupIconFile="):
            updated_lines.append(f"SetupIconFile={setup_icon_path}")
            continue

        if stripped.startswith("OutputDir="):
            updated_lines.append(f"OutputDir={output_dir}")
            continue

        if stripped.startswith("OutputBaseFilename="):
            updated_lines.append("OutputBaseFilename=beatzlock_{#MyAppArtifactVersion}_x64")
            continue

        if stripped.startswith("CloseApplications="):
            updated_lines.append("CloseApplications=yes")
            saw_close_applications = True
            continue

        if stripped.startswith("RestartApplications="):
            updated_lines.append("RestartApplications=yes")
            saw_restart_applications = True
            continue

        if stripped.startswith("Source: ") and "\\final_builds\\windows\\" in stripped.lower():
            lower_line = line.lower()
            quote_start = line.find('"')
            app_index = lower_line.find("\\app", quote_start)

            if quote_start != -1 and app_index != -1 and lower_line.rstrip().find(".dll") != -1:
                if not saw_dll_wildcard:
                    updated_lines.append(
                        'Source: "%s\\*.dll"; DestDir: "{app}"; '
                        "Flags: ignoreversion" % app_source_dir
                    )
                    saw_dll_wildcard = True
                continue

            if quote_start != -1 and app_index != -1:
                updated_lines.append(line[:quote_start + 1] + app_source_dir + line[app_index + 4:])
                continue

        if stripped.startswith("Source: ") and "vc_redist.x64.exe" in stripped.lower():
            quote_start = line.find('"')
            quote_end = line.find('"', quote_start + 1)
            if quote_start != -1 and quote_end != -1:
                updated_lines.append(line[:quote_start + 1] + vc_redist_path + line[quote_end:])
                continue

        updated_lines.append(line)

    if setup_section_index is not None:
        insert_at = setup_section_index + 1
        if not saw_restart_applications:
            updated_lines.insert(insert_at, "RestartApplications=yes")
        if not saw_close_applications:
            updated_lines.insert(insert_at, "CloseApplications=yes")

    if not saw_app_version_define:
        for index, line in enumerate(updated_lines):
            if line.strip() == '#define MyAppName "beatzLock"':
                updated_lines.insert(index + 1, f'#define MyAppVersion "{APP_FULL_VERSION}"')
                break

    if not saw_artifact_define:
        for index, line in enumerate(updated_lines):
            if line.strip().startswith('#define MyAppVersion "'):
                updated_lines.insert(index + 1, f'#define MyAppArtifactVersion "{APP_ARTIFACT_VERSION}"')
                break

    script_path.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
    return True


def find_inno_compiler() -> str | None:
    """Locate ISCC.exe for compiling Inno Setup scripts."""
    compiler = shutil.which("iscc")
    if compiler:
        return compiler

    common_paths = [
        r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        r"C:\Program Files\Inno Setup 6\ISCC.exe",
    ]
    for path in common_paths:
        if os.path.exists(path):
            return path

    return None


def build_windows_installer() -> bool:
    """Compile the Inno Setup installer into final_builds/windows/<version>/."""
    script_path = find_inno_setup_script()
    if script_path is None:
        print_color("No Inno Setup script found to compile.", Colors.RED)
        return False

    target_script_path = get_versioned_inno_script_path()
    if script_path.resolve() != target_script_path.resolve():
        target_script_path.parent.mkdir(parents=True, exist_ok=True)
        if target_script_path.exists():
            target_script_path.unlink()
        shutil.copy2(str(script_path), target_script_path)
        script_path = target_script_path
        print_color(
            f"Inno Setup script copied to current version: {script_path}",
            Colors.GREEN,
        )

    sync_inno_setup_script(script_path)

    compiler_path = find_inno_compiler()
    if not compiler_path:
        print_color("Inno Setup compiler (ISCC.exe) not found.", Colors.RED)
        print_color("Install Inno Setup 6 or add ISCC.exe to PATH.", Colors.YELLOW)
        return False

    get_windows_installer_dir().mkdir(parents=True, exist_ok=True)
    if not run(f'"{compiler_path}" "{script_path}"', cwd=str(WORKSPACE_DIR)):
        return False

    expected_output = get_windows_installer_path()
    if expected_output.exists():
        save_platform_build_metadata("windows", "installer", expected_output)
        print_color(f"✅ Windows installer created: {expected_output}", Colors.GREEN)
        windows_app_dir = get_windows_app_dir()
        if windows_app_dir.exists():
            try:
                remove_tree_force(windows_app_dir)
                print_color(f"Removed staged Windows app files: {windows_app_dir}", Colors.GREEN)
            except OSError as error:
                print_color(f"Could not remove staged Windows app files: {error}", Colors.YELLOW)
        return True

    print_color("Inno Setup finished, but the expected installer was not found.", Colors.YELLOW)
    return False


def run(cmd, cwd=None, shell=True, capture_output=False, env=None):
    """Run shell command with error handling"""
    print_color(f"\n>>> Running: {cmd}", Colors.CYAN)
    process_env = os.environ.copy()
    if env:
        process_env.update(env)
    try:
        if capture_output:
            result = subprocess.run(cmd, shell=shell, check=True, cwd=cwd, 
                                   capture_output=True, text=True, env=process_env)
            return result
        else:
            result = subprocess.run(cmd, shell=shell, check=True, cwd=cwd, 
                                   capture_output=False, text=True, env=process_env)
            return result
    except subprocess.CalledProcessError as e:
        print_color(f"❌ Command failed with exit code {e.returncode}", Colors.RED)
        if capture_output and hasattr(e, 'stderr'):
            print_color(f"Error: {e.stderr}", Colors.RED)
        elif capture_output and hasattr(e, 'stdout'):
            print_color(f"Output: {e.stdout}", Colors.RED)
        else:
            print_color(f"Error: {e}", Colors.RED)
        return None

def ensure_dirs():
    """Create necessary directories"""
    for dir_path in [LINUX_DIR, FEDORA_DIR, WINDOWS_DIR, ANDROID_DIR]:
        os.makedirs(dir_path, exist_ok=True)
        print_color(f"✓ Directory ready: {dir_path}", Colors.GREEN)


def find_tool_path(tool_name: str, exclude_build_tools=False) -> str | None:
    """Find a build tool in PATH or common LLVM install folders."""
    if exclude_build_tools:
        for path_dir in os.environ.get("PATH", "").split(os.pathsep):
            if not path_dir:
                continue
            if Path(path_dir).resolve() == BUILD_TOOLS_DIR.resolve():
                continue
            candidate = Path(path_dir) / tool_name
            if candidate.exists() and os.access(candidate, os.X_OK):
                return str(candidate)

    tool_path = shutil.which(tool_name)
    if tool_path and not (
        exclude_build_tools and Path(tool_path).parent.resolve() == BUILD_TOOLS_DIR.resolve()
    ):
        return tool_path

    for llvm_bin_dir in sorted(glob.glob("/usr/lib/llvm-*/bin"), reverse=True):
        candidate = Path(llvm_bin_dir) / tool_name
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)

    return None


def find_clang_toolchain_with_linker() -> Path | None:
    """Find a Clang bin directory that also contains a linker."""
    clang_path = find_tool_path("clang", exclude_build_tools=True)
    if clang_path:
        clang_bin_dir = Path(clang_path).resolve().parent
        if any((clang_bin_dir / tool_name).exists() for tool_name in ("ld.lld", "ld")):
            return clang_bin_dir

    for llvm_bin_dir in sorted(glob.glob("/usr/lib/llvm-*/bin"), reverse=True):
        candidate_dir = Path(llvm_bin_dir)
        if not (candidate_dir / "clang").exists():
            continue
        if any((candidate_dir / tool_name).exists() for tool_name in ("ld.lld", "ld")):
            return candidate_dir

    return Path(clang_path).resolve().parent if clang_path else None


def link_build_tool(tool_name: str, target: str) -> None:
    """Create or refresh a symlink in the workspace build tools folder."""
    BUILD_TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    link_path = BUILD_TOOLS_DIR / tool_name
    if link_path.exists() or link_path.is_symlink():
        current_target = os.readlink(link_path) if link_path.is_symlink() else None
        if current_target == target:
            return
        link_path.unlink()
    os.symlink(target, link_path)


def write_build_tool_wrapper(tool_name: str, target: str) -> None:
    """Create or refresh a tiny executable wrapper in the build tools folder."""
    BUILD_TOOLS_DIR.mkdir(parents=True, exist_ok=True)
    wrapper_path = BUILD_TOOLS_DIR / tool_name
    wrapper_content = f'#!/bin/sh\nexec "{target}" "$@"\n'
    if wrapper_path.exists() or wrapper_path.is_symlink():
        if wrapper_path.is_file() and not wrapper_path.is_symlink():
            try:
                if wrapper_path.read_text(encoding="utf-8") == wrapper_content:
                    return
            except UnicodeDecodeError:
                pass
        wrapper_path.unlink()
    wrapper_path.write_text(wrapper_content, encoding="utf-8")
    os.chmod(wrapper_path, 0o755)


def get_linux_build_env() -> dict[str, str]:
    """Return an environment that lets Dart native-assets find Clang's linker."""
    if platform.system() != "Linux":
        return {}

    clang_bin_dir = find_clang_toolchain_with_linker()
    if not clang_bin_dir:
        return {}

    clang_path = clang_bin_dir / "clang"
    if not clang_path.exists():
        return {}

    linker_path = (
        (clang_bin_dir / "ld.lld")
        if (clang_bin_dir / "ld.lld").exists()
        else (clang_bin_dir / "ld")
        if (clang_bin_dir / "ld").exists()
        else None
    )
    if not linker_path:
        print_color("⚠️  No ld.lld or ld linker found for Linux native assets.", Colors.YELLOW)
        return {}

    write_build_tool_wrapper("clang", str(clang_path))
    clangxx_path = clang_bin_dir / "clang++"
    if clangxx_path.exists():
        write_build_tool_wrapper("clang++", str(clangxx_path))
    link_build_tool(linker_path.name, str(linker_path))
    if Path(linker_path).name != "ld":
        ld_path = find_tool_path("ld", exclude_build_tools=True)
        if ld_path:
            link_build_tool("ld", ld_path)

    archiver_path = (
        (clang_bin_dir / "llvm-ar")
        if (clang_bin_dir / "llvm-ar").exists()
        else Path(find_tool_path("ar", exclude_build_tools=True) or "")
    )
    if archiver_path and archiver_path.exists():
        link_build_tool(archiver_path.name, str(archiver_path))
        if Path(archiver_path).name != "ar":
            ar_path = find_tool_path("ar", exclude_build_tools=True)
            if ar_path:
                link_build_tool("ar", ar_path)

    print_color(
        f"✓ Using workspace Clang linker shim: {BUILD_TOOLS_DIR}",
        Colors.GREEN,
    )
    return {"PATH": f"{BUILD_TOOLS_DIR}{os.pathsep}{os.environ.get('PATH', '')}"}


def get_common_flutter_bins() -> list[Path]:
    """Return common Flutter executable locations for manual SDK installs."""
    return [
        Path.home() / "develop/flutter/bin/flutter",
        Path.home() / "development/flutter/bin/flutter",
        Path.home() / "flutter/bin/flutter",
        Path("/opt/flutter/bin/flutter"),
        Path("/snap/bin/flutter"),
    ]


def find_local_flutter() -> Path | None:
    """Find Flutter in common install paths when PATH does not include it."""
    for flutter_bin in get_common_flutter_bins():
        if flutter_bin.exists() and os.access(flutter_bin, os.X_OK):
            return flutter_bin
    return None


def add_flutter_to_current_path(flutter_bin: Path) -> None:
    """Make a discovered Flutter SDK available to this build script process."""
    flutter_dir = str(flutter_bin.parent)
    os.environ["PATH"] = f"{flutter_dir}{os.pathsep}{os.environ.get('PATH', '')}"


def print_flutter_install_help():
    """Print Flutter install/PATH guidance for the current host."""
    common_flutter_bins = get_common_flutter_bins()
    existing_bins = [path for path in common_flutter_bins if path.exists()]

    if existing_bins:
        print_color("\nFlutter exists, but it is not on PATH in this terminal.", Colors.YELLOW)
        print_color("Add it to PATH, for example:", Colors.BLUE)
        print(f"  echo 'export PATH=\"{existing_bins[0].parent}:$PATH\"' >> ~/.bashrc")
        print("  source ~/.bashrc")
        print("  flutter doctor -v")
        return

    print_color("\nInstall Flutter and add it to PATH.", Colors.YELLOW)

    if platform.system() == "Linux" and is_rpm_based_linux():
        print_color("\nFedora prerequisites:", Colors.BLUE)
        for command in get_linux_desktop_install_commands(include_rpm=True):
            print(f"  {command}")
        print_color("\nThen install the Flutter SDK:", Colors.BLUE)
        print("  mkdir -p \"$HOME/develop\"")
        print("  # Download the Linux Flutter SDK from https://docs.flutter.dev/get-started/install/linux")
        print("  tar -xf ~/Downloads/flutter_linux_*.tar.xz -C \"$HOME/develop\"")
        print("  echo 'export PATH=\"$HOME/develop/flutter/bin:$PATH\"' >> ~/.bashrc")
        print("  source ~/.bashrc")
        print("  flutter doctor -v")
        return

    print_color("\nOfficial Flutter install guide:", Colors.BLUE)
    print("  https://docs.flutter.dev/get-started/install")


def check_flutter():
    """Verify Flutter is installed and configured"""
    if shutil.which("flutter") is None:
        local_flutter = find_local_flutter()
        if local_flutter:
            add_flutter_to_current_path(local_flutter)
            print_color(f"Using Flutter from: {local_flutter}", Colors.GREEN)
        else:
            print_color("Flutter command not found.", Colors.RED)
            print_flutter_install_help()
            return False

    result = run("flutter --version", cwd=PROJECT_DIR, capture_output=True)
    if not result:
        print_color("Flutter is on PATH, but it did not run correctly.", Colors.RED)
        print("  Try: flutter doctor -v")
        return False
    
    return True

def check_linux_desktop_requirements():
    """Verify Linux desktop build tools are installed before running Flutter."""
    if platform.system() != "Linux":
        return True

    missing_tools = []
    for tool in ["clang", "cmake", "ninja", "pkg-config"]:
        if shutil.which(tool) is None:
            missing_tools.append(tool)

    gtk_ready = subprocess.run(
        ["pkg-config", "--exists", "gtk+-3.0"],
        cwd=PROJECT_DIR,
        capture_output=True,
        text=True,
    ).returncode == 0 if shutil.which("pkg-config") else False
    webp_ready = Path("/usr/include/webp").is_dir()

    if not missing_tools and gtk_ready and webp_ready:
        return True

    print_color("\n❌ Linux desktop prerequisites are missing.", Colors.RED)

    if missing_tools:
        print_color(
            f"Missing tools: {', '.join(missing_tools)}",
            Colors.YELLOW,
        )

    if not gtk_ready:
        print_color("Missing GTK 3 development files (gtk+-3.0).", Colors.YELLOW)

    if not webp_ready:
        print_color("Missing WebP development headers (/usr/include/webp).", Colors.YELLOW)

    print_color("\nInstall them with:", Colors.BLUE)
    for command in get_linux_desktop_install_commands():
        print(f"  {command}")
    print_color("\nThen try the Linux run/build again.", Colors.BLUE)
    return False


def check_deb_packaging_requirements():
    """Verify Debian package tooling is installed."""
    if shutil.which("dpkg-deb"):
        return True

    print_color("\nDebian package tooling is missing: dpkg-deb", Colors.RED)
    if shutil.which("apt"):
        print_color("Install it with:", Colors.BLUE)
        print("  sudo apt update")
        print("  sudo apt install -y dpkg")
    else:
        print_color(
            "This host does not look Debian-based. Use the Fedora .rpm option here.",
            Colors.YELLOW,
        )
    return False


def check_rpm_packaging_requirements():
    """Verify RPM package tooling is installed."""
    missing_tools = [
        tool_name
        for tool_name in ("rpmbuild", "patchelf")
        if shutil.which(tool_name) is None
    ]
    if not missing_tools:
        return True

    print_color(
        f"\nRPM package tooling is missing: {', '.join(missing_tools)}",
        Colors.RED,
    )
    print_color("Install it with:", Colors.BLUE)
    for command in get_linux_desktop_install_commands(include_rpm=True):
        print(f"  {command}")
    return False

def check_device_connected():
    """Check if an Android device/emulator is connected"""
    result = run("adb devices", cwd=PROJECT_DIR, capture_output=True)
    if result and result.stdout:
        lines = result.stdout.strip().split('\n')
        devices = [l for l in lines[1:] if l.strip() and 'device' in l and 'offline' not in l]
        return len(devices) > 0
    return False

def save_build_metadata_legacy(platform_name, file_path):
    """Legacy combined build log writer retained for backward compatibility."""
    FINAL_BUILDS_DIR.mkdir(parents=True, exist_ok=True)
    log_file = FINAL_BUILDS_DIR / "build_log.json"
    
    try:
        with open(log_file, 'r') as f:
            logs = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        logs = []
    
    logs.append({
        "platform": platform_name,
        "file": os.path.basename(file_path),
        "path": str(file_path),
        "timestamp": datetime.now().isoformat(),
        "version": APP_FULL_VERSION,
        "build_number": APP_BUILD_NUMBER,
    })
    
    with open(log_file, 'w') as f:
        json.dump(logs, f, indent=2)
    
    print_color(f"✓ Build info saved to {log_file}", Colors.GREEN)

def ensure_build_log_directories():
    """Create per-platform build log directories when missing."""
    for platform_name in SUPPORTED_BUILD_LOG_PLATFORMS:
        get_build_log_dir(platform_name).mkdir(parents=True, exist_ok=True)


def load_build_log_entries(log_file: Path) -> list[dict]:
    """Load a build log JSON array, falling back to an empty list."""
    try:
        data = json.loads(log_file.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return []

    if isinstance(data, list):
        return [entry for entry in data if isinstance(entry, dict)]

    return []


def write_build_log_entries(log_file: Path, logs: list[dict]) -> None:
    """Write a build log JSON array in a stable, readable format."""
    log_file.write_text(json.dumps(logs, indent=2) + "\n", encoding="utf-8")


def migrate_legacy_android_build_log() -> None:
    """Move any legacy build_logs/apk/build_log.json entries into android."""
    legacy_dir = BUILD_LOGS_DIR / "apk"
    legacy_log_file = legacy_dir / "build_log.json"
    android_log_file = get_build_log_dir("android") / "build_log.json"

    if not legacy_log_file.exists():
        return

    legacy_logs = load_build_log_entries(legacy_log_file)
    android_logs = load_build_log_entries(android_log_file)
    merged_logs = legacy_logs + android_logs

    for index, entry in enumerate(merged_logs, start=1):
        entry["sequence"] = index
        entry["platform"] = "android"

    write_build_log_entries(android_log_file, merged_logs)
    legacy_log_file.unlink()

    remaining_items = list(legacy_dir.iterdir()) if legacy_dir.exists() else []
    if not remaining_items:
        legacy_dir.rmdir()

    print_color(f"Build info migrated to {android_log_file}", Colors.GREEN)


def save_platform_build_metadata(platform_name: str, artifact_type: str, file_path: str | Path):
    """Append build information into the platform-specific JSON log."""
    if platform_name not in SUPPORTED_BUILD_LOG_PLATFORMS:
        raise ValueError(f"Unsupported build log platform: {platform_name}")

    ensure_build_log_directories()
    if platform_name == "android":
        migrate_legacy_android_build_log()

    log_file = get_build_log_dir(platform_name) / "build_log.json"
    logs = load_build_log_entries(log_file)

    output_path = Path(file_path).resolve()
    try:
        relative_path = output_path.relative_to(WORKSPACE_DIR.resolve())
    except ValueError:
        relative_path = output_path

    next_sequence = max(
        (
            int(entry.get("sequence", 0))
            for entry in logs
            if str(entry.get("sequence", "")).isdigit()
        ),
        default=0,
    ) + 1

    new_entry = {
        "sequence": next_sequence,
        "platform": platform_name,
        "artifact_type": artifact_type,
        "file": output_path.name,
        "path": str(output_path),
        "relative_path": str(relative_path).replace("\\", "/"),
        "is_directory": output_path.is_dir(),
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "version": APP_FULL_VERSION,
        "build_number": APP_BUILD_NUMBER,
        "artifact_version": APP_ARTIFACT_VERSION,
        "host_platform": platform.system(),
    }

    release_key = (
        str(new_entry.get("version") or "").strip(),
        str(new_entry.get("build_number") or "").strip(),
    )

    replaced = False
    for index, entry in enumerate(logs):
        existing_key = (
            str(entry.get("version") or "").strip(),
            str(entry.get("build_number") or "").strip(),
        )
        if existing_key == release_key:
            preserved_sequence = int(entry.get("sequence", next_sequence) or next_sequence)
            new_entry["sequence"] = preserved_sequence
            logs[index] = new_entry
            replaced = True
            break

    if not replaced:
        logs.append(new_entry)

    logs.sort(
        key=lambda entry: (
            str(entry.get("timestamp") or ""),
            int(entry.get("sequence", 0) or 0),
        )
    )

    for index, entry in enumerate(logs, start=1):
        entry["sequence"] = index

    write_build_log_entries(log_file, logs)
    print_color(f"Build info saved to {log_file}", Colors.GREEN)


def clean_windows_cache():
    """Clean Windows build cache to fix CMake generator mismatch"""
    print_color("\n🧹 Cleaning Windows CMake cache...", Colors.YELLOW)
    
    paths_to_clean = [
        Path(PROJECT_DIR) / "build/windows",
        Path(PROJECT_DIR) / "windows/CMakeCache.txt",
        Path(PROJECT_DIR) / "windows/CMakeFiles",
        Path(PROJECT_DIR) / "windows/flutter/ephemeral",
        Path(PROJECT_DIR) / ".dart_tool",
    ]
    
    for path in paths_to_clean:
        if path.exists():
            if path.is_file():
                path.unlink()
                print_color(f"✓ Removed file: {path}", Colors.GREEN)
            elif path.is_dir():
                shutil.rmtree(path)
                print_color(f"✓ Removed directory: {path}", Colors.GREEN)
    
    run("flutter clean", cwd=PROJECT_DIR)
    
    print_color("✅ Windows CMake cache cleaned!", Colors.GREEN)

def run_linux():
    """Run the Linux app in debug mode"""
    print_color("\n🐧 Running Linux app...", Colors.CYAN)
    
    if platform.system() != "Linux":
        print_color("⚠️  Linux app can only be run on Linux!", Colors.YELLOW)
        return False

    if not check_linux_desktop_requirements():
        return False
    
    print_color("Starting Linux app (press Ctrl+C to stop)...", Colors.GREEN)
    run("flutter run -d linux", cwd=PROJECT_DIR, env=get_linux_build_env())
    return True

def run_windows():
    """Run the Windows app in debug mode"""
    print_color("\n🪟 Running Windows app...", Colors.CYAN)
    
    if platform.system() != "Windows":
        print_color("⚠️  Windows app can only be run on Windows!", Colors.YELLOW)
        return False
    
    print_color("Starting Windows app (press Ctrl+C to stop)...", Colors.GREEN)
    run("flutter run -d windows", cwd=PROJECT_DIR)
    return True

def run_android():
    """Run Android app on connected device/emulator"""
    print_color("\n📱 Running Android app...", Colors.CYAN)
    
    if not check_device_connected():
        print_color("⚠️  No Android device/emulator detected!", Colors.YELLOW)
        print_color("   Please start an emulator or connect a device via USB", Colors.YELLOW)
        choice = input("   Continue anyway? (y/n): ").lower()
        if choice != 'y':
            return False
    
    print_color("Starting Android app (press Ctrl+C to stop)...", Colors.GREEN)
    run("flutter run", cwd=PROJECT_DIR)
    return True

def list_devices():
    """List available devices for running"""
    print_color("\n📱 Available devices:", Colors.CYAN)
    run("flutter devices", cwd=PROJECT_DIR)

def hot_reload():
    """Run with hot reload for development"""
    print_color("\n🔥 Running with hot reload (development mode)...", Colors.CYAN)
    print_color("   Press 'r' for hot reload", Colors.BLUE)
    print_color("   Press 'R' for hot restart", Colors.BLUE)
    print_color("   Press 'q' to quit", Colors.BLUE)
    print_color("   Press 'h' for help", Colors.BLUE)
    
    if platform.system() == "Windows":
        run("flutter run", cwd=PROJECT_DIR)
    else:
        run("flutter run", cwd=PROJECT_DIR, env=get_linux_build_env())

def build_linux_deb(skip_deb_package=False):
    """Build Debian .deb package"""
    print_color("\n🐧 Building Linux .deb package...", Colors.CYAN)

    if not check_linux_desktop_requirements():
        return False

    if not skip_deb_package and not check_deb_packaging_requirements():
        return False
    
    linux_build_env = get_linux_build_env()
    if not run("flutter build linux --release", cwd=PROJECT_DIR, env=linux_build_env):
        return False
    
    bundle_path = get_linux_bundle_path()
    if not bundle_path.exists():
        print_color("❌ Linux build failed - bundle not found", Colors.RED)
        return False

    linux_binary_name = get_linux_bundle_binary_name(bundle_path)
    if skip_deb_package:
        return True
    
    deb_dir = WORKSPACE_DIR / "deb_pkg"
    try:
        if deb_dir.exists():
            shutil.rmtree(deb_dir)

        os.makedirs(deb_dir / "DEBIAN", exist_ok=True)
        os.makedirs(deb_dir / "usr/local" / APP_NAME, exist_ok=True)
        os.makedirs(deb_dir / "usr/share/applications", exist_ok=True)
        os.makedirs(deb_dir / "usr/share/icons/hicolor/256x256/apps", exist_ok=True)

        shutil.copytree(bundle_path, deb_dir / "usr/local" / APP_NAME, dirs_exist_ok=True)
        linux_icon_source = SCRIPT_DIR / "linux/runner/resources/app_icon.png"
        if linux_icon_source.exists():
            shutil.copy2(
                linux_icon_source,
                deb_dir / "usr/share/icons/hicolor/256x256/apps" / f"{LINUX_APPLICATION_ID}.png",
            )

        try:
            write_linux_desktop_file(
                deb_dir / "usr/share/applications" / f"{LINUX_APPLICATION_ID}.desktop",
                linux_binary_name,
            )
        except FileNotFoundError as error:
            print_color(f"❌ {error}", Colors.RED)
            return False

        control_content = f"""Package: {DEB_PACKAGE_NAME}
Version: {APP_FULL_VERSION}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: {APP_MAINTAINER}
Description: {APP_DESCRIPTION}
 This package provides an OTP authentication application.
"""
        with open(deb_dir / "DEBIAN" / "control", "w") as f:
            f.write(control_content)

        postinst_content = """#!/bin/bash
set -e
chmod +x /usr/local/{APP_NAME}/{APP_BINARY_NAME}
echo "✓ {APP_NAME} installed successfully"
exit 0
""".replace("{APP_NAME}", APP_NAME).replace("{APP_BINARY_NAME}", linux_binary_name)

        with open(deb_dir / "DEBIAN" / "postinst", "w") as f:
            f.write(postinst_content)
        os.chmod(deb_dir / "DEBIAN" / "postinst", 0o755)

        deb_file = f"{DEB_PACKAGE_NAME}_{APP_ARTIFACT_VERSION}_amd64.deb"
        deb_output = WORKSPACE_DIR / deb_file
        if not run(f'dpkg-deb --build "{deb_dir}" "{deb_output}"', cwd=str(WORKSPACE_DIR)):
            return False

        linux_version_dir = get_platform_version_dir("linux")
        linux_version_dir.mkdir(parents=True, exist_ok=True)
        final_deb_path = linux_version_dir / deb_file
        if final_deb_path.exists():
            final_deb_path.unlink()
        shutil.move(str(deb_output), final_deb_path)
        save_platform_build_metadata("linux", "deb", final_deb_path)

        print_color(f"✅ Linux .deb created: {final_deb_path}", Colors.GREEN)
        return True
    finally:
        if deb_dir.exists():
            shutil.rmtree(deb_dir)
            print_color(f"✓ Removed temporary Debian package folder: {deb_dir}", Colors.GREEN)


def create_rpm_source_archive(bundle_path: Path, linux_binary_name: str) -> tuple[str, Path]:
    """Stage Flutter bundle assets and archive them for rpmbuild."""
    source_root_name = f"{RPM_PACKAGE_NAME}-{APP_ARTIFACT_VERSION}"
    sources_dir = RPM_BUILD_DIR / "SOURCES"
    source_root = sources_dir / source_root_name
    source_archive = sources_dir / f"{source_root_name}.tar.gz"

    if source_root.exists():
        shutil.rmtree(source_root)
    if source_archive.exists():
        source_archive.unlink()

    source_root.mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle_path, source_root / "bundle", dirs_exist_ok=True)

    try:
        write_linux_desktop_file(
            source_root / f"{LINUX_APPLICATION_ID}.desktop",
            linux_binary_name,
        )
    except FileNotFoundError:
        shutil.rmtree(source_root)
        raise

    linux_icon_source = SCRIPT_DIR / "linux/runner/resources/app_icon.png"
    if linux_icon_source.exists():
        shutil.copy2(linux_icon_source, source_root / "app_icon.png")

    patch_staged_rpm_bundle_rpaths(source_root / "bundle")

    with tarfile.open(source_archive, "w:gz") as archive:
        archive.add(source_root, arcname=source_root.name)

    return source_root_name, source_archive


def is_elf_file(path: Path) -> bool:
    """Return True when a file looks like an ELF binary/shared library."""
    if not path.is_file():
        return False
    try:
        with path.open("rb") as file:
            return file.read(4) == b"\x7fELF"
    except OSError:
        return False


def get_bundle_relative_rpath(binary_path: Path, bundle_path: Path) -> str:
    """Return a relocatable RPATH from an ELF file to the bundle lib folder."""
    lib_dir = bundle_path / "lib"
    relative_lib_dir = os.path.relpath(lib_dir, binary_path.parent)
    if relative_lib_dir == ".":
        return "$ORIGIN"
    return f"$ORIGIN/{relative_lib_dir.replace(os.sep, '/')}"


def patch_staged_rpm_bundle_rpaths(bundle_path: Path) -> None:
    """Replace build-machine RUNPATHs with relocatable paths for RPM checks."""
    patchelf_path = shutil.which("patchelf")
    if not patchelf_path:
        raise RuntimeError("patchelf is required to prepare the Fedora RPM bundle")

    patched_files = []
    for path in sorted(bundle_path.rglob("*")):
        if not is_elf_file(path):
            continue

        rpath = get_bundle_relative_rpath(path, bundle_path)
        try:
            subprocess.run(
                [patchelf_path, "--set-rpath", rpath, str(path)],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as error:
            message = error.stderr.strip() or error.stdout.strip() or str(error)
            raise RuntimeError(f"Could not patch RPATH for {path}: {message}") from error

        patched_files.append(path.relative_to(bundle_path))

    if patched_files:
        print_color(
            f"✓ Normalized RPM bundle RPATHs for {len(patched_files)} ELF files",
            Colors.GREEN,
        )


def write_rpm_spec_file(
    source_root_name: str,
    source_archive: Path,
    linux_binary_name: str,
) -> Path:
    """Write the RPM spec file for the current Flutter release bundle."""
    specs_dir = RPM_BUILD_DIR / "SPECS"
    specs_dir.mkdir(parents=True, exist_ok=True)

    rpm_version = sanitize_rpm_value(APP_VERSION, "0")
    rpm_release = sanitize_rpm_value(APP_BUILD_NUMBER, "1")
    changelog_date = datetime.now().strftime("%a %b %d %Y")
    spec_file = specs_dir / f"{RPM_PACKAGE_NAME}.spec"
    spec_content = f"""%global debug_package %{{nil}}
%global _build_id_links none

Name:           {RPM_PACKAGE_NAME}
Version:        {rpm_version}
Release:        {rpm_release}%{{?dist}}
Summary:        {APP_DESCRIPTION}
License:        {RPM_LICENSE}
BuildArch:      {RPM_ARCH}
Source0:        {source_archive.name}

Requires:       gtk3
Requires:       xdg-utils
Requires(post): /usr/bin/update-desktop-database
Requires(postun): /usr/bin/update-desktop-database

%description
This package provides an OTP authentication application.

%prep
%setup -q -n {source_root_name}

%build
# Flutter already produced the release bundle before rpmbuild runs.

%install
rm -rf %{{buildroot}}
mkdir -p %{{buildroot}}/usr/local/{APP_NAME}
cp -a bundle/. %{{buildroot}}/usr/local/{APP_NAME}/
install -Dm0644 {LINUX_APPLICATION_ID}.desktop %{{buildroot}}%{{_datadir}}/applications/{LINUX_APPLICATION_ID}.desktop
install -Dm0644 app_icon.png %{{buildroot}}%{{_datadir}}/icons/hicolor/256x256/apps/{LINUX_APPLICATION_ID}.png
chmod 0755 %{{buildroot}}/usr/local/{APP_NAME}/{linux_binary_name}

%post
/usr/bin/update-desktop-database %{{_datadir}}/applications >/dev/null 2>&1 || :
/bin/touch --no-create %{{_datadir}}/icons/hicolor >/dev/null 2>&1 || :

%postun
/usr/bin/update-desktop-database %{{_datadir}}/applications >/dev/null 2>&1 || :
/bin/touch --no-create %{{_datadir}}/icons/hicolor >/dev/null 2>&1 || :

%files
/usr/local/{APP_NAME}
%{{_datadir}}/applications/{LINUX_APPLICATION_ID}.desktop
%{{_datadir}}/icons/hicolor/256x256/apps/{LINUX_APPLICATION_ID}.png

%changelog
* {changelog_date} {APP_MAINTAINER} - {rpm_version}-{rpm_release}
- Build {APP_FULL_VERSION}
"""
    spec_file.write_text(spec_content, encoding="utf-8")
    return spec_file


def build_linux_rpm():
    """Build Fedora/RHEL .rpm package."""
    print_color("\nBuilding Fedora .rpm package...", Colors.CYAN)

    if platform.system() != "Linux":
        print_color("Fedora RPM builds require Linux.", Colors.YELLOW)
        return False

    if not check_linux_desktop_requirements():
        return False

    if not check_rpm_packaging_requirements():
        return False

    linux_build_env = get_linux_build_env()
    if not run("flutter build linux --release", cwd=PROJECT_DIR, env=linux_build_env):
        return False

    bundle_path = get_linux_bundle_path()
    if not bundle_path.exists():
        print_color("Linux build failed - bundle not found", Colors.RED)
        return False

    linux_binary_name = get_linux_bundle_binary_name(bundle_path)

    try:
        if RPM_BUILD_DIR.exists():
            shutil.rmtree(RPM_BUILD_DIR)

        for rpm_subdir in ["BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS"]:
            (RPM_BUILD_DIR / rpm_subdir).mkdir(parents=True, exist_ok=True)

        try:
            source_root_name, source_archive = create_rpm_source_archive(
                bundle_path,
                linux_binary_name,
            )
        except (FileNotFoundError, RuntimeError) as error:
            print_color(f"RPM staging failed: {error}", Colors.RED)
            return False

        spec_file = write_rpm_spec_file(
            source_root_name,
            source_archive,
            linux_binary_name,
        )

        if not run(
            f'rpmbuild -bb "{spec_file}" --define "_topdir {RPM_BUILD_DIR}"',
            cwd=str(WORKSPACE_DIR),
        ):
            return False

        rpm_outputs = sorted(
            (RPM_BUILD_DIR / "RPMS" / RPM_ARCH).glob(f"{RPM_PACKAGE_NAME}-*.{RPM_ARCH}.rpm"),
            key=lambda path: path.stat().st_mtime,
            reverse=True,
        )
        if not rpm_outputs:
            print_color("rpmbuild finished, but no RPM artifact was found.", Colors.RED)
            return False

        fedora_version_dir = get_platform_version_dir("fedora")
        fedora_version_dir.mkdir(parents=True, exist_ok=True)
        final_rpm_path = fedora_version_dir / f"{RPM_PACKAGE_NAME}_{APP_ARTIFACT_VERSION}_{RPM_ARCH}.rpm"
        if final_rpm_path.exists():
            final_rpm_path.unlink()
        shutil.move(str(rpm_outputs[0]), final_rpm_path)
        save_platform_build_metadata("fedora", "rpm", final_rpm_path)

        print_color(f"✅ Fedora .rpm created: {final_rpm_path}", Colors.GREEN)
        return True
    finally:
        if RPM_BUILD_DIR.exists():
            shutil.rmtree(RPM_BUILD_DIR)
            print_color(f"✓ Removed temporary RPM package folder: {RPM_BUILD_DIR}", Colors.GREEN)


def build_linux():
    """Build the native Linux package for the current distribution."""
    if is_rpm_based_linux():
        return build_linux_rpm()
    return build_linux_deb()

FIREBASE_SDK_SEARCH_PATHS = [
    os.path.join("C:" + os.sep, "Programming", "_sdks", "firebase_cpp_sdk_windows"),
]


def ensure_firebase_sdk_env():
    """Point firebase_core at a Firebase C++ SDK outside the build tree.

    firebase_core's CMakeLists caches its ~1 GB SDK zip inside CMAKE_BINARY_DIR,
    which is build/windows -- exactly what clean_windows_cache() deletes. Left
    alone, every Windows build re-downloads a gigabyte before compiling a single
    file, and a stalled download leaves an orphaned cmake holding the build tree.

    The CMakeLists skips all of that when FIREBASE_CPP_SDK_DIR points at a
    matching SDK. Setting it here rather than relying on the shell means it
    works in whatever terminal the build is started from -- a User-scope
    variable is invisible to any shell that was already open when it was set,
    which is a genuinely easy way to lose an hour.
    """
    if platform.system() != "Windows":
        return

    existing = os.environ.get("FIREBASE_CPP_SDK_DIR", "").strip()
    if existing and os.path.exists(os.path.join(existing, "include", "firebase", "version.h")):
        print_color(f"Firebase C++ SDK: {existing}", Colors.GREEN)
        return

    for candidate in FIREBASE_SDK_SEARCH_PATHS:
        if os.path.exists(os.path.join(candidate, "include", "firebase", "version.h")):
            os.environ["FIREBASE_CPP_SDK_DIR"] = candidate
            print_color(f"Firebase C++ SDK: {candidate}", Colors.GREEN)
            return

    print_color(
        "Firebase C++ SDK not staged locally - CMake will download ~1 GB, "
        "and will do so again after every clean.",
        Colors.YELLOW,
    )


def check_windows_desktop_requirements():
    """Verify the Windows C++ toolchain can build the plugins we depend on.

    flutter_secure_storage_windows includes <atlstr.h>, which ships with the
    "C++ ATL for latest build tools" component rather than the base C++ build
    tools. Without it the build gets all the way through pub, NuGet and most of
    CMake before failing on a missing header -- an hour of wall clock to learn
    something checkable in a second.
    """
    if platform.system() != "Windows":
        return True

    vswhere = os.path.join(
        os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
        "Microsoft Visual Studio",
        "Installer",
        "vswhere.exe",
    )
    if not os.path.exists(vswhere):
        return True

    try:
        result = subprocess.run(
            [
                vswhere,
                "-latest",
                "-products",
                "*",
                "-requires",
                "Microsoft.VisualStudio.Component.VC.ATL",
                "-property",
                "installationPath",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except Exception:
        return True

    if result.stdout.strip():
        return True

    print_color("\nMissing Visual Studio component: C++ ATL", Colors.RED)
    print_color(
        "flutter_secure_storage_windows needs <atlstr.h>, which comes with the "
        "ATL component.",
        Colors.YELLOW,
    )
    print_color("\nInstall it with:", Colors.CYAN)
    print_color(
        '  "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\'
        'vs_installer.exe" modify ^\n'
        '    --installPath "C:\\Program Files (x86)\\Microsoft Visual Studio\\'
        '18\\BuildTools" ^\n'
        "    --add Microsoft.VisualStudio.Component.VC.ATL --quiet --norestart",
        Colors.BOLD,
    )
    print_color(
        "\nOr open the Visual Studio Installer, Modify, Individual components, "
        'and tick "C++ ATL for latest v143 build tools".',
        Colors.YELLOW,
    )
    return False


def build_windows():
    """Build Windows app files and copy them to the final builds folder"""
    print_color("\nWindows build starting...", Colors.CYAN)
    
    if platform.system() != "Windows":
        print_color("Windows build must be run on Windows!", Colors.YELLOW)
        print_color("   Use: GitHub Actions, Windows VM, or actual Windows machine", Colors.YELLOW)
        return False
    
    if not check_windows_desktop_requirements():
        return False

    ensure_firebase_sdk_env()

    clean_windows_cache()
    
    print_color("\nBuilding Flutter Windows app...", Colors.BLUE)
    if not run("flutter build windows --release", cwd=PROJECT_DIR):
        print_color("Flutter build failed. Try manually running: flutter clean && flutter build windows --release", Colors.RED)
        return False
    
    exe_path = os.path.join(PROJECT_DIR, "build/windows/x64/runner/Release")
    if not os.path.exists(exe_path):
        print_color(f"Windows build failed - output not found at {exe_path}", Colors.RED)
        return False
    
    final_build_dir = get_windows_app_dir()
    if final_build_dir.exists():
        shutil.rmtree(final_build_dir)
    shutil.copytree(exe_path, final_build_dir)
    save_platform_build_metadata("windows", "exe_bundle", final_build_dir)
    
    print_color(f"Windows app staged for installer: {final_build_dir}", Colors.GREEN)
    return build_windows_installer()

def build_android(choice: str | None = None):
    """Build Android APK and App Bundle"""
    print_color("\n📱 Building Android app...", Colors.CYAN)
    
    if choice is None:
        print_color("\nAndroid Build Options:", Colors.BOLD)
        print("1. APK (Universal)")
        print("2. App Bundle (.aab - for Play Store)")
        print("3. Split APKs (per ABI)")
        print("4. Both APK and App Bundle")
        
        choice = input("Choose (1/2/3/4): ").strip()
    
    success = True
    
    if choice == "1" or choice == "4":
        print_color("\n🔨 Building APK...", Colors.BLUE)
        if not run("flutter build apk --release", cwd=PROJECT_DIR):
            success = False
        else:
            apk_path = os.path.join(PROJECT_DIR, "build/app/outputs/flutter-apk/app-release.apk")
            if os.path.exists(apk_path):
                android_version_dir = get_platform_version_dir("android")
                android_version_dir.mkdir(parents=True, exist_ok=True)
                apk_dest = android_version_dir / f"beatzlock_{APP_ARTIFACT_VERSION}.apk"
                shutil.copy(apk_path, apk_dest)
                save_platform_build_metadata("android", "apk", apk_dest)
                print_color(f"✅ APK created: {apk_dest}", Colors.GREEN)
    
    if choice == "2" or choice == "4":
        print_color("\n🔨 Building App Bundle...", Colors.BLUE)
        if not run("flutter build appbundle --release", cwd=PROJECT_DIR):
            success = False
        else:
            aab_path = os.path.join(PROJECT_DIR, "build/app/outputs/bundle/release/app-release.aab")
            if os.path.exists(aab_path):
                android_version_dir = get_platform_version_dir("android")
                android_version_dir.mkdir(parents=True, exist_ok=True)
                aab_dest = android_version_dir / f"beatzlock_{APP_ARTIFACT_VERSION}.aab"
                shutil.copy(aab_path, aab_dest)
                save_platform_build_metadata("android", "aab", aab_dest)
                print_color(f"✅ App Bundle created: {aab_dest}", Colors.GREEN)
    
    if choice == "3":
        print_color("\n🔨 Building Split APKs...", Colors.BLUE)
        if not run("flutter build apk --release --split-per-abi", cwd=PROJECT_DIR):
            success = False
        else:
            apk_dir = os.path.join(PROJECT_DIR, "build/app/outputs/apk/release")
            for apk in ["app-armeabi-v7a-release.apk", "app-arm64-v8a-release.apk", "app-x86_64-release.apk"]:
                src = os.path.join(apk_dir, apk)
                if os.path.exists(src):
                    android_version_dir = get_platform_version_dir("android")
                    android_version_dir.mkdir(parents=True, exist_ok=True)
                    abi_name = apk.removeprefix("app-").removesuffix("-release.apk")
                    dst = android_version_dir / f"beatzlock_{APP_ARTIFACT_VERSION}_{abi_name}.apk"
                    shutil.copy(src, dst)
                    save_platform_build_metadata("android", f"split_apk_{abi_name}", dst)
                    print_color(f"✅ {dst}", Colors.GREEN)
    
    return success


def build_windows_and_apk():
    """Build Windows artifacts and Android APK in one run."""
    print_color("\nBuilding Windows and Android APK artifacts...", Colors.CYAN)
    windows_ok = build_windows()
    android_ok = build_android("1")
    return windows_ok and android_ok


def build_linux_and_apk():
    """Build the current Linux distro package and Android APK in one run."""
    print_color("\nBuilding Linux package and Android APK artifacts...", Colors.CYAN)
    linux_ok = build_linux()
    android_ok = build_android("1")
    return linux_ok and android_ok

def clean_all():
    """Clean all build artifacts"""
    print_color("\n🧹 Cleaning all build artifacts...", Colors.YELLOW)
    
    dirs_to_clean = [
        SCRIPT_DIR / "build",
        WORKSPACE_DIR / "deb_pkg",
        WORKSPACE_DIR / "rpm_pkg",
        SCRIPT_DIR / ".dart_tool",
        SCRIPT_DIR / "windows/CMakeCache.txt",
        SCRIPT_DIR / "windows/CMakeFiles",
        SCRIPT_DIR / "windows/flutter/ephemeral",
    ]
    
    for dir_path in dirs_to_clean:
        if dir_path.exists():
            if dir_path.is_file():
                dir_path.unlink()
                print_color(f"✓ Removed file: {dir_path}", Colors.GREEN)
            else:
                shutil.rmtree(dir_path)
                print_color(f"✓ Removed directory: {dir_path}", Colors.GREEN)
    
    run("flutter clean", cwd=PROJECT_DIR)
    
    print_color("✅ Clean complete!", Colors.GREEN)

def list_builds():
    """List all previously built outputs"""
    print_color("\nPreviously built outputs:", Colors.CYAN)
    
    found = False
    for platform_dir in [Path(LINUX_DIR), Path(FEDORA_DIR), Path(WINDOWS_DIR), Path(ANDROID_DIR)]:
        if platform_dir.exists() and any(platform_dir.iterdir()):
            found = True
            print_color(f"\n{platform_dir.name.upper()}:", Colors.BOLD)
            for path in sorted(platform_dir.rglob("*")):
                if not path.is_file():
                    continue
                relative_path = path.relative_to(platform_dir)
                size = path.stat().st_size // (1024 * 1024)
                print(f"  {relative_path} ({size} MB)")
    
    if not found:
        print_color("\nNo builds found yet. Run a build first!", Colors.YELLOW)

def open_final_builds_dir():
    """Open final builds directory in file manager"""
    final_builds_path = FINAL_BUILDS_DIR

    if final_builds_path.exists():
        if platform.system() == "Linux":
            run(f'xdg-open "{final_builds_path}"')
        elif platform.system() == "Windows":
            os.startfile(final_builds_path)
        else:
            print_color(f"Final builds directory: {final_builds_path}", Colors.BLUE)

def fix_windows_build():
    """Specifically fix Windows build issues"""
    print_color("\n🔧 Fixing Windows build environment...", Colors.YELLOW)
    
    clean_windows_cache()
    
    print_color("\n🔍 Checking Visual Studio installation...", Colors.BLUE)
    vs_paths = [
        r"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat",
        r"C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\Tools\VsDevCmd.bat",
        r"C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat",
        r"C:\Program Files\Microsoft Visual Studio\2019\Community\Common7\Tools\VsDevCmd.bat",
    ]
    
    vs_found = False
    for vs_path in vs_paths:
        if os.path.exists(vs_path):
            vs_found = True
            print_color(f"✓ Found Visual Studio: {vs_path}", Colors.GREEN)
            break
    
    if not vs_found:
        print_color("⚠️  Visual Studio not found in standard locations", Colors.YELLOW)
        print_color("   Make sure Visual Studio 2022 is installed with 'Desktop development with C++' workload", Colors.YELLOW)
    
    print_color("\n✅ Windows build fix complete!", Colors.GREEN)
    print_color("   Now try building again with option 4", Colors.BLUE)

def run_tests():
    """Run Flutter tests"""
    print_color("\n🧪 Running Flutter tests...", Colors.CYAN)
    run("flutter test", cwd=PROJECT_DIR)

def analyze_code():
    """Run Flutter analyzer"""
    print_color("\n🔍 Analyzing code...", Colors.CYAN)
    run("flutter analyze", cwd=PROJECT_DIR)

def main_menu():
    """Display main menu"""
    system = platform.system()
    
    while True:
        refresh_version_context()
        print_color(f"""
{'BUILD OPTIONS:':^50}
  1. Linux package for this distro (.deb/.rpm)
  2. Ubuntu/Debian .deb final build
  3. Fedora .rpm final build
  4. Windows installer (.exe)
  5. Android (.apk + .aab)
  6. Build All (Windows + APK)
  7. Build All (Linux package + APK)

{'RUN OPTIONS:':^50}
  8. Run Linux (debug mode)
  9. Run Windows (debug mode)
  10. Run Android (debug mode)
  11. Run with Hot Reload (development)

{'UTILITIES:':^50}
  12. Clean all build files
  13. Fix Windows build (clear CMake cache)
  14. List previous builds
  15. Open final builds directory
  16. List available devices
  17. Run tests
  18. Analyze code
  19. Exit

Current platform: {system}
Current app version: {APP_FULL_VERSION}
""")
        
        choice = input("Enter your choice (1-19): ").strip()

        if choice == "19":
            print_color("\nGoodbye!", Colors.GREEN)
            break
        
        if choice == "12":
            clean_all()
            input("\nPress Enter to continue...")
            continue
        elif choice == "13":
            if system == "Windows":
                fix_windows_build()
            else:
                print_color("This option is only for Windows!", Colors.YELLOW)
            input("\nPress Enter to continue...")
            continue
        elif choice == "14":
            list_builds()
            input("\nPress Enter to continue...")
            continue
        elif choice == "15":
            open_final_builds_dir()
            input("\nPress Enter to continue...")
            continue
        elif choice == "16":
            list_devices()
            input("\nPress Enter to continue...")
            continue
        elif choice == "17":
            run_tests()
            input("\nPress Enter to continue...")
            continue
        elif choice == "18":
            analyze_code()
            input("\nPress Enter to continue...")
            continue
        
        if not check_flutter():
            print_color("Flutter not properly configured!", Colors.RED)
            input("\nPress Enter to continue...")
            continue
        
        refresh_version_context(announce=True)
        ensure_dirs()
        
        if choice == "1":
            if system != "Linux":
                print_color("Linux builds require Linux OS!", Colors.YELLOW)
                print_color("   Run this script on Fedora, Ubuntu, Debian, or another Linux host", Colors.YELLOW)
            else:
                build_linux()
        elif choice == "2":
            if system != "Linux":
                print_color("Ubuntu/Debian .deb builds require Linux OS!", Colors.YELLOW)
            else:
                build_linux_deb()
        elif choice == "3":
            if system != "Linux":
                print_color("Fedora .rpm builds require Linux OS!", Colors.YELLOW)
            else:
                build_linux_rpm()
        elif choice == "4":
            if system != "Windows":
                print_color("Windows builds require Windows OS!", Colors.YELLOW)
                print_color("   Run this script on Windows", Colors.YELLOW)
            else:
                build_windows()
        elif choice == "5":
            build_android()
        elif choice == "6":
            if system != "Windows":
                print_color("Build All currently requires Windows for the Windows app build!", Colors.YELLOW)
                print_color("   Run this script on Windows to build Windows + APK together", Colors.YELLOW)
            else:
                build_windows_and_apk()
        elif choice == "7":
            if system != "Linux":
                print_color("Linux + APK builds require Linux OS!", Colors.YELLOW)
                print_color("   Run this script on Linux to build the native package + APK together", Colors.YELLOW)
            else:
                build_linux_and_apk()
        elif choice == "8":
            if system != "Linux":
                print_color("Linux run requires Linux OS!", Colors.YELLOW)
            else:
                run_linux()
        elif choice == "9":
            if system != "Windows":
                print_color("Windows run requires Windows OS!", Colors.YELLOW)
            else:
                run_windows()
        elif choice == "10":
            run_android()
        elif choice == "11":
            hot_reload()
        else:
            print_color("Invalid choice", Colors.RED)
        
        input("\nPress Enter to continue...")

if __name__ == "__main__":
    try:
        main_menu()
    except KeyboardInterrupt:
        print_color("\n\n👋 Build cancelled. Goodbye!", Colors.YELLOW)
        sys.exit(0)
    except Exception as e:
        print_color(f"\n❌ Unexpected error: {e}", Colors.RED)
        import traceback
        traceback.print_exc()
        sys.exit(1)
