#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_SCRIPT="${SCRIPT_DIR}/../test/commercial/CDS_3D_BASE_ALL.sh"

if [[ ! -x "${CANONICAL_SCRIPT}" ]]; then
  echo "ERROR: canonical launcher not found: ${CANONICAL_SCRIPT}" >&2
  exit 1
fi

exec bash "${CANONICAL_SCRIPT}" "$@"
