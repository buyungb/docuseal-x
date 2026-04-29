#!/usr/bin/env bash
# Local Docker deploy helper for DocuSeal.
#
# Usage:
#   ./deploy-local.sh up       # pull (if needed) and start the stack
#   ./deploy-local.sh down     # stop the stack
#   ./deploy-local.sh restart  # down + up
#   ./deploy-local.sh pull     # refresh the app image from registry
#   ./deploy-local.sh logs     # tail app logs
#   ./deploy-local.sh sh       # shell into the app container
#   ./deploy-local.sh psql     # open psql in the postgres container
#   ./deploy-local.sh status   # docker compose ps
#   ./deploy-local.sh rm       # force-remove the current containers (keeps volumes)
#   ./deploy-local.sh reset    # destroy containers + data volumes (DANGEROUS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.local.yml"
ENV_FILE=".env.local"
ENV_EXAMPLE=".env.local.example"
PROJECT_NAME="docuseal-local"

# Color helpers
if [ -t 1 ]; then
  C_BLUE="\033[1;34m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_YELLOW="\033[1;33m"; C_RESET="\033[0m"
else
  C_BLUE=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_RESET=""
fi

info()  { printf "${C_BLUE}==>${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}OK${C_RESET}  %s\n" "$*"; }
warn()  { printf "${C_YELLOW}!!${C_RESET}  %s\n" "$*"; }
die()   { printf "${C_RED}xx${C_RESET}  %s\n" "$*" >&2; exit 1; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
  docker info >/dev/null 2>&1 || die "docker daemon is not running"

  if docker compose version >/dev/null 2>&1; then
    DC=(docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE")
  elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE")
  else
    die "docker compose plugin not found"
  fi
}

ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$ENV_EXAMPLE" ]; then
      cp "$ENV_EXAMPLE" "$ENV_FILE"
      warn "Created $ENV_FILE from $ENV_EXAMPLE -- review it before running again"
    else
      die "Neither $ENV_FILE nor $ENV_EXAMPLE exists"
    fi
  fi

  if grep -qE '^SECRET_KEY_BASE=replace-me' "$ENV_FILE"; then
    info "Generating SECRET_KEY_BASE in $ENV_FILE"
    local secret
    secret="$(openssl rand -hex 64 2>/dev/null || ruby -rsecurerandom -e 'print SecureRandom.hex(64)')"
    if [ "$(uname -s)" = "Darwin" ]; then
      sed -i '' "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$secret|" "$ENV_FILE"
    else
      sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$secret|" "$ENV_FILE"
    fi
  fi
}

ensure_data_dirs() {
  # Named docker volumes are auto-created by compose; nothing to do here.
  :
}

cmd_build() {
  warn "This compose file uses a prebuilt image (\$APP_IMAGE)."
  warn "Set APP_IMAGE in $ENV_FILE to a tag you build/push elsewhere."
  warn "Nothing to build locally. Use './deploy-local.sh pull' to refresh."
}

cmd_pull() {
  info "Pulling app image: ${APP_IMAGE:-buyungbahari/docuseal-x:latest}"
  pull_with_retry
  ok "Pulled"
}

pull_with_retry() {
  local attempt=1 max=3
  while [ "$attempt" -le "$max" ]; do
    info "Pulling images (attempt $attempt/$max)"
    if "${DC[@]}" pull; then
      return 0
    fi
    warn "Pull failed; sleeping 5s before retry"
    sleep 5
    attempt=$((attempt + 1))
  done
  warn "Image pull kept failing -- continuing; docker compose will retry on up"
  return 0
}

cmd_up() {
  ensure_data_dirs
  pull_with_retry
  info "Starting stack"
  "${DC[@]}" up -d
  ok "Stack is up"
  printf "    Web:      http://localhost:%s\n" "${APP_PORT:-3000}"
  printf "    Postgres: localhost:%s (user/pass: postgres/postgres, db: docuseal)\n" "${POSTGRES_PORT:-5433}"
  printf "\nFollow logs with: %s logs -f app\n" "$0"
}

cmd_down() {
  info "Stopping stack"
  "${DC[@]}" down
  ok "Stopped"
}

cmd_restart() {
  cmd_down
  cmd_up
}

cmd_logs() {
  "${DC[@]}" logs -f --tail=200 "${1:-app}"
}

cmd_sh() {
  "${DC[@]}" exec app /bin/sh
}

cmd_psql() {
  "${DC[@]}" exec postgres psql -U postgres -d docuseal
}

cmd_status() {
  "${DC[@]}" ps
}

cmd_rm() {
  info "Force-removing local DocuSeal containers (volumes are preserved)"
  # Stop + remove via compose first.
  "${DC[@]}" down --remove-orphans || true
  # Belt-and-suspenders: nuke by container_name in case compose lost track
  # (e.g. after editing PROJECT_NAME or container_name in the compose file).
  for name in docuseal-app docuseal-postgres; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
      info "Removing container $name"
      docker rm -f "$name" >/dev/null
    fi
  done
  ok "Containers removed (run './deploy-local.sh up' to recreate)"
}

cmd_reset() {
  warn "This will delete the local DocuSeal database and uploaded files."
  printf "Type 'yes' to continue: "
  read -r answer
  [ "$answer" = "yes" ] || die "Aborted"
  "${DC[@]}" down -v || true
  # Legacy bind-mount dirs from earlier versions of this script.
  rm -rf tmp/docuseal-data tmp/docuseal-pg 2>/dev/null || true
  ok "Local data wiped"
}

main() {
  require_docker
  ensure_env_file
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  case "${1:-up}" in
    up|start)    cmd_up ;;
    down|stop)   cmd_down ;;
    restart)     cmd_restart ;;
    pull)        cmd_pull ;;
    build)       cmd_build ;;
    logs)        shift || true; cmd_logs "$@" ;;
    sh|shell)    cmd_sh ;;
    psql)        cmd_psql ;;
    status|ps)   cmd_status ;;
    rm|remove)   cmd_rm ;;
    reset)       cmd_reset ;;
    -h|--help|help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *)
      die "Unknown command: $1 (try: $0 help)"
      ;;
  esac
}

main "$@"
