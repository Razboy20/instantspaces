#!/usr/bin/env bash
set -euo pipefail

# Auto-inject script for LaunchAgent
# Usage: auto-inject.sh [MODE] [FEATURES]

MODE="${1:-zero}"
FEATURES="${2:-all}"

OSAX_DIR="/Library/ScriptingAdditions/instantspaces.osax/Contents"
LOADER="${OSAX_DIR}/MacOS/loader"
PAYLOAD="${OSAX_DIR}/Resources/payload.dylib"

# Wait for Dock to appear
for _ in {1..30}; do
  if pgrep -x Dock >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

PID="$(pgrep -x Dock || true)"
if [[ -z "${PID}" ]]; then
  echo "Dock not running; giving up."
  exit 75  # temporary failure so launchd can retry
fi

# Check if arm64e_preview_abi boot-arg is set
use_loader=false
if nvram boot-args 2>/dev/null | grep -q "arm64e_preview_abi"; then
  if [[ -x "${LOADER}" ]]; then
    use_loader=true
  fi
fi

# Try injection with retry
tries=2
for attempt in $(seq 1 $tries); do
  echo "auto-inject attempt $attempt/$tries (mode=$MODE, features=$FEATURES)"

  if [[ "${use_loader}" == "true" ]]; then
    if "${LOADER}" -m "$MODE" -f "$FEATURES" "${PAYLOAD}"; then
      echo "auto-inject success (loader)"
      exit 0
    fi
  else
    if /usr/bin/lldb -p "${PID}" -b \
      -o "expr (int)setenv(\"INSTANTSPACES_MODE\",\"${MODE}\",1)" \
      -o "expr (int)setenv(\"INSTANTSPACES_FEATURES\",\"${FEATURES}\",1)" \
      -o "expr (void*)dlopen(\"${PAYLOAD}\", 2)" \
      -o 'process detach' \
      -o 'quit' 2>/dev/null; then
      echo "auto-inject success (lldb)"
      exit 0
    fi
  fi

  sleep 2
done

echo "auto-inject failed after $tries attempts"
exit 75
