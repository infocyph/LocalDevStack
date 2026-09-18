# shellcheck shell=bash
_shq() { printf '%q' "$1"; }

cmd_diag() {
  local sub="${1:-}"
  shift || true

  case "${sub,,}" in
  dns)
    local dom="${1:-}"
    [[ -n "$dom" ]] || die "diag dns <domain>"
    local qdom
    qdom="$(_shq "$dom")"
    _tools_exec "dig +short $qdom; echo; nslookup $qdom 2>/dev/null || true; echo; getent hosts $qdom 2>/dev/null || true"
    ;;
  route | net)
    _tools_exec "ip r; echo; ip a; echo; ss -tulpen 2>/dev/null || netstat -tulpen 2>/dev/null || true"
    ;;
  tcp)
    local h="${1:-}"
    local p="${2:-}"
    [[ -n "$h" && -n "$p" ]] || die "diag tcp <host> <port>"
    _tools_exec "nc -vz -w2 $(_shq "$h") $(_shq "$p")"
    ;;
  http)
    local url="${1:-}"
    shift || true
    [[ -n "$url" ]] || die "diag http <url> [curl-args...]"
    local -a qargs=()
    local a
    for a in "$@"; do qargs+=("$(printf '%q' "$a")"); done
    _tools_exec "curl -vkI $(_shq "$url") ${qargs[*]}"
    ;;
  tls)
    local dom="${1:-}"
    [[ -n "$dom" ]] || die "diag tls <domain>"
    local qdom
    qdom="$(_shq "$dom")"
    _tools_exec "echo | openssl s_client -connect ${qdom}:443 -servername $qdom -showcerts 2>/dev/null | sed -n '1,60p'"
    ;;
  *)
    die "diag <dns|route|net|tcp|http|tls>"
    ;;
  esac
}

cmd_sniff() {
  local url="${1:-}"
  shift || true
  [[ -n "$url" ]] || die "sniff <url> [curl-args...]"
  local -a qargs=()
  local a
  for a in "$@"; do qargs+=("$(printf '%q' "$a")"); done
  _tools_exec "curl -vk -D - $(_shq "$url") ${qargs[*]} | (command -v jq >/dev/null 2>&1 && jq . 2>/dev/null || cat)"
}

