#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin" "$tmp/Input Images" "$tmp/Output Images"
log="$tmp/docker.log"
: >"$log"

cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_CONVERT_TEST_LOG:?}"
printf '%s\n' '---' >>"$IMAGE_CONVERT_TEST_LOG"
for arg in "$@"; do
  printf '<%s>\n' "$arg" >>"$IMAGE_CONVERT_TEST_LOG"
done

case " $* " in
  *" -list format "*)
    printf '%s\n' '     JPEG* rw-   Joint Photographic Experts Group JFIF format' '      PNG* rw-   Portable Network Graphics' '      GIF* rw+   CompuServe graphics interchange format' '     WEBP* rw+   WebP Image Format'
    exit 0
    ;;
  *" -version "*)
    printf '%s\n' 'Version: ImageMagick 7.test'
    exit 0
    ;;
esac

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
done
if ((${#args[@]} > 0)); then
  target="${args[$((${#args[@]} - 1))]}"
  [[ "$target" == /lds-output/* ]] && out_name="${target#/lds-output/}"
fi
if [[ -n "$out_host" && -n "$out_name" ]]; then
  mkdir -p -- "$(dirname -- "$out_host/$out_name")"
  printf '%s\n' 'converted-image' >"$out_host/$out_name"
fi
SH
chmod +x "$bin/docker"

input="$tmp/Input Images/Photo File.png"
output="$tmp/Output Images/Photo File.webp"
printf 'png' >"$input"

IMAGE_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
  "$ROOT/lds" convert image "$input" "$output" -- -quality 82 -strip
[[ -f "$output" ]] || fail "lds convert image did not publish the host output file"
grep -Fq "<$tmp/Input Images:/lds-input:ro>" "$log" ||
  fail "image conversion did not mount input read-only"
grep -Fq "<$tmp/Output Images:/lds-output>" "$log" ||
  fail "image conversion did not mount output writable"
grep -Fq '<--entrypoint>' "$log" || fail "image conversion did not set entrypoint"
grep -Fq '<magick>' "$log" || fail "image conversion did not invoke ImageMagick"
grep -Fq '<--network>' "$log" || fail "image conversion did not disable networking"
grep -Fq '<none>' "$log" || fail "image conversion did not use network none"
grep -Fq '<--user>' "$log" || fail "image conversion did not preserve host output ownership"
grep -Fq '</lds-input/Photo File.png>' "$log" || fail "image input with spaces was not preserved"
grep -Fq '<-quality>' "$log" || fail "ImageMagick quality option was lost"
grep -Fq '<82>' "$log" || fail "ImageMagick quality value was lost"
grep -Fq '<-strip>' "$log" || fail "ImageMagick strip option was lost"
grep -Fq '</lds-output/Photo File.webp>' "$log" || fail "image output with spaces was not preserved"
if grep -Fq '/var/run/docker.sock' "$log"; then fail "image conversion exposed Docker socket"; fi
pass "containerized host image conversion"

gif="$tmp/Input Images/Animation.gif"
jpg="$tmp/Output Images/Preview.jpg"
webp="$tmp/Output Images/Animation.webp"
printf 'gif' >"$gif"
: >"$log"
IMAGE_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
  "$ROOT/lds" convert image "$gif" "$jpg"
grep -Fq '</lds-input/Animation.gif[0]>' "$log" ||
  fail "static image output did not select first animation frame"
IMAGE_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
  "$ROOT/lds" convert image "$gif" "$webp"
if grep -Fq '</lds-input/Animation.gif[0]>' "$log"; then
  fail "animation-capable WebP output incorrectly discarded animation frames"
fi
grep -Fq '</lds-input/Animation.gif>' "$log" || fail "animated WebP input path missing"
pass "static and animated image output semantics"

formats="$(IMAGE_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" "$ROOT/lds" convert image --formats)"
grep -q 'JPEG' <<<"$formats" || fail "JPEG capability discovery missing"
grep -q 'PNG' <<<"$formats" || fail "PNG capability discovery missing"
grep -q 'GIF' <<<"$formats" || fail "GIF capability discovery missing"
grep -q 'WEBP' <<<"$formats" || fail "WebP capability discovery missing"
version="$(IMAGE_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" "$ROOT/lds" convert image --version)"
grep -q 'ImageMagick' <<<"$version" || fail "ImageMagick version discovery failed"
pass "image conversion capability discovery"

before="$(wc -l <"$log" | tr -d '[:space:]')"
set +e
IMAGE_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
  "$ROOT/lds" convert image --force "$input" "$output" -- -write extra.png >/dev/null 2>"$tmp/write.err"
rc=$?
set -e
after="$(wc -l <"$log" | tr -d '[:space:]')"
[[ "$rc" -eq 64 ]] || fail "ImageMagick -write returned $rc instead of 64"
[[ "$before" == "$after" ]] || fail "ImageMagick -write reached Docker"
grep -Fq 'owns ImageMagick output selection' "$tmp/write.err" || fail "ImageMagick -write diagnostic missing"
pass "image conversion owns output path"
