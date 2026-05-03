
from __future__ import annotations

import os
import shutil
import subprocess
import platform
import sys
import json
from datetime import datetime
from pathlib import Path

# ==================== CONFIGURATION ====================
SCRIPT_DIR = Path(__file__).resolve().parent
WORKSPACE_DIR = SCRIPT_DIR.parent
PROJECT_DIR = str(SCRIPT_DIR)
FINAL_BUILDS_DIR = WORKSPACE_DIR / "final_builds"
CONFIG_FILE = str(WORKSPACE_DIR / "build_config.json")
PUBSPEC_FILE = SCRIPT_DIR / "pubspec.yaml"
INNO_SCRIPT_DIR = WORKSPACE_DIR / "inno_script"
VC_REDIST_DIR = WORKSPACE_DIR / "vc_redist"
INNO_SCRIPT_SEEDS = [
    INNO_SCRIPT_DIR / "BeatzLock v1.iss",
    INNO_SCRIPT_DIR / "BeatzLock.iss",
    WORKSPACE_DIR / "BeatzLock v1.iss",
    WORKSPACE_DIR / "BeatzLock.iss",
]

# Platform-specific build dirs
LINUX_DIR = str(FINAL_BUILDS_DIR / "linux")
WINDOWS_DIR = str(FINAL_BUILDS_DIR / "windows")
ANDROID_DIR = str(FINAL_BUILDS_DIR / "android")

# App metadata (customize these)
APP_NAME = "BeatzLock"
DEB_PACKAGE_NAME = "beatzlock"
LINUX_APPLICATION_ID = "com.beatzlock.auth"
APP_MAINTAINER = "Felix Mokaya <felixmokayabeatz@proton.me>"
APP_DESCRIPTION = "BeatzLock OTP Authentication App"

# Color codes for terminal output (Windows & Linux compatible)
class Colors:
    """ANSI color codes for terminal output"""
    if platform.system() == "Windows":
        # Windows doesn't support ANSI by default, but we'll still use them
        # They work in Windows Terminal and PowerShell 7+
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
    # Check if running in a terminal that supports colors
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


def get_platform_version_dir(platform_name: str) -> Path:
    """Return final_builds/<platform>/<version>/ for released artifacts."""
    return FINAL_BUILDS_DIR / platform_name / APP_ARTIFACT_VERSION


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

    if announce:
        print_color(f"Using app version: {APP_FULL_VERSION}", Colors.GREEN)


refresh_version_context()

def get_linux_bundle_binary_name(bundle_path: Path) -> str:
    """Return the main executable name produced by the Flutter Linux bundle."""
    for entry in bundle_path.iterdir():
        if entry.is_file() and os.access(entry, os.X_OK):
            return entry.name
    raise FileNotFoundError(f"No executable found in Linux bundle: {bundle_path}")


def sync_inno_setup_script(script_path: Path):
    """Update the Inno script for the current version and output folder."""
    if not script_path.exists():
        return False

    app_source_dir = to_inno_path(get_windows_app_dir())
    output_dir = to_inno_path(get_windows_installer_dir())
    vc_redist_path = to_inno_path(VC_REDIST_DIR / "VC_redist.x64.exe")

    lines = script_path.read_text(encoding="utf-8").splitlines()
    updated_lines = []
    saw_app_version_define = False
    saw_artifact_define = False

    for line in lines:
        stripped = line.strip()

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

        if stripped.startswith("OutputDir="):
            updated_lines.append(f"OutputDir={output_dir}")
            continue

        if stripped.startswith("OutputBaseFilename="):
            updated_lines.append("OutputBaseFilename=beatzlock_{#MyAppArtifactVersion}_x64")
            continue

        if stripped.startswith("Source: ") and "\\final_builds\\windows\\" in stripped.lower():
            lower_line = line.lower()
            quote_start = line.find('"')
            app_index = lower_line.find("\\app", quote_start)
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
        shutil.move(str(script_path), target_script_path)
        script_path = target_script_path
        print_color(f"Inno Setup script renamed to: {script_path}", Colors.GREEN)

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
        save_build_metadata("windows_installer", str(expected_output))
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


def run(cmd, cwd=None, shell=True, capture_output=False):
    """Run shell command with error handling"""
    print_color(f"\n>>> Running: {cmd}", Colors.CYAN)
    try:
        if capture_output:
            result = subprocess.run(cmd, shell=shell, check=True, cwd=cwd, 
                                   capture_output=True, text=True)
            return result
        else:
            result = subprocess.run(cmd, shell=shell, check=True, cwd=cwd, 
                                   capture_output=False, text=True)
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
    for dir_path in [LINUX_DIR, WINDOWS_DIR, ANDROID_DIR]:
        os.makedirs(dir_path, exist_ok=True)
        print_color(f"✓ Directory ready: {dir_path}", Colors.GREEN)

def check_flutter():
    """Verify Flutter is installed and configured"""
    result = run("flutter --version", cwd=PROJECT_DIR, capture_output=True)
    if not result:
        print_color("❌ Flutter not found! Please install Flutter first.", Colors.RED)
        return False
    
    # Quick check - don't run full doctor unless needed
    return True

def check_linux_desktop_requirements():
    """Verify Linux desktop build tools are installed before running Flutter."""
    if platform.system() != "Linux":
        return True

    missing_tools = []
    for tool in ["cmake", "ninja", "pkg-config"]:
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
    print("  sudo apt update")
    print("  sudo apt install cmake ninja-build pkg-config libgtk-3-dev libwebp-dev")
    print_color("\nThen try the Linux run/build again.", Colors.BLUE)
    return False

def check_device_connected():
    """Check if an Android device/emulator is connected"""
    result = run("adb devices", cwd=PROJECT_DIR, capture_output=True)
    if result and result.stdout:
        lines = result.stdout.strip().split('\n')
        devices = [l for l in lines[1:] if l.strip() and 'device' in l and 'offline' not in l]
        return len(devices) > 0
    return False

def save_build_metadata(platform_name, file_path):
    """Save build information to JSON log"""
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

def clean_windows_cache():
    """Clean Windows build cache to fix CMake generator mismatch"""
    print_color("\n🧹 Cleaning Windows CMake cache...", Colors.YELLOW)
    
    # Paths to clean
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
    
    # Run flutter clean
    run("flutter clean", cwd=PROJECT_DIR)
    
    print_color("✅ Windows CMake cache cleaned!", Colors.GREEN)

# ==================== RUN FUNCTIONS ====================
def run_linux():
    """Run the Linux app in debug mode"""
    print_color("\n🐧 Running Linux app...", Colors.CYAN)
    
    if platform.system() != "Linux":
        print_color("⚠️  Linux app can only be run on Linux!", Colors.YELLOW)
        return False

    if not check_linux_desktop_requirements():
        return False
    
    print_color("Starting Linux app (press Ctrl+C to stop)...", Colors.GREEN)
    run("flutter run -d linux", cwd=PROJECT_DIR)
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

def run_web():
    """Run the app in web browser"""
    print_color("\n🌐 Running Web app...", Colors.CYAN)
    
    print_color("Starting web server (press Ctrl+C to stop)...", Colors.GREEN)
    print_color("   Open Chrome to see the app", Colors.BLUE)
    run("flutter run -d chrome", cwd=PROJECT_DIR)
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
        run("flutter run", cwd=PROJECT_DIR)

# ==================== BUILD FUNCTIONS ====================
def build_linux_deb(skip_deb_package=False):
    """Build Debian .deb package"""
    print_color("\n🐧 Building Linux .deb package...", Colors.CYAN)

    if not check_linux_desktop_requirements():
        return False
    
    # Build Flutter Linux app
    if not run("flutter build linux --release", cwd=PROJECT_DIR):
        return False
    
    bundle_path = SCRIPT_DIR / "build/linux/x64/release/bundle"
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

        # Create DEBIAN control directory
        os.makedirs(deb_dir / "DEBIAN", exist_ok=True)
        os.makedirs(deb_dir / "usr/local" / APP_NAME, exist_ok=True)
        os.makedirs(deb_dir / "usr/share/applications", exist_ok=True)
        os.makedirs(deb_dir / "usr/share/icons/hicolor/256x256/apps", exist_ok=True)

        # Copy app files
        shutil.copytree(bundle_path, deb_dir / "usr/local" / APP_NAME, dirs_exist_ok=True)
        linux_icon_source = SCRIPT_DIR / "linux/runner/resources/app_icon.png"
        if linux_icon_source.exists():
            shutil.copy2(
                linux_icon_source,
                deb_dir / "usr/share/icons/hicolor/256x256/apps" / f"{LINUX_APPLICATION_ID}.png",
            )

        desktop_file_source = SCRIPT_DIR / "linux/runner/resources" / f"{LINUX_APPLICATION_ID}.desktop"
        if not desktop_file_source.exists():
            print_color(f"❌ Linux desktop file not found: {desktop_file_source}", Colors.RED)
            return False
        shutil.copy2(
            desktop_file_source,
            deb_dir / "usr/share/applications" / f"{LINUX_APPLICATION_ID}.desktop",
        )

        # Create control file
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

        # Optional: Create post-installation script
        postinst_content = """#!/bin/bash
set -e
chmod +x /usr/local/{APP_NAME}/{APP_BINARY_NAME}
echo "✓ {APP_NAME} installed successfully"
exit 0
""".replace("{APP_NAME}", APP_NAME).replace("{APP_BINARY_NAME}", linux_binary_name)

        with open(deb_dir / "DEBIAN" / "postinst", "w") as f:
            f.write(postinst_content)
        os.chmod(deb_dir / "DEBIAN" / "postinst", 0o755)

        # Build .deb
        deb_file = f"{DEB_PACKAGE_NAME}_{APP_ARTIFACT_VERSION}_amd64.deb"
        deb_output = WORKSPACE_DIR / deb_file
        if not run(f'dpkg-deb --build "{deb_dir}" "{deb_output}"', cwd=str(WORKSPACE_DIR)):
            return False

        # Move to platform/version directory
        linux_version_dir = get_platform_version_dir("linux")
        linux_version_dir.mkdir(parents=True, exist_ok=True)
        final_deb_path = linux_version_dir / deb_file
        if final_deb_path.exists():
            final_deb_path.unlink()
        shutil.move(str(deb_output), final_deb_path)
        save_build_metadata("linux_deb", str(final_deb_path))

        print_color(f"✅ Linux .deb created: {final_deb_path}", Colors.GREEN)
        return True
    finally:
        if deb_dir.exists():
            shutil.rmtree(deb_dir)
            print_color(f"✓ Removed temporary Debian package folder: {deb_dir}", Colors.GREEN)

def build_linux():
    """Build the Linux Debian package."""
    return build_linux_deb()

def build_windows():
    """Build Windows app files and copy them to the final builds folder"""
    print_color("\nWindows build starting...", Colors.CYAN)
    
    if platform.system() != "Windows":
        print_color("Windows build must be run on Windows!", Colors.YELLOW)
        print_color("   Use: GitHub Actions, Windows VM, or actual Windows machine", Colors.YELLOW)
        return False
    
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
    save_build_metadata("windows_exe", str(final_build_dir))
    
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
                save_build_metadata("android_apk", str(apk_dest))
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
                save_build_metadata("android_aab", str(aab_dest))
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
                    print_color(f"✅ {dst}", Colors.GREEN)
    
    return success


def build_windows_and_apk():
    """Build Windows artifacts and Android APK in one run."""
    print_color("\nBuilding Windows and Android APK artifacts...", Colors.CYAN)
    windows_ok = build_windows()
    android_ok = build_android("1")
    return windows_ok and android_ok


def build_linux_and_apk():
    """Build Linux .deb and Android APK in one run."""
    print_color("\nBuilding Linux and Android APK artifacts...", Colors.CYAN)
    linux_ok = build_linux()
    android_ok = build_android("1")
    return linux_ok and android_ok

# ==================== UTILITIES ====================
def clean_all():
    """Clean all build artifacts"""
    print_color("\n🧹 Cleaning all build artifacts...", Colors.YELLOW)
    
    dirs_to_clean = [
        SCRIPT_DIR / "build",
        WORKSPACE_DIR / "deb_pkg",
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
    
    # Clean Flutter cache
    run("flutter clean", cwd=PROJECT_DIR)
    
    print_color("✅ Clean complete!", Colors.GREEN)

def list_builds():
    """List all previously built outputs"""
    print_color("\nPreviously built outputs:", Colors.CYAN)
    
    found = False
    for platform_dir in [Path(LINUX_DIR), Path(WINDOWS_DIR), Path(ANDROID_DIR)]:
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
    
    # Clean all caches
    clean_windows_cache()
    
    # Check Visual Studio
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
    print_color("   Now try building again with option 2", Colors.BLUE)

def run_tests():
    """Run Flutter tests"""
    print_color("\n🧪 Running Flutter tests...", Colors.CYAN)
    run("flutter test", cwd=PROJECT_DIR)

def analyze_code():
    """Run Flutter analyzer"""
    print_color("\n🔍 Analyzing code...", Colors.CYAN)
    run("flutter analyze", cwd=PROJECT_DIR)

# ==================== MAIN MENU ====================
def main_menu():
    """Display main menu"""
    system = platform.system()
    
    while True:
        refresh_version_context()
        print_color(f"""
{'BUILD OPTIONS:':^50}
  1. Linux (.deb final build)
  2. Windows installer (.exe)
  3. Android (.apk + .aab)
  4. Build All (Windows + APK)
  5. Build All (Linux + APK)

{'RUN OPTIONS:':^50}
  6. Run Linux (debug mode)
  7. Run Windows (debug mode)
  8. Run Android (debug mode)
  9. Run Web (Chrome)
  10. Run with Hot Reload (development)

{'UTILITIES:':^50}
  11. Clean all build files
  12. Fix Windows build (clear CMake cache)
  13. List previous builds
  14. Open final builds directory
  15. List available devices
  16. Run tests
  17. Analyze code
  18. Exit

Current platform: {system}
Current app version: {APP_FULL_VERSION}
""")
        
        choice = input("Enter your choice (1-18): ").strip()

        if choice == "18":
            print_color("\nGoodbye!", Colors.GREEN)
            break
        
        if choice == "11":
            clean_all()
            input("\nPress Enter to continue...")
            continue
        elif choice == "12":
            if system == "Windows":
                fix_windows_build()
            else:
                print_color("This option is only for Windows!", Colors.YELLOW)
            input("\nPress Enter to continue...")
            continue
        elif choice == "13":
            list_builds()
            input("\nPress Enter to continue...")
            continue
        elif choice == "14":
            open_final_builds_dir()
            input("\nPress Enter to continue...")
            continue
        elif choice == "15":
            list_devices()
            input("\nPress Enter to continue...")
            continue
        elif choice == "16":
            run_tests()
            input("\nPress Enter to continue...")
            continue
        elif choice == "17":
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
                print_color("   This script must be run on Ubuntu/Debian", Colors.YELLOW)
            else:
                build_linux()
        elif choice == "2":
            if system != "Windows":
                print_color("Windows builds require Windows OS!", Colors.YELLOW)
                print_color("   Run this script on Windows", Colors.YELLOW)
            else:
                build_windows()
        elif choice == "3":
            build_android()
        elif choice == "4":
            if system != "Windows":
                print_color("Build All currently requires Windows for the Windows app build!", Colors.YELLOW)
                print_color("   Run this script on Windows to build Windows + APK together", Colors.YELLOW)
            else:
                build_windows_and_apk()
        elif choice == "5":
            if system != "Linux":
                print_color("Linux + APK builds require Linux OS!", Colors.YELLOW)
                print_color("   Run this script on Linux to build the .deb + APK together", Colors.YELLOW)
            else:
                build_linux_and_apk()
        elif choice == "6":
            if system != "Linux":
                print_color("Linux run requires Linux OS!", Colors.YELLOW)
            else:
                run_linux()
        elif choice == "7":
            if system != "Windows":
                print_color("Windows run requires Windows OS!", Colors.YELLOW)
            else:
                run_windows()
        elif choice == "8":
            run_android()
        elif choice == "9":
            run_web()
        elif choice == "10":
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
