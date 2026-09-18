#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

images=(
  "infocyph/tools:0.23.2"
  "infocyph/runner:0.5"
  "infocyph/nginx:0.4.1"
  "infocyph/apache:0.4.2"
)

for image in "${images[@]}"; do
  printf 'Pulling %s\n' "$image"
  docker pull "$image"
  docker image inspect "$image" >/dev/null
done
pass "published infrastructure compatibility images exist"

for image in "infocyph/tools:0.23.2" "infocyph/runner:0.5"; do
  health="$(docker image inspect "$image" --format '{{json .Config.Healthcheck}}')"
  [[ -n "$health" && "$health" != "null" ]] || fail "$image must publish a healthcheck"
done
pass "Tools and Runner publish healthchecks"

# The model-bearing LLM image is intentionally not pulled on every PR.
# Its exact release reference is still characterized here and is exercised
# by the LocalDevStack real-provider release gate once AI integration lands.
assert_file_contains "$ROOT/docs/plans/docker-ecosystem/07-localdevstack-integration-plan.md" 'infocyph/llm-sm:0.03'
assert_file_contains "$ROOT/docs/plans/docker-ecosystem/07-localdevstack-integration-plan.md" 'infocyph/llm-sm:amd-0.03'
pass "LLM release references are pinned in the integration plan"
