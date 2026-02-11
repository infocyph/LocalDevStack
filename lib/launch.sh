# lds lib: launch
# shellcheck shell=bash
# Requires lib/docker_exec.sh

conf_node_container() {
  local f="$1"

  # Nginx node vhost: proxy_pass http://node_<token>:<port>;
  local host token ctr

  host="$(
    grep -m1 -Eo 'proxy_pass[[:space:]]+http://[^;]+' "$f" 2>/dev/null |
      awk '{print $2}' |
      sed 's|^http://||' |
      awk -F: '{print $1}'
  )"

  [[ -n "${host:-}" ]] || return 0
  [[ "$host" == node_* ]] || return 0

  token="${host#node_}"
  ctr="NODE_${token^^}"

  docker inspect "$ctr" >/dev/null 2>&1 || return 0
  printf '%s' "$ctr"
}

core_pick_domain() {
  local -a domains=()
  local f d

  shopt -s nullglob
  for f in "$DIR/configuration/nginx/"*.conf; do
    d="$(basename -- "$f" .conf)"
    [[ -n "$d" ]] && domains+=("$d")
  done
  shopt -u nullglob

  ((${#domains[@]} > 0)) || die "No domains found in $DIR/configuration/nginx"

  # stable ordering
  IFS=$'\n' domains=($(printf '%s\n' "${domains[@]}" | LC_ALL=C sort -u))

  # If there's only one domain, just use it.
  if ((${#domains[@]} == 1)); then
    printf '%s' "${domains[0]}"
    return 0
  fi

  # Must be interactive to pick.
  if [[ ! -t 0 ]]; then
    printf "%b[core]%b No domain provided. Available domains:\n" "$YELLOW" "$NC" >&2
    local i=1
    for d in "${domains[@]}"; do
      printf "  %2d) %s\n" "$i" "$d" >&2
      ((i++))
    done
    die "No TTY to prompt. Use: lds core <domain>"
  fi

  printf "%bSelect domain:%b\n" "$CYAN" "$NC" >&2
  local i=1
  for d in "${domains[@]}"; do
    printf "  %2d) %s\n" "$i" "$d" >&2
    ((i++))
  done
  printf "  %2d) %s\n" 0 "Cancel" >&2

  local ans idx
  while true; do
    printf "%bDomain #%b " "$GREEN" "$NC" >&2
    tty_readline ans "" || return 130
    ans="${ans//[[:space:]]/}"
    [[ -n "$ans" ]] || continue

    if [[ "$ans" == "0" ]]; then
      return 130
    fi

    if [[ "$ans" =~ ^[0-9]+$ ]]; then
      idx=$((ans - 1))
      if ((idx >= 0 && idx < ${#domains[@]})); then
        printf '%s' "${domains[$idx]}"
        return 0
      fi
    else
      # allow typing domain directly
      for d in "${domains[@]}"; do
        if [[ "$d" == "$ans" ]]; then
          printf '%s' "$d"
          return 0
        fi
      done
    fi

    printf "%bInvalid selection.%b\n" "$YELLOW" "$NC" >&2
  done
}

launch_php() {
  local domain=$1 suffix
  local nconf="$DIR/configuration/nginx/$domain.conf"
  local aconf="$DIR/configuration/apache/$domain.conf"
  [[ -f $nconf ]] || die "No Nginx config for $domain"

  local docroot php
  if grep -q fastcgi_pass "$nconf"; then
    php=$(grep -Eo 'fastcgi_pass ([^:]+):9000' "$nconf" | awk '{print $2}' | sed 's/:9000$//')
    docroot=$(grep -m1 -Eo 'root [^;]+' "$nconf" | awk '{print $2}')
  else
    [[ -f $aconf ]] || die "No Apache config for $domain"
    docroot=$(grep -m1 -Eo 'DocumentRoot [^ ]+' "$aconf" | awk '{print $2}')
    php=$(grep -Eo 'proxy:fcgi://([^:]+):9000' "$aconf" | sed 's/.*:\/\/\([^:]*\):.*/\1/')
  fi

  [[ $php ]] || die "Could not detect PHP container for $domain"
  [[ $docroot ]] || docroot=/app
  for suffix in public dist public_html; do
    [[ $docroot == */$suffix ]] && {
      docroot=${docroot%/*}
      break
    }
  done

  php=$(echo "$php" | tr ' \n' '\n' | awk 'NF && !seen[$0]++' | paste -sd' ' -)
  docker exec -it "$php" bash --login -c "cd '$docroot' && exec bash"
}

launch_node() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || die "Usage: lds core <domain>"

  local nconf="$DIR/configuration/nginx/$domain.conf"
  [[ -f "$nconf" ]] || die "No Nginx config for $domain"

  # Expect: proxy_pass http://node_<token>:<port>;
  local upstream host token ctr
  upstream="$(
    grep -m1 -Eo 'proxy_pass[[:space:]]+http://[^;]+' "$nconf" 2>/dev/null |
      awk '{print $2}' |
      sed 's|^http://||'
  )"

  [[ -n "${upstream:-}" ]] || die "Could not detect node upstream for $domain"
  host="${upstream%%:*}" # node_resume_sparkle_localhost

  [[ -n "${host:-}" ]] || die "Could not parse upstream host for $domain"

  # Standard mapping: node_<token> -> NODE_<TOKEN>
  ctr=""
  if docker inspect "$host" >/dev/null 2>&1; then
    ctr="$host"
  elif [[ "$host" == node_* ]]; then
    token="${host#node_}"
    ctr="NODE_${token^^}"
    docker inspect "$ctr" >/dev/null 2>&1 || ctr=""
  fi

  [[ -n "${ctr:-}" ]] || die "Node container not found for upstream '$host' (domain: $domain)"
  docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null | grep -qx true || die "Container not running: $ctr"

  docker exec -it "$ctr" sh -lc '
    cd /app 2>/dev/null || cd / || true
    if command -v bash >/dev/null 2>&1; then exec bash --login; fi
    exec sh
  '
}

