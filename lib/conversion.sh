# shellcheck shell=bash

_CONVERT_TOOLS_IMAGE="infocyph/tools:latest"
_CONVERT_INPUT_ABS=''
_CONVERT_OUTPUT_ABS=''
_CONVERT_INPUT_DIR=''
_CONVERT_OUTPUT_DIR=''
_CONVERT_INPUT_NAME=''
_CONVERT_OUTPUT_NAME=''
_CONVERT_INPUT_MOUNT=''
_CONVERT_OUTPUT_MOUNT=''

_convert_usage() {
  cat <<'EOF'
Usage:
  lds convert docs [--force] <input> <output> [--] [pandoc-options...]
  lds convert docs --list-input-formats|--list-output-formats|--version
  lds convert image [--force] <input> <output> [--] [imagemagick-options...]
  lds convert image --formats|--version
  lds convert audio [--force] <input> <output> [--] [ffmpeg-output-options...]
  lds convert audio --formats|--codecs|--encoders|--version
  lds convert video [--force] <input> <output> [--] [ffmpeg-output-options...]
  lds convert video --formats|--codecs|--encoders|--version

Examples:
  lds convert docs README.md README.html
  lds convert docs docs/guide.rst guide.docx --toc
  lds convert image photo.jpg photo.png
  lds convert image photo.png photo.webp -- -quality 82
  lds convert image animation.gif animation.webp
  lds convert audio recording.wav recording.mp3
  lds convert video recording.mov recording.mp4 -- -c:v libx264 -crf 23 -c:a aac
EOF
}

_convert_docs_usage() {
  cat <<'EOF'
Usage:
  lds convert docs [--force] <input> <output> [--] [pandoc-options...]
  lds convert docs --list-input-formats
  lds convert docs --list-output-formats
  lds convert docs --version
EOF
}

_convert_image_usage() {
  cat <<'EOF'
Usage:
  lds convert image [--force] <input> <output> [--] [imagemagick-options...]
  lds convert image --formats
  lds convert image --version

Examples:
  lds convert image photo.jpg photo.png
  lds convert image photo.png photo.webp -- -quality 82
  lds convert image animation.gif animation.webp
  lds convert image animation.gif preview.jpg

GIF/WebP output preserves animation when supported by ImageMagick. Static output
formats such as JPEG/PNG use the first frame of a multi-frame input by default.
EOF
}

_convert_media_usage() {
  local kind="${1:-media}"
  cat <<EOF
Usage:
  lds convert $kind [--force] <input> <output> [--] [ffmpeg-output-options...]
  lds convert $kind --formats
  lds convert $kind --codecs
  lds convert $kind --encoders
  lds convert $kind --version

Examples:
  lds convert audio recording.wav recording.mp3
  lds convert audio recording.wav recording.ogg -- -c:a libopus -b:a 128k
  lds convert video recording.mov recording.mp4
  lds convert video recording.mkv recording.webm -- -c:v libvpx-vp9 -crf 32 -b:v 0

The first-class media converter owns the single input, overwrite policy and one
output path. For multi-input, concat, capture, or advanced filtergraph workflows
use "lds tools ffmpeg ..." directly.
EOF
}

_convert_ffmpeg_capability() {
  local option="${1:-}"
  case "$option" in
  --version)
    _convert_engine ffmpeg -version
    ;;
  --formats)
    _convert_engine ffmpeg -hide_banner -formats
    ;;
  --codecs)
    _convert_engine ffmpeg -hide_banner -codecs
    ;;
  --encoders)
    _convert_engine ffmpeg -hide_banner -encoders
    ;;
  *)
    return 64
    ;;
  esac
}

_convert_reject_ffmpeg_owned_options() {
  local kind="${1:-media}"
  shift || true
  local arg
  for arg in "$@"; do
    case "$arg" in
    -i|-y|-n)
      err "lds convert $kind owns FFmpeg input/output and overwrite selection; option $arg is not allowed"
      return 64
      ;;
    esac
  done
}

_convert_media() {
  local kind="${1:-media}"
  shift || true
  local force=0 input='' output='' overwrite_flag=-n
  local -a args=() run_args=()

  case "${1:-}" in
  ''|-h|--help|help)
    _convert_media_usage "$kind"
    return 0
    ;;
  --version|--formats|--codecs|--encoders)
    _convert_ffmpeg_capability "$1"
    return $?
    ;;
  --force)
    force=1
    overwrite_flag=-y
    shift
    ;;
  esac

  input="${1:-}"
  output="${2:-}"
  [[ -n "$input" && -n "$output" ]] || {
    _convert_media_usage "$kind" >&2
    return 64
  }
  shift 2
  [[ "${1:-}" != '--' ]] || shift
  args=("$@")
  _convert_reject_ffmpeg_owned_options "$kind" "${args[@]}" || return $?
  _convert_prepare_paths "$input" "$output" "$force" || return $?

  run_args=(
    run --rm --pull=missing --network none
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp
    -v "$_CONVERT_INPUT_MOUNT:/lds-input:ro"
    -v "$_CONVERT_OUTPUT_MOUNT:/lds-output"
    --entrypoint ffmpeg
    "$_CONVERT_TOOLS_IMAGE"
    -hide_banner
    -nostdin
    "$overwrite_flag"
    -i "/lds-input/$_CONVERT_INPUT_NAME"
  )
  run_args+=("${args[@]}")
  run_args+=("/lds-output/$_CONVERT_OUTPUT_NAME")
  _convert_docker "${run_args[@]}"
}

_convert_host_fs_path() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1

  if [[ "$path" =~ ^[A-Za-z]:[\\/].* ]] && has_bin cygpath; then
    cygpath -u "$path"
    return $?
  fi

  printf '%s' "$path"
}

_convert_abs_existing_file() {
  local raw="${1:-}" path
  path="$(_convert_host_fs_path "$raw")" || return 1
  [[ -f "$path" ]] || return 1
  _realpath "$path"
}

_convert_abs_output() {
  local raw="${1:-}" path dir base abs_dir
  path="$(_convert_host_fs_path "$raw")" || return 1
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  [[ -d "$dir" ]] || return 1
  abs_dir="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$abs_dir" "$base"
}

_convert_docker_mount_path() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1

  if [[ -n "${MSYSTEM:-}${CYGWIN:-}" ]] && has_bin cygpath; then
    cygpath -w "$path"
    return $?
  fi

  printf '%s' "$path"
}

_convert_prepare_paths() {
  local input="${1:-}" output="${2:-}" force="${3:-0}" existing_output_abs

  _CONVERT_INPUT_ABS="$(_convert_abs_existing_file "$input")" || {
    err "Input file not found or is not a regular file: $input"
    return 66
  }
  _CONVERT_OUTPUT_ABS="$(_convert_abs_output "$output")" || {
    err "Output directory does not exist: $(dirname -- "$output")"
    return 66
  }

  [[ "$_CONVERT_INPUT_ABS" != "$_CONVERT_OUTPUT_ABS" ]] || {
    err "Input and output must be different files"
    return 64
  }
  if [[ -e "$_CONVERT_OUTPUT_ABS" ]]; then
    existing_output_abs="$(_realpath "$_CONVERT_OUTPUT_ABS" 2>/dev/null || true)"
    [[ -z "$existing_output_abs" || "$existing_output_abs" != "$_CONVERT_INPUT_ABS" ]] || {
      err "Input and output must be different files"
      return 64
    }
  fi
  if [[ -e "$_CONVERT_OUTPUT_ABS" && "$force" -ne 1 ]]; then
    err "Output already exists: $_CONVERT_OUTPUT_ABS (use --force to replace it)"
    return 73
  fi

  _CONVERT_INPUT_DIR="$(dirname -- "$_CONVERT_INPUT_ABS")"
  _CONVERT_OUTPUT_DIR="$(dirname -- "$_CONVERT_OUTPUT_ABS")"
  _CONVERT_INPUT_NAME="$(basename -- "$_CONVERT_INPUT_ABS")"
  _CONVERT_OUTPUT_NAME="$(basename -- "$_CONVERT_OUTPUT_ABS")"
  _CONVERT_INPUT_MOUNT="$(_convert_docker_mount_path "$_CONVERT_INPUT_DIR")" || return 66
  _CONVERT_OUTPUT_MOUNT="$(_convert_docker_mount_path "$_CONVERT_OUTPUT_DIR")" || return 66
}

_convert_docker() {
  if [[ -n "${MSYSTEM:-}${CYGWIN:-}" ]]; then
    (
      export MSYS_NO_PATHCONV=1
      export MSYS2_ARG_CONV_EXCL='*'
      "$(bin_path docker)" "$@"
    )
  else
    "$(bin_path docker)" "$@"
  fi
}

_convert_engine() {
  local entrypoint="${1:-}"
  shift || true
  [[ -n "$entrypoint" ]] || return 64
  _convert_docker run --rm --pull=missing --network none --entrypoint "$entrypoint" "$_CONVERT_TOOLS_IMAGE" "$@"
}

_convert_reject_pandoc_output_option() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    -o|-o?*|--output|--output=*)
      err "lds convert docs owns Pandoc output selection; use the LDS output path instead of $arg"
      return 64
      ;;
    esac
  done
}

_convert_reject_imagemagick_output_option() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    -write|+write)
      err "lds convert image owns ImageMagick output selection; additional -write outputs are not allowed"
      return 64
      ;;
    esac
  done
}

_convert_image_static_output() {
  local ext="${1##*.}"
  ext="${ext,,}"
  case "$ext" in
  jpg|jpeg|jpe|png|bmp|ico) return 0 ;;
  esac
  return 1
}

_convert_docs() {
  local force=0 input='' output=''
  local -a args=() run_args=()

  case "${1:-}" in
  ''|-h|--help|help)
    _convert_docs_usage
    return 0
    ;;
  --version|--list-input-formats|--list-output-formats)
    _convert_engine pandoc "$1"
    return $?
    ;;
  --force)
    force=1
    shift
    ;;
  esac

  input="${1:-}"
  output="${2:-}"
  [[ -n "$input" && -n "$output" ]] || {
    _convert_docs_usage >&2
    return 64
  }
  shift 2
  [[ "${1:-}" != '--' ]] || shift
  args=("$@")
  _convert_reject_pandoc_output_option "${args[@]}" || return $?
  _convert_prepare_paths "$input" "$output" "$force" || return $?

  run_args=(
    run --rm --pull=missing --network none
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp
    -v "$_CONVERT_INPUT_MOUNT:/lds-input:ro"
    -v "$_CONVERT_OUTPUT_MOUNT:/lds-output"
    -w /lds-input
    --entrypoint pandoc
    "$_CONVERT_TOOLS_IMAGE"
    --resource-path=/lds-input
    "./$_CONVERT_INPUT_NAME"
    -o "/lds-output/$_CONVERT_OUTPUT_NAME"
  )
  run_args+=("${args[@]}")
  _convert_docker "${run_args[@]}"
}

_convert_image() {
  local force=0 input='' output='' image_input
  local -a args=() run_args=()

  case "${1:-}" in
  ''|-h|--help|help)
    _convert_image_usage
    return 0
    ;;
  --version)
    _convert_engine magick -version
    return $?
    ;;
  --formats|--list-formats)
    _convert_engine magick -list format
    return $?
    ;;
  --force)
    force=1
    shift
    ;;
  esac

  input="${1:-}"
  output="${2:-}"
  [[ -n "$input" && -n "$output" ]] || {
    _convert_image_usage >&2
    return 64
  }
  shift 2
  [[ "${1:-}" != '--' ]] || shift
  args=("$@")
  _convert_reject_imagemagick_output_option "${args[@]}" || return $?
  _convert_prepare_paths "$input" "$output" "$force" || return $?

  image_input="/lds-input/$_CONVERT_INPUT_NAME"
  if _convert_image_static_output "$_CONVERT_OUTPUT_NAME"; then
    image_input+='[0]'
  fi

  run_args=(
    run --rm --pull=missing --network none
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp
    -v "$_CONVERT_INPUT_MOUNT:/lds-input:ro"
    -v "$_CONVERT_OUTPUT_MOUNT:/lds-output"
    --entrypoint magick
    "$_CONVERT_TOOLS_IMAGE"
    "$image_input"
  )
  run_args+=("${args[@]}")
  run_args+=("/lds-output/$_CONVERT_OUTPUT_NAME")
  _convert_docker "${run_args[@]}"
}

cmd_convert() {
  local kind="${1:-}"
  shift || true

  case "${kind,,}" in
  docs)
    _convert_docs "$@"
    ;;
  image)
    _convert_image "$@"
    ;;
  audio | video)
    _convert_media "${kind,,}" "$@"
    ;;
  ''|-h|--help|help)
    _convert_usage
    ;;
  *)
    err "Unknown conversion type: $kind (expected docs, image, audio, or video)"
    _convert_usage >&2
    return 64
    ;;
  esac
}
