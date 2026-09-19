# shellcheck shell=bash
###############################################################################
# RUN (ad-hoc Dockerfile runner)
###############################################################################
hash_short() {
  local s="$1"
  if has_cmd sha1sum; then
    printf '%s' "$s" | sha1sum | cut -c1-8
  elif has_cmd shasum; then
    printf '%s' "$s" | shasum -a 1 | cut -c1-8
  else
    # POSIX fallback; stable (not cryptographic)
    printf '%s' "$s" | cksum | awk '{print $1}'
  fi
}

run_slug() {
  local dir="$1" base hash
  base="$(basename "$dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
  hash="$(hash_short "$dir")"
  printf '%s-%s' "$base" "$hash"
}

run_plan() {
  local dir="$1" slug
  slug="$(run_slug "$dir")"
  printf '%s|%s|%s\n' \
    "lds-run-${slug}" \
    "${slug}:local" \
    "$dir"
}

detect_host_os() {
  if is_windows_shell || grep -qi microsoft /proc/version 2>/dev/null; then
    printf 'windows'
    return 0
  fi

  if has_cmd uname; then
    case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      printf 'macos'
      ;;
    Linux)
      printf 'linux'
      ;;
    *)
      printf 'unknown'
      ;;
    esac
  else
    printf 'unknown'
  fi
}

run_find_container() {
  local dir="$1"
  docker ps -a --filter "label=com.infocyph.lds.run=1" \
    --filter "label=com.infocyph.lds.dir=${dir}" \
    --format '{{.Names}}' | head -n 1
}

run_build() {
  local tag="$1" dir="$2"

  # Build only if the image doesn't already exist.
  if docker image inspect "$tag" >/dev/null 2>&1; then
    printf "%b[run]%b Image exists, skipping build: %b%s%b
" "$CYAN" "$NC" "$BLUE" "$tag" "$NC"
    return 0
  fi

  printf "%b[run]%b Building image %b%s%b from %s
" "$CYAN" "$NC" "$BLUE" "$tag" "$NC" "$dir"
  docker build -t "$tag" "$dir"
}

run_start() {
  local name="$1" tag="$2" dir="$3" keepalive="$4" sock="$5" host_os="$6"
  shift 6 || true

  # Remaining args are split by a "--" sentinel:
  #   - before "--" : publish specs (HOST:CONT), repeatable
  #   - after "--"  : mount specs (HOST[:CONT]), repeatable
  local -a pubs=() mounts=()
  local seen_delim=0 x
  for x in "$@"; do
    if [[ "$x" == "--" ]]; then
      seen_delim=1
      continue
    fi
    if ((seen_delim)); then
      mounts+=("$x")
    else
      pubs+=("$x")
    fi
  done

  # Normalize project dir (POSIX absolute).
  # On Windows Git Bash, /e/... is OK; docker.exe will receive converted path automatically.
  local dir_posix
  dir_posix="$(cd "$dir" 2>/dev/null && pwd -P)" || die "invalid dir: $dir"

  # MSYS-safe container paths: use '//' prefix to prevent path conversion.
  # Docker interprets //path as /path inside container.
  local WDIR="//workspace"
  local WDIR_MOUNT="${dir_posix}://workspace"

  local -a args=(docker run -d --name "$name"
    --label "com.infocyph.lds.run=1"
    --label "com.infocyph.lds.dir=$dir_posix"
    --label "com.infocyph.lds.tag=$tag"
    -w "$WDIR"
    -v "$WDIR_MOUNT"
  )

  if [[ -n "$host_os" ]]; then
    args+=(-e "HOST_OS=$host_os")
  fi

  # Mount extra directories/files (HOST[:CONT]).
  # - If container path missing, mounts under /mnt/<basename>.
  # - HOST may be relative to the run directory.
  if ((${#mounts[@]})); then
    local spec host cont base
    for spec in "${mounts[@]}"; do
      [[ -n "$spec" ]] || continue
      host="$spec"
      cont=""

      # Split as HOST:CONT ONLY if suffix after last ':' looks like a container absolute path (/...)
      # (safe for Windows drive letters like E:\... because tail won't start with '/')
      if [[ "$spec" == *:* ]]; then
        local tail="${spec##*:}"
        if [[ "$tail" == /* ]]; then
          host="${spec%:*}"
          cont="$tail"
        fi
      fi

      # Resolve host to absolute (POSIX) for checks
      if [[ "$host" != /* && "$host" != ~* && ! "$host" =~ ^[A-Za-z]:[\\/].* ]]; then
        host="${dir_posix%/}/$host"
      fi

      # If user provided Windows path (E:\...), convert to POSIX for existence check
      if [[ "$host" =~ ^[A-Za-z]:[\\/].* ]] && has_cmd cygpath; then
        host="$(cygpath -u "$host")"
      fi

      host="$(cd "${host%/*}" 2>/dev/null && pwd -P)/${host##*/}" || {
        printf "%b[run]%b Warning: cannot resolve mount path: %s\n" "$YELLOW" "$NC" "$spec" >&2
        continue
      }

      [[ -e "$host" ]] || {
        printf "%b[run]%b Warning: mount path does not exist: %s\n" "$YELLOW" "$NC" "$host" >&2
        continue
      }

      if [[ -z "$cont" ]]; then
        base="${host##*/}"
        cont="/mnt/${base}"
      fi
      [[ "$cont" == /* ]] || cont="/mnt/${cont}"

      # Prevent MSYS conversion for container side by using '//' prefix
      cont="//${cont#/}"

      args+=(-v "${host}:${cont}")
    done
  fi

  # Optional docker sock
  if [[ "${sock:-0}" == 1 ]]; then
    args+=(-v "/var/run/docker.sock:/var/run/docker.sock")
  fi

  # Publish ports
  local pub
  for pub in "${pubs[@]}"; do
    [[ -n "$pub" ]] || continue
    args+=(-p "$pub")
  done

  if [[ "$keepalive" == 1 ]]; then
    # Keepalive mode replaces the image command; disable image healthcheck to avoid false "unhealthy".
    args+=(--no-healthcheck --entrypoint sh "$tag" -c "trap : TERM INT; sleep infinity & wait")
  else
    args+=("$tag")
  fi

  printf "%b[run]%b Starting container %b%s%b\n" "$CYAN" "$NC" "$BLUE" "$name" "$NC"

  # IMPORTANT: don't hide errors; if it fails, you need to see why
  if ! "${args[@]}"; then
    printf "%b[run]%b docker run failed.\n" "$RED" "$NC" >&2
    return 1
  fi
  printf "\n"
}

run_exec_shell() {
  local name="$1"
  if docker exec "$name" sh -lc 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
    exec docker exec -it "$name" bash
  else
    exec docker exec -it "$name" sh
  fi
}

cmd_run() {
  local action="*" dir="$PWD" name="" tag="" nobuild=0 keepalive=1 sock=0 host_os=""
  local -a publish=() mounts=()
  local open_port="" open_path="/" open_proto="http"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    stop | rm | ps | shell | logs | open | "*")
      action="$1"
      shift
      ;;
    build)
      action="*"
      shift
      ;;
    --name)
      name="${2:-}"
      shift 2
      ;;
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --no-build)
      nobuild=1
      shift
      ;;
    --no-keepalive)
      keepalive=0
      shift
      ;;
    --sock)
      sock=1
      shift
      ;;
    --host-os)
      host_os="${2:-}"
      shift 2
      ;;
    -p | --publish)
      publish+=("${2:-}")
      shift 2
      ;;
    --mount)
      mounts+=("${2:-}")
      shift 2
      ;;
    --port)
      open_port="${2:-}"
      shift 2
      ;;
    --path)
      open_path="${2:-/}"
      shift 2
      ;;
    --https)
      open_proto="https"
      shift
      ;;
    --http)
      open_proto="http"
      shift
      ;;
    *) break ;;
    esac
  done

  # Host path (POSIX) for planning/labels
  local dir_posix
  dir_posix="$(cd "$dir" && pwd -P)"

  if [[ -z "$host_os" ]]; then
    host_os="${HOST_OS:-$(detect_host_os)}"
  fi

  # Docker path (may need Windows form for docker.exe)
  local dir_docker="$dir_posix"

  # Windows Git Bash/MSYS hardening:
  # - stop MSYS rewriting container paths (/workspace -> D:/Program Files/Git/workspace)
  # - but still feed docker.exe Windows-absolute host paths for build/run contexts
  if is_windows_shell; then
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    if has_cmd cygpath; then
      dir_docker="$(cygpath -w "$dir_posix")"
    fi
  fi

  # Plan/name/tag should be based on the real project identity (POSIX dir)
  IFS='|' read -r def_name def_tag _def_dir < <(run_plan "$dir_posix")
  name="${name:-$def_name}"

  # Tag rules:
  # - Default tag is ":local" (from run_plan)
  # - If user passes --tag without ":", append ":local"
  if [[ -n "${tag:-}" ]]; then
    if [[ "$tag" != *:* ]]; then
      tag="${tag}:local"
    fi
  else
    tag="$def_tag"
  fi

  _find_for_dir() {
    local found
    found="$(run_find_container "$dir_posix" || true)"
    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return 0
    fi
    if docker inspect "$name" >/dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
    return 1
  }

  _run_build_summary() {
    local img="$1" build_dir="$2" cname="$3"
    local tag_only="${img##*:}"

    printf "\n%b[run]%b Build summary\n" "$CYAN" "$NC"
    printf "  %bImage:%b     %s\n" "$BOLD" "$NC" "$img"
    printf "  %bTag:%b       %s\n" "$BOLD" "$NC" "$tag_only"
    printf "  %bDir:%b       %s\n" "$BOLD" "$NC" "$build_dir"
    printf "  %bName:%b      %s\n" "$BOLD" "$NC" "$cname"
    printf "  %bKeepalive:%b %s\n" "$BOLD" "$NC" "$keepalive"
    printf "  %bSock:%b      %s\n" "$BOLD" "$NC" "$sock"
    printf "  %bHost OS:%b   %s\n" "$BOLD" "$NC" "$host_os"

    if ((${#publish[@]})); then
      printf "  %bPublish:%b   %s\n" "$BOLD" "$NC" "${publish[*]}"
    else
      printf "  %bPublish:%b   (none)\n" "$BOLD" "$NC"
    fi

    if ((${#mounts[@]})); then
      printf "  %bMounts:%b    %s\n" "$BOLD" "$NC" "${mounts[*]}"
    else
      printf "  %bMounts:%b    (none)\n" "$BOLD" "$NC"
    fi
    printf "\n"
  }

  _run_runtime_summary() {
    local cname="$1"
    local id img state ports
    id="$(docker inspect -f '{{.Id}}' "$cname" 2>/dev/null | cut -c1-12 || true)"
    img="$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || true)"
    state="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || true)"
    ports="$(docker port "$cname" 2>/dev/null | sed '/^[[:space:]]*$/d' | tr '\n' '; ' | sed 's/; $//' || true)"

    printf "%b[run]%b Runtime summary\n" "$CYAN" "$NC"
    printf "  %bContainer:%b %s\n" "$BOLD" "$NC" "${cname}${id:+ ($id)}"
    [[ -n "$img" ]] && printf "  %bImage:%b     %s\n" "$BOLD" "$NC" "$img"
    [[ -n "$state" ]] && printf "  %bState:%b     %s\n" "$BOLD" "$NC" "$state"
    if [[ -n "$ports" ]]; then
      printf "  %bPorts:%b     %s\n" "$BOLD" "$NC" "$ports"
    else
      printf "  %bPorts:%b     (none published)\n" "$BOLD" "$NC"
    fi
    printf "%b\n[run]%b Example Usage (in Composer)\n" "$CYAN" "$NC"
    printf "  %bimage:%b %s\n" "$BOLD" "$NC" "$img"
    printf "  %bpull_policy:%b never\n" "$BOLD" "$NC"
    printf "\n"
  }

  case "$action" in
  ps)
    docker ps -a --filter "label=com.infocyph.lds.run=1" \
      --format 'table {{.Names}}	{{.Image}}	{{.Status}}	{{.Labels}}'
    return 0
    ;;
  stop)
    local existing
    existing="$(_find_for_dir)" || die "no run container found for: $dir_posix"
    docker stop "$existing" >/dev/null
    printf "%b[run]%b Stopped %s\n" "$GREEN" "$NC" "$existing"
    return 0
    ;;
  logs)
    local existing
    existing="$(_find_for_dir)" || die "no run container found for: $dir_posix"
    exec docker logs -f "$existing"
    ;;
  open)
    local existing line addr hp url
    existing="$(_find_for_dir)" || die "no run container found for: $dir_posix"

    [[ -n "$open_path" ]] || open_path="/"
    [[ "$open_path" == /* ]] || open_path="/$open_path"

    if [[ -n "$open_port" ]]; then
      line="$(docker port "$existing" "$open_port" 2>/dev/null | head -n 1 || true)"
      [[ -n "$line" ]] || line="$(docker port "$existing" "${open_port}/tcp" 2>/dev/null | head -n 1 || true)"
    else
      line="$(docker port "$existing" 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -z "$line" ]]; then
      printf "%b[run]%b No published ports found.\n" "$YELLOW" "$NC"
      printf "%b[run]%b Tip: start with %blds run --publish 8025:8025%b then %blds run open%b\n" \
        "$YELLOW" "$NC" "$BLUE" "$NC" "$BLUE" "$NC"
      return 1
    fi

    addr="${line##*-> }"
    hp="${addr##*:}"
    url="${open_proto}://localhost:${hp}${open_path}"
    open_url "$url"
    printf "%b[run]%b Opened: %s\n" "$GREEN" "$NC" "$url"
    return 0
    ;;
  rm)
    local existing img
    existing="$(_find_for_dir)" || true
    if [[ -n "${existing:-}" ]]; then
      img="$(docker inspect -f '{{.Config.Image}}' "$existing" 2>/dev/null || true)"
      docker stop "$existing" >/dev/null 2>&1 || true
      docker rm "$existing" >/dev/null 2>&1 || true
      printf "%b[run]%b Removed container %s\n" "$GREEN" "$NC" "$existing"
      if [[ -n "${img:-}" ]]; then
        docker rmi -f "$img" >/dev/null 2>&1 || true
        printf "%b[run]%b Removed image %s\n" "$GREEN" "$NC" "$img"
      fi
    else
      printf "%b[run]%b No container found for %s\n" "$YELLOW" "$NC" "$dir_posix"
    fi
    return 0
    ;;
  shell | "*")
    if ((nobuild == 0)); then
      # Build needs docker.exe-friendly path on Windows
      run_build "$tag" "$dir_docker"
    else
      printf "%b[run]%b Skipping build (--no-build)\n" "$YELLOW" "$NC"
    fi

    _run_build_summary "$tag" "$dir_posix" "$name"

    if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
      printf "%b[run]%b Container already running: %s\n\n" "$GREEN" "$NC" "$name"
    else
      if docker inspect "$name" >/dev/null 2>&1; then
        docker rm -f "$name" >/dev/null 2>&1 || true
      fi

      # Keep mounts as user gave them (POSIX/relative); run_start should validate POSIX
      # and convert host-side to Windows only at docker run time.
      run_start "$name" "$tag" "$dir_docker" "$keepalive" "$sock" "$host_os" \
        "${publish[@]}" -- "${mounts[@]}"
    fi

    _run_runtime_summary "$name"

    # "shell" enters the container; "*" / "build" does not.
    if [[ "$action" == "shell" ]]; then
      run_exec_shell "$name"
    else
      printf "%b[run]%b Built/started. Use %blds run shell%b to enter, %blds run logs%b to follow logs.\n" \
        "$GREEN" "$NC" "$BLUE" "$NC" "$BLUE" "$NC"
      return 0
    fi
    ;;
  esac
}

