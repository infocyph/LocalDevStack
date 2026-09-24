#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin" "$tmp/Input Docs" "$tmp/Output Docs"
log="$tmp/docker.log"
: >"$log"

cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${DOCUMENT_CONVERT_TEST_LOG:?}"
printf '%s\n' '---' >>"$DOCUMENT_CONVERT_TEST_LOG"
for arg in "$@"; do
  printf '<%s>\n' "$arg" >>"$DOCUMENT_CONVERT_TEST_LOG"
done

out_host=''
out_name=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "-v" && $((i + 1)) -lt ${#args[@]} ]]; then
    mount="${args[$((i + 1))]}"
    if [[ "$mount" == *":/lds-output" ]]; then
      out_host="${mount%:/lds-output}"
    fi
  fi
  if [[ "${args[$i]}" == "-o" && $((i + 1)) -lt ${#args[@]} ]]; then
    target="${args[$((i + 1))]}"
    out_name="${target#/lds-output/}"
  fi
done

case " $* " in
  *" --list-input-formats "*)
    printf '%s\n' markdown rst html docx epub
    exit 0
    ;;
  *" --list-output-formats "*)
    printf '%s\n' html5 markdown docx epub
    exit 0
    ;;
  *" --version "*)
    printf '%s\n' 'pandoc 3.test'
    exit 0
    ;;
esac

if [[ -n "$out_host" && -n "$out_name" ]]; then
  mkdir -p -- "$(dirname -- "$out_host/$out_name")"
  printf '%s\n' 'converted' >"$out_host/$out_name"
fi
SH
chmod +x "$bin/docker"

input="$tmp/Input Docs/Guide File.md"
output="$tmp/Output Docs/Guide File.html"
printf '# Guide\n' >"$input"

DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH"   "$ROOT/lds" convert docs "$input" "$output" --toc --standalone

[[ -f "$output" ]] || fail "lds convert docs did not publish the host output file"
grep -Fq "<$tmp/Input Docs:/lds-input:ro>" "$log" ||
  fail "lds convert docs did not mount the input directory read-only"
grep -Fq "<$tmp/Output Docs:/lds-output>" "$log" ||
  fail "lds convert docs did not mount the output directory writable"
grep -Fq '<--entrypoint>' "$log" || fail "lds convert docs did not use an explicit Pandoc entrypoint"
grep -Fq '<pandoc>' "$log" || fail "lds convert docs did not invoke Pandoc"
grep -Fq '<--network>' "$log" || fail "lds convert docs did not disable container networking"
grep -Fq '<none>' "$log" || fail "lds convert docs did not use the none network"
grep -Fq '<--user>' "$log" || fail "lds convert docs did not preserve host output ownership"
grep -Fq '<--resource-path=/lds-input>' "$log" ||
  fail "lds convert docs did not preserve relative input resources"
grep -Fq '<./Guide File.md>' "$log" || fail "input filename with spaces was not preserved"
grep -Fq '</lds-output/Guide File.html>' "$log" || fail "output filename with spaces was not preserved"
grep -Fq '<--toc>' "$log" || fail "Pandoc option passthrough lost --toc"
grep -Fq '<--standalone>' "$log" || fail "Pandoc option passthrough lost --standalone"
if grep -Fq '/var/run/docker.sock' "$log"; then
  fail "lds convert docs must not expose the Docker socket"
fi
if grep -Fq '<compose>' "$log"; then
  fail "lds convert docs must not require a running Compose stack"
fi
pass "containerized host document conversion"

set +e
DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH"   "$ROOT/lds" convert docs "$input" "$output" >/dev/null 2>"$tmp/existing.err"
rc=$?
set -e
[[ "$rc" -eq 73 ]] || fail "existing output returned $rc instead of 73"
grep -Fq 'use --force to replace it' "$tmp/existing.err" ||
  fail "existing output refusal did not explain --force"

DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH"   "$ROOT/lds" convert docs --force "$input" "$output" --wrap=none
grep -Fq '<--wrap=none>' "$log" || fail "--force conversion lost Pandoc options"
pass "document conversion overwrite protection"

before="$(wc -l <"$log" | tr -d '[:space:]')"
set +e
DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH"   "$ROOT/lds" convert docs --force "$input" "$output" -- -oelsewhere.html >/dev/null 2>"$tmp/output-option.err"
rc=$?
set -e
after="$(wc -l <"$log" | tr -d '[:space:]')"
[[ "$rc" -eq 64 ]] || fail "conflicting Pandoc output option returned $rc instead of 64"
[[ "$before" == "$after" ]] || fail "conflicting output option reached Docker"
grep -Fq 'owns Pandoc output selection' "$tmp/output-option.err" ||
  fail "conflicting output option diagnostic missing"
ln -s "$input" "$tmp/Output Docs/input-link.md"
before="$(wc -l <"$log" | tr -d '[:space:]')"
set +e
DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
  "$ROOT/lds" convert docs --force "$input" "$tmp/Output Docs/input-link.md" >/dev/null 2>"$tmp/same.err"
rc=$?
set -e
after="$(wc -l <"$log" | tr -d '[:space:]')"
[[ "$rc" -eq 64 ]] || fail "input/output symlink collision returned $rc instead of 64"
[[ "$before" == "$after" ]] || fail "input/output symlink collision reached Docker"
grep -Fq 'Input and output must be different files' "$tmp/same.err" ||
  fail "input/output symlink collision diagnostic missing"
pass "document conversion blocks in-place and symlink overwrite"

formats="$(
  DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH"     "$ROOT/lds" convert docs --list-input-formats
)"
grep -qx 'markdown' <<<"$formats" || fail "input format discovery did not reach Pandoc"
version="$(
  DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH"     "$ROOT/lds" convert docs --version
)"
grep -q '^pandoc ' <<<"$version" || fail "Pandoc version discovery failed"
pass "document conversion capability discovery"

set +e
DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH"   "$ROOT/lds" convert docs "$tmp/missing.md" "$tmp/Output Docs/missing.html" >/dev/null 2>"$tmp/missing.err"
rc=$?
set -e
[[ "$rc" -eq 66 ]] || fail "missing input returned $rc instead of 66"

set +e
DOCUMENT_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH"   "$ROOT/lds" convert docs "$input" "$tmp/no-such-dir/output.html" >/dev/null 2>"$tmp/outdir.err"
rc=$?
set -e
[[ "$rc" -eq 66 ]] || fail "missing output directory returned $rc instead of 66"
pass "document conversion validates host paths"
