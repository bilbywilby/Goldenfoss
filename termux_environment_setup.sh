#!/usr/bin/env bash
# termux_environment_setup.sh — Hardened Cross-Platform & Termux Setup
set -euo pipefail

echo "=============================================="
echo "  Development Environment Remediation         "
echo "=============================================="

# --- 1. Environment Detection ----------------------------------------------
detect_environment() {
    if command -v pkg >/dev/null 2>&1; then
        echo "termux"
    elif command -v apt >/dev/null 2>&1 && [ -w /var/lib/apt/lists ]; then
        echo "linux-root"
    elif command -v apt >/dev/null 2>&1 && [ ! -w /var/lib/apt/lists ]; then
        echo "linux-no-root"
    elif command -v dnf >/dev/null 2>&1 && [ -w /var/lib/dnf ]; then
        echo "fedora-root"
    elif command -v pacman >/dev/null 2>&1; then
        echo "arch-root"
    else
        echo "unknown"
    fi
}

ENV_TYPE="$(detect_environment)"
echo "[+] Detected environment type: ${ENV_TYPE}"

# --- 2. Path Resolution ----------------------------------------------------
RESOLVED_HOME="$(realpath ~ 2>/dev/null || (cd ~ && pwd -P))"
PROJECT_NAME="tech-ref-portal"
TARGET_DIR="${RESOLVED_HOME}/${PROJECT_NAME}"

if [ ! -d "${TARGET_DIR}" ]; then
    echo "[+] Creating project directory: ${TARGET_DIR}"
    mkdir -p "${TARGET_DIR}"
fi

cd "${TARGET_DIR}"

# --- 3. Package Management -------------------------------------------------
case "$ENV_TYPE" in
    termux)
        echo "[+] Updating Termux packages..."
        pkg update -y || true
        pkg install -y nodejs-lts git coreutils curl jq yarn || true
        ;;
    linux-root)
        echo "[+] Updating Linux apt packages..."
        apt update -y || true
        apt install -y nodejs npm git coreutils curl jq || true
        ;;
    fedora-root)
        echo "[+] Updating Fedora packages..."
        dnf install -y nodejs npm git coreutils curl jq || true
        ;;
    arch-root)
        echo "[+] Updating Arch packages..."
        pacman -Sy --noconfirm nodejs npm git coreutils curl jq || true
        ;;
    linux-no-root)
        echo "[!] Running without root privileges. Skipping global package operations."
        if ! command -v node >/dev/null 2>&1; then
            echo "[ERROR] Node.js is missing and cannot be installed via system apt." >&2
            echo "        Install Node locally via nvm:" >&2
            echo "        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash" >&2
            exit 1
        fi
        ;;
    *)
        echo "[!] Unrecognized package manager. Relying on host binaries."
        ;;
esac

# --- 4. User-Space npm Prefix Configuration --------------------------------
if command -v npm >/dev/null 2>&1; then
    NPM_PREFIX="$(npm config get prefix 2>/dev/null || echo "")"
    if [ -z "${NPM_PREFIX}" ] \
       || [ ! -d "${NPM_PREFIX}/lib/node_modules" ] \
       || [ ! -w "${NPM_PREFIX}/lib/node_modules" ]; then
        echo "[+] Configuring user-space npm global path (~/.npm-global)..."
        NPM_GLOBAL="${RESOLVED_HOME}/.npm-global"
        mkdir -p "${NPM_GLOBAL}/bin"
        npm config set prefix "${NPM_GLOBAL}"
    else
        echo "[+] npm prefix '${NPM_PREFIX}' is writable; leaving it alone."
    fi
else
    echo "[!] npm not found — skipping prefix configuration."
fi

# --- 5. Global Git Pre-Commit Hook -----------------------------------------
HOOKS_DIR="${RESOLVED_HOME}/.git-hooks"
mkdir -p "${HOOKS_DIR}"

cat << 'HOOK_EOF' > "${HOOKS_DIR}/pre-commit"
#!/usr/bin/env bash
set -euo pipefail

MAX_SIZE_BYTES=$((5 * 1024 * 1024))  # 5 MB

staged_files=$(git diff --cached --name-only --diff-filter=ACM)
if [ -z "$staged_files" ]; then
    exit 0
fi

if stat -c%s /dev/null >/dev/null 2>&1; then
    stat_size() { stat -c%s "$1"; }
else
    stat_size() { stat -f%z "$1"; }
fi

while IFS= read -r file; do
    [ -z "$file" ] && continue

    case "$file" in
        *.env.example)
            : ;;   # templates are explicitly allowed
        .env|.env.*|*.env|*.env.*|*/node_modules/*|node_modules/*|*.bak|*/studio/logs/*|*/studio/workspace_backups/*)
            echo "[ERROR] Security Violation: restricted file pattern: '$file'" >&2
            exit 1
            ;;
    esac

    if [ -f "$file" ]; then
        file_size=$(stat_size "$file" 2>/dev/null || echo 0)
        if [ "$file_size" -gt "$MAX_SIZE_BYTES" ]; then
            echo "[ERROR] Staged file '$file' exceeds 5MB limit ($file_size bytes)." >&2
            exit 1
        fi
    fi
done <<< "$staged_files"

exit 0
HOOK_EOF

chmod +x "${HOOKS_DIR}/pre-commit"
git config --global core.hooksPath "${HOOKS_DIR}"
echo "[+] Pre-commit security hook installed at ${HOOKS_DIR}/pre-commit"
echo "[!] Note: core.hooksPath is global — repo-local .git/hooks are now ignored."

# --- 6. Bash Profile Extensions --------------------------------------------
BASHRC_FILE="${RESOLVED_HOME}/.bashrc"
touch "${BASHRC_FILE}"

if ! grep -q "Termux Environment Aliases" "${BASHRC_FILE}"; then
    cat << 'BASHRC_ADDITIONS' >> "${BASHRC_FILE}"

# --- Termux Environment Aliases & Helpers ---
export NPM_GLOBAL="$HOME/.npm-global"
export PATH="$NPM_GLOBAL/bin:$PATH"

alias portal='cd "$HOME/tech-ref-portal"'
alias portal-clean='find . -maxdepth 3 -type f \( -name ".env*" ! -name ".env.example" -o -name "*.bak" \) -delete && rm -rf studio/logs studio/.workspace_backups'
alias portal-audit='npm audit --audit-level=moderate'

termux_net_info() {
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig
    else
        ip addr show
    fi
}
alias netinfo='termux_net_info'
BASHRC_ADDITIONS
    echo "[+] Profile extensions added to ${BASHRC_FILE}"
else
    echo "[+] Profile extensions already exist in ${BASHRC_FILE}"
fi

# --- 7. Engine Compatibility Check ----------------------------------------
if [ -f "package.json" ] && command -v node >/dev/null 2>&1; then
    ENGINE_REQ="$(node -e "try{console.log(require('./package.json').engines.node||'')}catch(e){}" 2>/dev/null || echo "")"
    CURRENT_NODE="$(node -v | sed 's/^v//')"

    MAJOR_CURRENT="${CURRENT_NODE%%.*}"
    MAJOR_REQUIRED="$(printf '%s' "$ENGINE_REQ" | grep -oE '[0-9]+' | head -1 || echo "")"

    if [ -n "$MAJOR_REQUIRED" ] && [ -n "$MAJOR_CURRENT" ] \
       && [ "$MAJOR_CURRENT" -lt "$MAJOR_REQUIRED" ]; then
        echo ""
        echo "[!] Local Node (${CURRENT_NODE}) is below package.json requirement (${ENGINE_REQ})."
        echo "    Recommended: nvm install ${MAJOR_REQUIRED}"
        echo "    To override the manifest instead, run:"
        echo "      npm pkg set engines.node=\">=${MAJOR_CURRENT}.0.0\""
    fi
fi

echo ""
echo "=============================================="
echo "  Setup Complete!                             "
echo "=============================================="
echo "Apply to this session:"
echo "  source ~/.bashrc && npm install"
