#!/usr/bin/env bash
# Compare with the exact backend revision paired with this client release.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
ref="${BACKEND_REF:-$(cat contracts/backend-ref)}"
base="https://raw.githubusercontent.com/U2SG/aidrobe-BE/${ref}/docs"
status=0
for file in openapi.json v3-p0-contract.md v3-analytics-events.json; do
  if ! curl -fsSL "${base}/${file}" | cmp -s - "contracts/${file}"; then
    echo "contracts/${file} differs from aidrobe-BE@${ref}:docs/${file}" >&2
    status=1
  fi
done
exit "${status}"
