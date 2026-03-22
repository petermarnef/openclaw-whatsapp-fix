#!/usr/bin/env bash
# apply-fix.sh — Monkey-patch for OpenClaw WhatsApp outbound bug
#
# Root cause: Rollup code-splitting duplicates src/web/active-listener.ts
# across multiple chunks, each with its own Map() instance. This patch
# replaces all instances with a globalThis singleton.
#
# Usage:
#   ./apply-fix.sh apply          Apply the patch
#   ./apply-fix.sh revert         Revert to original files
#   ./apply-fix.sh verify         Check patch status
#   ./apply-fix.sh detect [ver]   Find files to patch for a version

set -euo pipefail

VERSION="${OPENCLAW_VERSION:-2026.3.13}"
DIST="/opt/homebrew/Cellar/openclaw-cli/${VERSION}/libexec/lib/node_modules/openclaw/dist"
BACKUP="${HOME}/.openclaw/backups/dist-${VERSION}-pre-wa-fix"

detect_files() {
  local dist="${1:-$DIST}"
  grep -rl "active-listener" "${dist}"/*.js "${dist}"/**/*.js 2>/dev/null | while read -r f; do
    local base=$(basename "$f")
    [[ "$base" == "entry.js" ]] && continue
    echo "$f"
  done
}

cmd_apply() {
  echo "=== OpenClaw WhatsApp Outbound Fix ==="
  echo "Version: ${VERSION}"
  [[ ! -d "$DIST" ]] && echo "ERROR: $DIST not found" && exit 1

  local files=$(detect_files)
  [[ -z "$files" ]] && echo "No files to patch found." && exit 1

  mkdir -p "$BACKUP"
  echo "Backing up..."
  echo "$files" | while read -r f; do
    cp "$f" "$BACKUP/$(basename "$f")"
    echo "  $(basename "$f")"
  done

  echo "Patching..."
  echo "$files" | while read -r f; do
    sed -i '' 's|const listeners = /\* @__PURE__ \*/ new Map();|const listeners = globalThis.__openclaw_wa_listeners ??= new Map();|g' "$f"
    local c=$(grep -c "globalThis.__openclaw_wa_listeners" "$f" || true)
    echo "  $(basename "$f"): $c occurrence(s)"
  done

  echo ""
  if grep -q "globalThis.__openclaw_wa_listeners" "${DIST}/entry.js" 2>/dev/null; then
    echo "ERROR: entry.js was patched! Restore immediately."
    exit 1
  fi
  echo "entry.js: clean (not patched)"
  echo ""
  echo "Restart gateway: openclaw gateway restart"
}

cmd_revert() {
  [[ ! -d "$BACKUP" ]] && echo "No backup found at $BACKUP" && exit 1
  for f in "$BACKUP"/*.js; do
    cp "$f" "$DIST/$(basename "$f")"
    echo "Restored: $(basename "$f")"
  done
  echo "Restart gateway: openclaw gateway restart"
}

cmd_verify() {
  echo "=== Patch Status ==="
  detect_files | while read -r f; do
    local c=$(grep -c "globalThis.__openclaw_wa_listeners" "$f" || echo 0)
    local s=$([[ "$c" -ge 1 ]] && echo "PATCHED" || echo "NOT PATCHED")
    echo "  $s: $(basename "$f")"
  done
  local ec=$(grep -c "globalThis.__openclaw_wa_listeners" "${DIST}/entry.js" 2>/dev/null || echo 0)
  echo "  $([[ "$ec" -eq 0 ]] && echo "OK" || echo "ERROR"): entry.js"
}

cmd_detect() {
  local ver="${1:-$VERSION}"
  local d="/opt/homebrew/Cellar/openclaw-cli/${ver}/libexec/lib/node_modules/openclaw/dist"
  echo "=== Files with active-listener.ts in OpenClaw ${ver} ==="
  [[ ! -d "$d" ]] && echo "Not found: $d" && exit 1
  detect_files "$d" | while read -r f; do echo "  PATCH: $(basename "$f")"; done
  echo ""
  echo "entry.js: SKIP (signal handlers)"
}

case "${1:-help}" in
  apply)   cmd_apply ;;
  revert)  cmd_revert ;;
  verify)  cmd_verify ;;
  detect)  cmd_detect "${2:-}" ;;
  *)       echo "Usage: $0 {apply|revert|verify|detect [version]}" ;;
esac
