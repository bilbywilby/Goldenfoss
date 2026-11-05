#!/usr/bin/env bash
​==============================================================================
​🏰 XLean Fortress Reconcile & Push Script
​Purpose: Unpack archives, audit secrets, quarantine junk, stage clean files,
​and safely commit/push to github.com/bilbywilby/Goldenfoss.git
​==============================================================================
​set -euo pipefail
​TARGET_REPO="https://github.com/bilbywilby/Goldenfoss.git"
STAGE_DIR="$HOME/goldenfoss-staging"
LOG_DIR="HOME/.audit_logs"
TS=(date +"%Y%m%d_%H%M%S")
​echo "🚀 [1/5] Initializing Termux Environment Audit & Unpacking..."
​1. Unpack archived bundles if present
​for archive in pixel-terminal-master..tgz animated-umbrella.tar.gz vid2gif-repo.tar.gz test-backup.tar.gz; do
if [ -f "$archive" ]; then
echo "📦 Unpacking archive..."
mkdir -p "{archive%.}"
tar -xzf "archive" -C "{archive%.*}" 2>/dev/null || true
fi
done
​2. Execute Python audit & quarantine tool
​echo "🔍 [2/5] Running zero-leak audit engine..."
mkdir -p "$LOG_DIR"
if [ -f "$HOME/bin/home_audit.py" ]; then
python3 "$HOME/bin/home_audit.py" --quarantine-junk --stage --stage-dir "$STAGE_DIR"
elif [ -f "home_audit.py" ]; then
python3 home_audit.py --quarantine-junk --stage --stage-dir "$STAGE_DIR"
else
echo "⚠️  home_audit.py not found in path. Creating minimal staging directory..."
mkdir -p "$STAGE_DIR"
fi
​3. Verify Staging Security & Git Initialization
​echo "🔒 [3/5] Verifying Goldenfoss Target Repository..."
cd "$STAGE_DIR"
​if [ ! -d ".git" ]; then
git init -b main
git remote add origin "$TARGET_REPO" || git remote set-url origin "$TARGET_REPO"
fi
​4. Enforce Strict Security Exclusions
​cat <<'EOF' > .gitignore
.env
.env.*
*.log
*.tgz
*.tar.gz
*.xml
github_deploy/
.git-credentials
.pypirc
.npmrc
pycache/
node_modules/
EOF
​5. Commit and Push Gateway
​echo "📤 [4/5] Preparing safe commit payload..."
git add -A
​if git diff --cached --quiet; then
echo "ℹ️ No new uncommitted changes found in staging."
else
git commit -m "feat(fortress): reconcile home workspace into Goldenfoss repository [$TS]"
echo "🚀 [5/5] Pushing to $TARGET_REPO..."
git push -u origin main
fi
​echo "✅ Reconciliation and Push Complete!"
