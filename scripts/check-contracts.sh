#!/usr/bin/env bash
# Fails when contracts/ drifts from the backend's canonical copies (U2SG/aidrobe-BE@main).
set -euo pipefail
ref="${BACKEND_REF:-main}"
base="https://raw.githubusercontent.com/U2SG/aidrobe-BE/${ref}/docs"
status=0
for file in openapi.json v3-p0-contract.md v3-analytics-events.json; do
  if ! curl -fsSL "${base}/${file}" | cmp -s - "contracts/${file}"; then
    echo "contracts/${file} differs from aidrobe-BE@${ref}:docs/${file}" >&2
    status=1
  fi
done
exit "${status}"
