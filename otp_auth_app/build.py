#!/usr/bin/env python3
"""
Flutter Build Automation Script
Supports: Linux (.deb), Windows (.exe + Inno Setup), Android (.apk)
"""

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
INSTALLER_DIR = str(WORKSPACE_DIR / "installer")
CONFIG_FILE = str(WORKSPACE_DIR / "build_config.json")

# Platform-specific build dirs
LINUX_DIR = str(Path(INSTALLER_DIR) / "linux")
WINDOWS_DIR = str(Path(INSTALLER_DIR) / "windows")
ANDROID_DIR = str(Path(INSTALLER_DIR) / "android")

# App metadata (customize these)
APP_NAME = "BeatzLock"
APP_BINARY_NAME = "otp_auth_app"
DEB_PACKAGE_NAME = "beatzlock"
APP_VERSION = "1.0.0"
APP_MAINTAINER = "Your Name <your.email@example.com>"
APP_DESCRIPTION = "BeatzLock"

# ==================== HELPER FUNCTIONS ====================
def run(cmd, cwd=None):
    """Run shell command with error handling"""
    print(f"\n>>> Running: {cmd}\n")
    try:
        result = subprocess.run(cmd, shell=True, check=True, cwd=cwd, 
                               capture_output=False, text=True)
        return result
    except subprocess.CalledProcessError as e:
        print(f"❌ Command failed with exit code {e.returncode}")
        print(f"Error: {e}")
        return None

def ensure_dirs():
    """Create necessary directories"""
    for dir_path in [LINUX_DIR, WINDOWS_DIR, ANDROID_DIR]:
        os.makedirs(dir_path, exist_ok=True)
        print(f"✓ Directory ready: {dir_path}")

def check_flutter():
    """Verify Flutter is installed and configured"""
    result = run("flutter --version", cwd=PROJECT_DIR)
    if not result:
        print("❌ Flutter not found! Please install Flutter first.")
        return False
    
    # Check for required platforms
    result = run("flutter doctor", cwd=PROJECT_DIR)
    return True

def copy_with_progress(src, dst):
    """Copy file/folder with progress indication"""
    if os.path.isfile(src):
        size = os.path.getsize(src)
        print(f"📁 Copying {os.path.basename(src)} ({size // 1024} KB)")
        shutil.copy2(src, dst)
    elif os.path.isdir(src):
        if os.path.exists(dst):
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
        print(f"📁 Copied directory: {os.path.basename(src)}")

def save_build_metadata(platform_name, file_path):
    """Save build information to JSON log"""
    log_file = os.path.join(INSTALLER_DIR, "build_log.json")
    
    try:
        with open(log_file, 'r') as f:
            logs = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        logs = []
    
    logs.append({
        "platform": platform_name,
        "file": os.path.basename(file_path),
        "path": file_path,
        "timestamp": datetime.now().isoformat(),
        "version": APP_VERSION
    })
    
    with open(log_file, 'w') as f:
        json.dump(logs, f, indent=2)
    
    print(f"✓ Build info saved to {log_file}")

# ==================== LINUX BUILD ====================
def build_linux_deb():
    """Build Debian .deb package"""
    print("\n🐧 Building Linux .deb package...")
    
    # Build Flutter Linux app
    if not run("flutter build linux --release", cwd=PROJECT_DIR):
        return False
    
    bundle_path = SCRIPT_DIR / "build/linux/x64/release/bundle"
    if not bundle_path.exists():
        print("❌ Linux build failed - bundle not found")
        return False
    
    deb_dir = WORKSPACE_DIR / "deb_pkg"
    if deb_dir.exists():
        shutil.rmtree(deb_dir)
    
    # Create DEBIAN control directory
    os.makedirs(deb_dir / "DEBIAN", exist_ok=True)
    os.makedirs(deb_dir / "usr/local" / APP_NAME, exist_ok=True)
    os.makedirs(deb_dir / "usr/share/applications", exist_ok=True)
    os.makedirs(deb_dir / "usr/share/icons/hicolor/256x256/apps", exist_ok=True)
    
    # Copy app files
    shutil.copytree(bundle_path, deb_dir / "usr/local" / APP_NAME, dirs_exist_ok=True)
    
    # Create .desktop file
    desktop_content = f"""[Desktop Entry]
Version={APP_VERSION}
Name={APP_NAME}
Comment={APP_DESCRIPTION}
Exec=/usr/local/{APP_NAME}/{APP_BINARY_NAME}
Icon=/usr/local/{APP_NAME}/data/flutter_assets/assets/icon.png
Terminal=false
Type=Application
Categories=Utility;
"""
    with open(deb_dir / "usr/share/applications" / f"{APP_NAME}.desktop", "w") as f:
        f.write(desktop_content)
    
    # Create control file
    control_content = f"""Package: {DEB_PACKAGE_NAME}
Version: {APP_VERSION}
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
""".replace("{APP_NAME}", APP_NAME).replace("{APP_BINARY_NAME}", APP_BINARY_NAME)
    
    with open(deb_dir / "DEBIAN" / "postinst", "w") as f:
        f.write(postinst_content)
    os.chmod(deb_dir / "DEBIAN" / "postinst", 0o755)
    
    # Build .deb
    deb_file = f"{DEB_PACKAGE_NAME}_{APP_VERSION}_amd64.deb"
    deb_output = WORKSPACE_DIR / deb_file
    if not run(f'dpkg-deb --build "{deb_dir}" "{deb_output}"', cwd=str(WORKSPACE_DIR)):
        return False
    
    # Move to installer directory
    final_deb_path = Path(LINUX_DIR) / deb_file
    shutil.move(str(deb_output), final_deb_path)
    save_build_metadata("linux_deb", str(final_deb_path))
    
    print(f"✅ Linux .deb created: {final_deb_path}")
    return True

def build_linux():
    """Build the Linux Debian package."""
    return build_linux_deb()

# ==================== WINDOWS BUILD ====================
def create_inno_script():
    """Generate Inno Setup script dynamically"""
    inno_script = f"""; Inno Setup Script for {APP_NAME}
; Generated by build script

[Setup]
AppName={APP_NAME}
AppVersion={APP_VERSION}
DefaultDirName={{pf}}\\{APP_NAME}
DefaultGroupName={APP_NAME}
UninstallDisplayIcon={{app}}\\{APP_BINARY_NAME}.exe
Compression=lzma2
SolidCompression=yes
OutputDir={WINDOWS_DIR}
OutputBaseFilename={APP_NAME}_Setup_{APP_VERSION}
PrivilegesRequired=admin

[Files]
Source: "{WINDOWS_DIR}\\app\\*"; DestDir: "{{app}}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{{group}}\\{APP_NAME}"; Filename: "{{app}}\\{APP_BINARY_NAME}.exe"
Name: "{{group}}\\Uninstall {APP_NAME}"; Filename: "{{uninstallexe}}"
Name: "{{commondesktop}}\\{APP_NAME}"; Filename: "{{app}}\\{APP_BINARY_NAME}.exe"

[Run]
Filename: "{{app}}\\{APP_BINARY_NAME}.exe"; Description: "Launch {APP_NAME}"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{{app}}"
"""
    
    script_path = os.path.join(INSTALLER_DIR, "installer_script.iss")
    with open(script_path, 'w') as f:
        f.write(inno_script)
    return script_path

def build_windows():
    """Build Windows .exe installer using Inno Setup"""
    print("\n Windows Building Windows app...")
    
    if platform.system() != "Windows":
        print("⚠️  Windows build must be run on Windows!")
        print("   Use: GitHub Actions, Windows VM, or actual Windows machine")
        return False
    
    # Build Flutter Windows app
    if not run("flutter build windows --release", cwd=PROJECT_DIR):
        return False
    
    exe_path = os.path.join(PROJECT_DIR, "build/windows/runner/Release")
    if not os.path.exists(exe_path):
        print("❌ Windows build failed")
        return False
    
    # Copy to staging directory
    staging_dir = os.path.join(WINDOWS_DIR, "app")
    if os.path.exists(staging_dir):
        shutil.rmtree(staging_dir)
    shutil.copytree(exe_path, staging_dir)
    
    # Create Inno Setup script
    inno_script = create_inno_script()
    
    # Check if Inno Setup is installed
    iscc_paths = [
        r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        r"C:\Program Files\Inno Setup 6\ISCC.exe",
    ]
    
    iscc_found = False
    for path in iscc_paths:
        if os.path.exists(path):
            iscc_found = True
            if not run(f'"{path}" "{inno_script}"', cwd=PROJECT_DIR):
                return False
            break
    
    if not iscc_found:
        print("❌ Inno Setup not found! Please install from: https://jrsoftware.org/isdl.php")
        print(f"   Build files are in {staging_dir}")
        return False
    
    print(f"✅ Windows installer created in {WINDOWS_DIR}")
    return True

# ==================== ANDROID BUILD ====================
def build_android():
    """Build Android APK and App Bundle"""
    print("\n📱 Building Android app...")
    
    print("\nAndroid Build Options:")
    print("1. APK (Universal)")
    print("2. App Bundle (.aab - for Play Store)")
    print("3. Split APKs (per ABI)")
    print("4. Both APK and App Bundle")
    
    choice = input("Choose (1/2/3/4): ").strip()
    
    success = True
    
    if choice == "1" or choice == "4":
        if not run("flutter build apk --release", cwd=PROJECT_DIR):
            success = False
        else:
            apk_path = os.path.join(PROJECT_DIR, "build/app/outputs/flutter-apk/app-release.apk")
            if os.path.exists(apk_path):
                apk_dest = os.path.join(ANDROID_DIR, f"{APP_NAME}_v{APP_VERSION}.apk")
                shutil.copy(apk_path, apk_dest)
                save_build_metadata("android_apk", apk_dest)
                print(f"✅ APK created: {apk_dest}")
    
    if choice == "2" or choice == "4":
        if not run("flutter build appbundle --release", cwd=PROJECT_DIR):
            success = False
        else:
            aab_path = os.path.join(PROJECT_DIR, "build/app/outputs/bundle/release/app-release.aab")
            if os.path.exists(aab_path):
                aab_dest = os.path.join(ANDROID_DIR, f"{APP_NAME}_v{APP_VERSION}.aab")
                shutil.copy(aab_path, aab_dest)
                save_build_metadata("android_aab", aab_dest)
                print(f"✅ App Bundle created: {aab_dest}")
    
    if choice == "3":
        if not run("flutter build apk --release --split-per-abi", cwd=PROJECT_DIR):
            success = False
        else:
            apk_dir = os.path.join(PROJECT_DIR, "build/app/outputs/apk/release")
            for apk in ["app-armeabi-v7a-release.apk", "app-arm64-v8a-release.apk", "app-x86_64-release.apk"]:
                src = os.path.join(apk_dir, apk)
                if os.path.exists(src):
                    dst = os.path.join(ANDROID_DIR, apk.replace("app-", f"{APP_NAME}_"))
                    shutil.copy(src, dst)
                    print(f"✅ {dst}")
    
    return success

# ==================== UTILITIES ====================
def clean_all():
    """Clean all build artifacts"""
    print("\n🧹 Cleaning build artifacts...")
    
    dirs_to_clean = [
        SCRIPT_DIR / "build",
        WORKSPACE_DIR / "deb_pkg",
        SCRIPT_DIR / ".dart_tool",
    ]
    for dir_path in dirs_to_clean:
        if dir_path.exists():
            shutil.rmtree(dir_path)
            print(f"✓ Removed {dir_path}")
    
    # Clean Flutter cache
    run("flutter clean", cwd=PROJECT_DIR)
    
    print("✅ Clean complete!")

def list_builds():
    """List all previously built installers"""
    print("\n📦 Previously built installers:")
    
    for platform_dir in [LINUX_DIR, WINDOWS_DIR, ANDROID_DIR]:
        if os.path.exists(platform_dir) and os.listdir(platform_dir):
            print(f"\n{platform_dir.split('/')[-1].upper()}:")
            for file in os.listdir(platform_dir):
                file_path = os.path.join(platform_dir, file)
                size = os.path.getsize(file_path) // (1024 * 1024)
                print(f"  📄 {file} ({size} MB)")
        else:
            print(f"\n{platform_dir.split('/')[-1].upper()}: No builds found")

def open_installer_dir():
    """Open installer directory in file manager"""
    if os.path.exists(INSTALLER_DIR):
        if platform.system() == "Linux":
            run(f'xdg-open "{INSTALLER_DIR}"')
        elif platform.system() == "Windows":
            run(f'explorer "{INSTALLER_DIR}"')
        else:
            print(f"Installer directory: {INSTALLER_DIR}")

# ==================== MAIN MENU ====================
def main_menu():
    """Display main menu"""
    system = platform.system()
    
    while True:
        print(f"""
╔══════════════════════════════════════════╗
║     Flutter Build Automation v{APP_VERSION}        ║
║     System: {system}                         ║
╚══════════════════════════════════════════╝

📦 Build Options:
  1. 🐧 Linux (.deb)
  2. 🪟 Windows (.exe + Inno Setup)
  3. 📱 Android (.apk + .aab)
  4. 🔨 Build ALL (for current OS)

🛠️  Utilities:
  5. 🧹 Clean all build files
  6. 📋 List previous builds
  7. 📂 Open installer directory
  8. 🚪 Exit

Current platform: {system}
""")
        
        choice = input("Enter your choice (1-8): ").strip()

        if choice == "8":
            print("\n👋 Goodbye!")
            break
        elif choice in {"6", "7"}:
            if choice == "6":
                list_builds()
            else:
                open_installer_dir()
            continue
        elif choice == "5":
            clean_all()
            continue

        if not check_flutter():
            print("❌ Flutter not properly configured!")
            continue

        ensure_dirs()

        if choice == "1":
            build_linux()
        elif choice == "2":
            if system != "Windows":
                print("⚠️  Windows builds require Windows OS!")
                print("   Use option 8 to exit, then run on Windows")
                input("Press Enter to continue...")
            else:
                build_windows()
        elif choice == "3":
            build_android()
        elif choice == "4":
            if system == "Linux":
                build_linux()
                build_android()
            elif system == "Windows":
                build_windows()
                build_android()
            else:
                print("❌ Unsupported OS for building all targets")
        else:
            print("❌ Invalid choice")

if __name__ == "__main__":
    try:
        main_menu()
    except KeyboardInterrupt:
        print("\n\n👋 Build cancelled. Goodbye!")
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ Unexpected error: {e}")
        sys.exit(1)
