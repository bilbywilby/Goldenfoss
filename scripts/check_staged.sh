#!/usr/bin/env bash
# Pre-commit sanitizer for tech-ref-portal
# Gates: secret scan · DAG name regex (parity with dashboard.py) · python compile
set -uo pipefail

fail=0
RED=$'\033[31m'; GRN=$'\033[32m'; NC=$'\033[0m'

# Files that are new or modified (skip deleted)
mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACMR)
if [ "${#FILES[@]}" -eq 0 ]; then exit 0; fi

DAG_RE='^[a-zA-Z0-9_\-]+\.py$'

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue

  # Gate 1: obvious secrets in staged content
  if grep -InE \
      '(MASTER_AUTH_TOKEN\s*=\s*["'"'"'][a-f0-9]{32,}|gh[pousr]_[A-Za-z0-9]{36,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|api[_-]?key\s*[:=]\s*["'"'"'][A-Za-z0-9_\-]{20,})' \
      "$f" >/tmp/husky_secret_hits 2>/dev/null; then
    echo "${RED}✖ Possible secret(s) in '$f':${NC}"
    sed 's/^/    /' /tmp/husky_secret_hits
    fail=1
  fi

  # Gate 2: DAG files must match the dashboard's sanitizer regex
  case "$f" in
    */dags/*.py|core/lib/ultra/dags/*.py)
      base=$(basename "$f")
      if ! printf '%s' "$base" | grep -qE "$DAG_RE"; then
        echo "${RED}✖ DAG filename '$base' violates dashboard sanitizer regex${NC}"
        fail=1
      fi
      ;;
  esac

  # Gate 3: compile-check staged python (use the staged blob, not the worktree)
  if [[ "$f" == *.py ]]; then
    if ! git show ":$f" | python -c 'import sys,py_compile,tempfile,os
src=sys.stdin.buffer.read()
with tempfile.NamedTemporaryFile(suffix=".py",delete=False) as t: t.write(src); p=t.name
try: py_compile.compile(p,doraise=True)
finally: os.unlink(p)' 2>/tmp/husky_py_err; then
      echo "${RED}✖ Python syntax error in '$f':${NC}"
      sed 's/^/    /' /tmp/husky_py_err
      fail=1
    fi
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "${RED}pre-commit: blocked.${NC} Fix above, or bypass a false positive with: git commit --no-verify"
  exit 1
fi
echo "${GRN}✓ pre-commit sanitizer passed (${#FILES[@]} file(s))${NC}"
