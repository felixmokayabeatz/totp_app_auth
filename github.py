#!/usr/bin/env python3
"""
Git Configuration Helper Script
Sets up git user.name and user.email either globally or for current repo
"""

import subprocess
import sys
import os

# Your details
USERNAME = "felixmokayabeatz"
EMAIL = "130485404+felixmokayabeatz@users.noreply.github.com"

def run_git_command(args):
    """Run a git command and return output"""
    try:
        result = subprocess.run(['git'] + args, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        # Don't print errors for config queries (they just mean not set)
        if "config" in args and "user.name" in args:
            return None
        print(f"Error: {e.stderr}")
        return None

def check_git_repo():
    """Check if current directory is a git repository"""
    try:
        subprocess.run(['git', 'rev-parse', '--git-dir'], capture_output=True, check=True)
        return True
    except subprocess.CalledProcessError:
        return False

def set_config(scope, username, email):
    """Set git config for given scope"""
    scope_text = "global" if scope == '--global' else "local"
    print(f"\n🔧 Setting up Git configuration ({scope_text})...")
    print(f"   Username: {username}")
    print(f"   Email: {email}")
    
    # Set username
    result_user = run_git_command(['config', scope, 'user.name', username])
    # Set email  
    result_email = run_git_command(['config', scope, 'user.email', email])
    
    if result_user is not None and result_email is not None:
        print(f"✅ Git configuration set successfully ({scope_text})")
        return True
    else:
        print(f"❌ Failed to set configuration ({scope_text})")
        return False

def show_current_config():
    """Show current git configuration"""
    print("\n📋 Current Git Configuration:")
    
    # Global config
    global_name = run_git_command(['config', '--global', 'user.name'])
    global_email = run_git_command(['config', '--global', 'user.email'])
    
    print(f"   Global:  {global_name or '(not set)'} <{global_email or '(not set)'}>")
    
    # Local config (if in repo)
    if check_git_repo():
        local_name = run_git_command(['config', 'user.name'])
        local_email = run_git_command(['config', 'user.email'])
        print(f"   Local:   {local_name or '(not set)'} <{local_email or '(not set)'}>")
    
    print()

def main():
    print("\n" + "="*50)
    print("🚀 Git Configuration Helper")
    print("="*50)
    
    # Check if we're in a git repo
    in_repo = check_git_repo()
    
    if not in_repo:
        print("\n⚠️  Not in a git repository!")
        print("   Only global configuration will be available.\n")
    
    # Show current config
    show_current_config()
    
    # Ask user for preference
    if in_repo:
        print("Where would you like to set the configuration?")
        print("  1) 🌍 Global (for all repositories)")
        print("  2) 📁 Local (only for this repository)")
        print("  3) 🔄 Both")
        choice = input("\nYour choice (1/2/3): ").strip()
    else:
        print("Setting configuration globally (only option available)...")
        choice = "1"
    
    # Set configuration based on choice
    if choice == "1":
        set_config('--global', USERNAME, EMAIL)
    elif choice == "2":
        if in_repo:
            set_config('--local', USERNAME, EMAIL)
        else:
            print("❌ Cannot set local config - not in a git repository!")
    elif choice == "3":
        set_config('--global', USERNAME, EMAIL)
        if in_repo:
            set_config('--local', USERNAME, EMAIL)
        else:
            print("⚠️  Skipping local config - not in a git repository!")
    else:
        print("❌ Invalid choice. Exiting.")
        sys.exit(1)
    
    # Show updated config
    print("\n" + "="*50)
    print("✅ Updated Configuration:")
    show_current_config()
    
    print("\n💡 You can now commit normally!")
    print("="*50 + "\n")

if __name__ == "__main__":
    main()