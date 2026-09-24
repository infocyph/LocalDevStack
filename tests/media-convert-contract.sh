#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/assertions.sh
source "$ROOT/tests/lib/assertions.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin" "$tmp/Input Media" "$tmp/Output Media"
log="$tmp/docker.log"
: >"$log"

cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${MEDIA_CONVERT_TEST_LOG:?}"
printf '%s\n' '---' >>"$MEDIA_CONVERT_TEST_LOG"
for arg in "$@"; do
  printf '<%s>\n' "$arg" >>"$MEDIA_CONVERT_TEST_LOG"
done

case " $* " in
  *" -formats "*) printf '%s\n' ' D  matroska,webm' ' DE mp3' ; exit 0 ;;
  *" -codecs "*) printf '%s\n' ' DEV.L. h264' ' DEA.L. mp3' ; exit 0 ;;
  *" -encoders "*) printf '%s\n' ' V..... libx264' ' A..... libmp3lame' ; exit 0 ;;
  *" -version "*) printf '%s\n' 'ffmpeg version test' ; exit 0 ;;
esac

out_host=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "-v" && $((i + 1)) -lt ${#args[@]} ]]; then
    mount="${args[$((i + 1))]}"
    [[ "$mount" == *":/lds-output" ]] && out_host="${mount%:/lds-output}"
  fi
done
if ((${#args[@]} > 0)); then
  target="${args[$((${#args[@]} - 1))]}"
  if [[ "$target" == /lds-output/* && -n "$out_host" ]]; then
    out_name="${target#/lds-output/}"
    printf '%s\n' converted >"$out_host/$out_name"
  fi
fi
SH
chmod +x "$bin/docker"

audio_in="$tmp/Input Media/Source Audio.wav"
audio_out="$tmp/Output Media/Output Audio.mp3"
video_in="$tmp/Input Media/Source Video.mkv"
video_out="$tmp/Output Media/Output Video.mp4"
printf 'audio' >"$audio_in"
printf 'video' >"$video_in"

MEDIA_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
  "$ROOT/lds" convert audio "$audio_in" "$audio_out" -- -c:a libmp3lame -b:a 160k
[[ -f "$audio_out" ]] || fail "audio conversion did not publish output"
grep -Fq '<--network>' "$log" || fail "audio conversion did not disable networking"
grep -Fq '<none>' "$log" || fail "audio conversion did not use network none"
grep -Fq '<--user>' "$log" || fail "audio conversion did not preserve host ownership"
grep -Fq "<$tmp/Input Media:/lds-input:ro>" "$log" || fail "audio input mount was not read-only"
grep -Fq '<--entrypoint>' "$log" || fail "audio conversion did not set FFmpeg entrypoint"
grep -Fq '<ffmpeg>' "$log" || fail "audio conversion did not invoke FFmpeg"
grep -Fq '<-nostdin>' "$log" || fail "audio conversion did not disable FFmpeg interactive stdin"
grep -Fq '<-n>' "$log" || fail "audio conversion did not use no-overwrite mode"
grep -Fq '<-i>' "$log" || fail "audio conversion input marker missing"
grep -Fq '</lds-input/Source Audio.wav>' "$log" || fail "audio input path with spaces was lost"
grep -Fq '<-c:a>' "$log" || fail "audio codec option was lost"
grep -Fq '<libmp3lame>' "$log" || fail "audio codec value was lost"
grep -Fq '</lds-output/Output Audio.mp3>' "$log" || fail "audio output path with spaces was lost"
pass "FFmpeg audio conversion contract"

: >"$log"
MEDIA_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
  "$ROOT/lds" convert video "$video_in" "$video_out" -- -c:v libx264 -crf 23 -c:a aac
[[ -f "$video_out" ]] || fail "video conversion did not publish output"
grep -Fq '</lds-input/Source Video.mkv>' "$log" || fail "video input path missing"
grep -Fq '<-c:v>' "$log" || fail "video codec option missing"
grep -Fq '<libx264>' "$log" || fail "video codec value missing"
grep -Fq '<-crf>' "$log" || fail "video CRF option missing"
grep -Fq '</lds-output/Output Video.mp4>' "$log" || fail "video output path missing"
pass "FFmpeg video conversion contract"

: >"$log"
MEDIA_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
  "$ROOT/lds" convert audio --force "$audio_in" "$audio_out" -- -c:a copy
grep -Fq '<-y>' "$log" || fail "--force did not map to FFmpeg overwrite mode"
pass "media conversion overwrite policy"

for forbidden in -i -y -n; do
  before="$(wc -l <"$log" | tr -d '[:space:]')"
  set +e
  MEDIA_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" \
    "$ROOT/lds" convert video --force "$video_in" "$video_out" -- "$forbidden" extra >/dev/null 2>"$tmp/forbidden.err"
  rc=$?
  set -e
  after="$(wc -l <"$log" | tr -d '[:space:]')"
  [[ "$rc" -eq 64 ]] || fail "reserved FFmpeg option $forbidden returned $rc instead of 64"
  [[ "$before" == "$after" ]] || fail "reserved FFmpeg option $forbidden reached Docker"
done
grep -Fq 'owns FFmpeg input/output and overwrite selection' "$tmp/forbidden.err" ||
  fail "reserved FFmpeg option diagnostic missing"
pass "media converter owns FFmpeg input/output controls"

formats="$(MEDIA_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" "$ROOT/lds" convert video --formats)"
grep -q matroska <<<"$formats" || fail "FFmpeg format discovery failed"
codecs="$(MEDIA_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" "$ROOT/lds" convert audio --codecs)"
grep -q mp3 <<<"$codecs" || fail "FFmpeg codec discovery failed"
encoders="$(MEDIA_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" "$ROOT/lds" convert video --encoders)"
grep -q libx264 <<<"$encoders" || fail "FFmpeg encoder discovery failed"
version="$(MEDIA_CONVERT_TEST_LOG="$log" PATH="$bin:$PATH" "$ROOT/lds" convert audio --version)"
grep -q '^ffmpeg version' <<<"$version" || fail "FFmpeg version discovery failed"
pass "media conversion capability discovery"
