# lds lib: docker
# shellcheck shell=bash
# Requires lib/bootstrap.sh

load_extras() {
  ((__EXTRAS_LOADED)) && return 0
  __EXTRAS_LOADED=1

  [[ -d "$EXTRAS_DIR" ]] || return 0

  # Stable ordering: later -f overrides earlier.
  mapfile -t __EXTRA_FILES < <(
    find "$EXTRAS_DIR" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort
  )
}

docker_compose() {
  load_extras

  local -a files=()
  if ((${#__EXTRA_FILES[@]})); then
    local f
    for f in "${__EXTRA_FILES[@]}"; do
      files+=(-f "$f")
    done
  fi

  # Prefer Docker Compose v2 ("docker compose"), fallback to v1 ("docker-compose")
  local -a dc=(docker compose)
  if ! docker compose version >/dev/null 2>&1; then
    dc=(docker-compose)
  fi

  "${dc[@]}" \
    --project-directory "$DIR" \
    -f "$COMPOSE_FILE" \
    "${files[@]}" \
    --env-file "$ENV_DOCKER" \
    "$@"
}

dc_up() {
  if ((VERBOSE)); then
    docker_compose up "$@"
  else
    docker_compose up --quiet-pull "$@"
  fi
}

dc_pull() {
  if ((VERBOSE)); then
    docker_compose pull "$@"
  else
    docker_compose pull -q "$@"
  fi
}

dc_build() {
  if ((VERBOSE)); then
    docker_compose build "$@"
  else
    docker_compose build --quiet "$@"
  fi
}

