#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/tests/static.sh"
"$ROOT/tests/cli-contract.sh"
"$ROOT/tests/execution-contract.sh"
"$ROOT/tests/env-contract.sh"
"$ROOT/tests/catalog-contract.sh"
"$ROOT/tests/compose-contract.sh"
"$ROOT/tests/networking-contract.sh"
"$ROOT/tests/wrappers-contract.sh"
bash "$ROOT/tests/service-hardening-contract.sh"
bash "$ROOT/tests/qol-contract.sh"
bash "$ROOT/tests/permissions-contract.sh"
bash "$ROOT/tests/docs-contract.sh"
"$ROOT/tests/runtime-php-contract.sh"
"$ROOT/tests/runtime-node-contract.sh"
"$ROOT/tests/ai-contract.sh"
"$ROOT/tests/published-images.sh"
