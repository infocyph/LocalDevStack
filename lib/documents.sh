# shellcheck shell=bash

_DOCUMENT_CONVERT_IMAGE="infocyph/tools:latest"

_convert_usage() {
  cat <<'EOF'
Usage:
  lds convert [--force] <input> <output> [--] [pandoc-options...]
  lds convert --list-input-formats
  lds convert --list-output-formats
  lds convert --version

Examples:
  lds convert README.md README.html
  lds convert docs/guide.rst guide.docx --toc
  lds convert report.docx report.md --wrap=none
  lds convert book.md book.epub --toc

The conversion runs in a short-lived Tools container; Pandoc is not required on
the host. Relative auxiliary files referenced by Pandoc should live under the
input file's directory. Existing output files require --force.
EOF
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

_convert_reject_output_option() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    -o|--output|--output=*)
      err "lds convert owns Pandoc output selection; use the second LDS path argument instead of $arg"
      return 64
      ;;
    esac
  done
}

_convert_run_pandoc() {
  local -a args=("$@")

  if [[ -n "${MSYSTEM:-}${CYGWIN:-}" ]]; then
    (
      export MSYS_NO_PATHCONV=1
      export MSYS2_ARG_CONV_EXCL='*'
      "$(bin_path docker)" run --rm --pull=missing --entrypoint pandoc "$_DOCUMENT_CONVERT_IMAGE" "${args[@]}"
    )
  else
    "$(bin_path docker)" run --rm --pull=missing --entrypoint pandoc "$_DOCUMENT_CONVERT_IMAGE" "${args[@]}"
  fi
}

cmd_convert() {
  local force=0 input='' output='' input_abs output_abs
  local input_dir output_dir input_name output_name input_mount output_mount
  local -a pandoc_args=()

  case "${1:-}" in
  ""|-h|--help|help)
    _convert_usage
    return 0
    ;;
  --version|--list-input-formats|--list-output-formats)
    _convert_run_pandoc "$1"
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
    _convert_usage >&2
    return 64
  }
  shift 2

  [[ "${1:-}" != "--" ]] || shift
  pandoc_args=("$@")
  _convert_reject_output_option "${pandoc_args[@]}" || return $?

  input_abs="$(_convert_abs_existing_file "$input")" || {
    err "Input document not found or is not a regular file: $input"
    return 66
  }
  output_abs="$(_convert_abs_output "$output")" || {
    err "Output directory does not exist: $(dirname -- "$output")"
    return 66
  }

  [[ "$input_abs" != "$output_abs" ]] || {
    err "Input and output must be different files"
    return 64
  }
  if [[ -e "$output_abs" && "$force" -ne 1 ]]; then
    err "Output already exists: $output_abs (use --force to replace it)"
    return 73
  fi

  input_dir="$(dirname -- "$input_abs")"
  output_dir="$(dirname -- "$output_abs")"
  input_name="$(basename -- "$input_abs")"
  output_name="$(basename -- "$output_abs")"

  input_mount="$(_convert_docker_mount_path "$input_dir")" || {
    err "Unable to resolve input directory for Docker: $input_dir"
    return 66
  }
  output_mount="$(_convert_docker_mount_path "$output_dir")" || {
    err "Unable to resolve output directory for Docker: $output_dir"
    return 66
  }

  local -a docker_args=(
    -v "$input_mount:/lds-input:ro"
    -v "$output_mount:/lds-output"
    -w /lds-input
    --resource-path=/lds-input
    "./$input_name"
    -o "/lds-output/$output_name"
  )
  docker_args+=("${pandoc_args[@]}")

  _convert_run_pandoc "${docker_args[@]}"
}
