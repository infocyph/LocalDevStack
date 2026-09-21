#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

user_env="$ROOT/docker/.env"
backup=""
had_env=0
if [[ -e "$user_env" ]]; then
  had_env=1
  backup="$(mktemp)"
  cp "$user_env" "$backup"
fi
cleanup() {
  if ((had_env)); then
    cp "$backup" "$user_env"
    rm -f "$backup"
  else
    rm -f "$user_env"
  fi
}
trap cleanup EXIT

cat >"$user_env" <<EOF
COMPOSE_PROFILES=postgresql,redis,ai,mysql
LDS_AI_RUNTIME=cpu
MYSQL_ROOT_PASSWORD=supersecret-ci-value
EOF

tmpbin="$(mktemp -d)"
trap 'rm -rf "$tmpbin"; cleanup' EXIT
cat >"$tmpbin/docker" <<'SH'
#!/usr/bin/env sh
echo "docker should not be executed for this command" >&2
exit 97
SH
chmod +x "$tmpbin/docker"

images="$(PATH="$tmpbin:$PATH" "$ROOT/lds" images)"
assert_contains "$images" "infocyph/tools:latest"
assert_contains "$images" "infocyph/runner:latest"
assert_contains "$images" "infocyph/nginx:latest"
assert_contains "$images" "infocyph/apache:latest"
assert_contains "$images" "postgres:alpine"
assert_contains "$images" "docker.elastic.co/elasticsearch/elasticsearch:9.5.4"
assert_contains "$images" "infocyph/llm-ollama:latest"
assert_contains "$images" "LLM provider"
assert_contains "$images" "ollama"
assert_contains "$images" "localdevstack-php:<selected-version> (Alpine)"
pass "images is offline-safe and reports fixed plus configurable image selections"

urls="$(PATH="$tmpbin:$PATH" "$ROOT/lds" urls)"
assert_contains "$urls" "https://admin.localhost"
assert_contains "$urls" "https://webmail.localhost"
assert_contains "$urls" "https://db.localhost"
assert_contains "$urls" "https://ri.localhost"
assert_contains "$urls" "https://llm.localhost"
if grep -Fq "https://kibana.localhost" <<<"$urls"; then
  fail "urls must not show disabled Elasticsearch profile URL"
fi
pass "urls is profile-aware and offline-safe"

env_used="$(PATH="$tmpbin:$PATH" "$ROOT/lds" config env-used)"
assert_contains "$env_used" $'user\tCOMPOSE_PROFILES'
assert_contains "$env_used" $'release\tSCRIPTOMATIC_REF'
if grep -Fq "supersecret-ci-value" <<<"$env_used"; then
  fail "config env-used leaked a value"
fi
pass "config env-used reports keys only"

redacted="$("$ROOT/lds" config show)"
if grep -Fq "supersecret-ci-value" <<<"$redacted"; then
  fail "config show leaked MYSQL_ROOT_PASSWORD"
fi
assert_contains "$redacted" "***REDACTED***"
pass "config show redacts effective secrets by default"

bundle_dir="$(mktemp -d)"
bundle="$bundle_dir/bundle.zip"
"$ROOT/lds" support bundle --redact "$bundle" >/dev/null
python3 - "$bundle" "supersecret-ci-value" <<'PY'
import sys, zipfile
path, secret = sys.argv[1:]
with zipfile.ZipFile(path) as z:
    for name in z.namelist():
        data = z.read(name)
        if secret.encode() in data:
            raise SystemExit(f"support bundle leaked secret in {name}")
PY
rm -rf "$bundle_dir"
pass "support bundle redacts interpolated secrets"

default_bundle_dir="$(mktemp -d)"
(
  cd "$default_bundle_dir"
  "$ROOT/lds" support bundle --redact >/dev/null
)
default_bundle="$(find "$default_bundle_dir" -maxdepth 1 -type f -name 'lds_bundle_*.zip' -print -quit)"
[[ -n "$default_bundle" ]] || fail "support bundle option-only invocation did not create a default zip"
rm -rf "$default_bundle_dir"
pass "support bundle option-only invocation uses a generated filename"

relative_bundle_dir="$(mktemp -d)"
(
  cd "$relative_bundle_dir"
  "$ROOT/lds" support bundle --redact relative-support.zip >/dev/null
  [[ -s relative-support.zip ]] || fail "relative support bundle path was lost with staging cleanup"
)
rm -rf "$relative_bundle_dir"
pass "support bundle preserves explicit relative output paths"

help="$("$ROOT/lds" help)"
assert_contains "$help" "doctor"
assert_contains "$help" "images"
assert_contains "$help" "urls"
assert_contains "$help" "support trace"
assert_contains "$help" "--global"
pass "QoL commands are discoverable"

assert_file_contains "$ROOT/lds" 'images | urls | doctor)'
assert_file_contains "$ROOT/lib/diagnostics.sh" 'Docker daemon is unavailable.'
pass "doctor owns Docker availability diagnostics"

assert_file_contains "$ROOT/lds" 'trace) cmd_support_trace "$@" ;;'
assert_file_contains "$ROOT/lib/services.sh" '/etc/share/vhosts/nginx/*.conf'
if grep -Fq '$DIR/configuration/nginx/' "$ROOT/lib/services.sh" "$ROOT/lib/diagnostics.sh"; then
  fail "domain inspection must use persisted named-volume vhosts"
fi
assert_file_contains "$ROOT/lib/services.sh" 'docker_compose restart "${services[@]}"'
assert_file_contains "$ROOT/lib/services.sh" '--global'
assert_file_contains "$ROOT/lib/services.sh" 'label=com.docker.compose.project=$project'
pass "trace, domain listing, targeted restart, and scoped cleanup contracts"
