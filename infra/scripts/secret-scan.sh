#!/usr/bin/env bash
# Secret scan. Uses gitleaks when installed; otherwise a grep fallback over tracked + staged files.
# Usage: secret-scan.sh            (staged changes — run after `git add`, before `git commit`)
#        secret-scan.sh --history  (every commit in git history)
# Gitignored files (.env.local etc.) are never committed, so they are not scanned.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if command -v gitleaks >/dev/null 2>&1; then
  if [[ "${1:-}" == "--history" ]]; then
    gitleaks git --redact --no-banner .
  else
    gitleaks git --pre-commit --staged --redact --no-banner .
  fi
  exit $?
fi
echo "gitleaks not installed — using grep fallback" >&2
PATTERN='-----BEGIN [A-Z ]*PRIVATE KEY-----|sk_live_[0-9a-zA-Z]{10,}|AKIA[0-9A-Z]{16}|[A-Za-z0-9+/]{80,}={0,2}'
EXCLUDE=':!*pnpm-lock.yaml :!*pubspec.lock :!*.pdf :!*.png :!*.ttf :!infra/scripts/secret-scan.sh'
if [[ "${1:-}" == "--history" ]]; then
  # shellcheck disable=SC2086
  if git grep -nIE "$PATTERN" $(git rev-list --all) -- . $EXCLUDE; then echo "SECRET SCAN FAILED" >&2; exit 1; fi
else
  # shellcheck disable=SC2086
  FILES=$(git diff --cached --name-only --diff-filter=ACM -- . $EXCLUDE)
  if [[ -n "$FILES" ]] && echo "$FILES" | xargs grep -nIE "$PATTERN" 2>/dev/null; then echo "SECRET SCAN FAILED" >&2; exit 1; fi
fi
echo "secret scan: clean"
