#!/usr/bin/env python3
"""
Robust Git Repository Staging, Reconciliation, and Push Automation.
Ensures remote origin is correctly configured, stages untracked files (excluding garbage/logs),
commits with timestamp, and pushes to main.
"""

import subprocess
import sys
from datetime import datetime
from pathlib import Path

TARGET_REPO = "https://github.com/bilbywilby/Goldenfoss.git"
EXCLUSIONS = [
    ".env", ".env.*", "*.log", "*.tgz", "*.tar.gz", "*.xml",
    "github_deploy/", ".git-credentials", "__pycache__/", "node_modules/"
]

def run_cmd(cmd, cwd=None):
    res = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        print(f"[-] Command failed: {' '.join(cmd)}")
        print(res.stderr.strip())
        sys.exit(res.returncode)
    return res.stdout.strip()

def main():
    repo_dir = Path.cwd()
    print(f"[*] Target Directory: {repo_dir}")

    # Initialize git if not present
    git_dir = repo_dir / ".git"
    if not git_dir.exists():
        print("[*] Initializing git repository...")
        run_cmd(["git", "init", "-b", "main"])

    # Configure or update remote origin
    remotes = run_cmd(["git", "remote"]).splitlines()
    if "origin" in remotes:
        print("[*] Updating remote origin URL...")
        run_cmd(["git", "remote", "set-url", "origin", TARGET_REPO])
    else:
        print("[*] Adding remote origin...")
        run_cmd(["git", "remote", "add", "origin", TARGET_REPO])

    # Enforce .gitignore
    gitignore_path = repo_dir / ".gitignore"
    current_ignore = gitignore_path.read_text() if gitignore_path.exists() else ""
    missing_exclusions = [ex for ex in EXCLUSIONS if ex not in current_ignore]
    if missing_exclusions:
        print("[*] Updating .gitignore with standard exclusions...")
        with open(gitignore_path, "a") as f:
            if current_ignore and not current_ignore.endswith("\n"):
                f.write("\n")
            f.write("\n".join(missing_exclusions) + "\n")

    # Stage changes
    print("[*] Staging files...")
    run_cmd(["git", "add", "-A"])

    # Check if there are changes to commit
    status = run_cmd(["git", "status", "--porcelain"])
    if not status:
        print("[*] No uncommitted changes found.")
    else:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        commit_msg = f"feat(fortress): reconcile workspace into Goldenfoss repository [{ts}]"
        print(f"[*] Committing changes: {commit_msg}")
        run_cmd(["git", "commit", "-m", commit_msg])

    # Push to remote
    print(f"[*] Pushing to origin/main ({TARGET_REPO})...")
    run_cmd(["git", "push", "-u", "origin", "main"])
    print("[+] Repository successfully reconciled and pushed.")

if __name__ == "__main__":
    main()
