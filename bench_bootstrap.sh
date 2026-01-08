#!/usr/bin/env bash
set -euo pipefail

# -------- helpers --------
die() {
  echo "Error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

# -------- load config --------
CONFIG_FILE="${1:-./bench_bootstrap.conf}"
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# -------- sanity checks --------
require_cmd bench
require_cmd git
require_cmd python3

[[ -n "${BENCH_GROUPS_PATH:-}" ]] || die "BENCH_GROUPS_PATH is not set"
[[ -n "${BENCH_NAME:-}" ]] || die "BENCH_NAME is not set"
[[ -n "${DOCKER_COMPOSE_CMD:-}" ]] || die "DOCKER_COMPOSE_CMD is not set"

BENCH_PATH="${BENCH_GROUPS_PATH}/${BENCH_NAME}"

# -------- step 1: go to bench groups + docker compose up --------
log "Changing to bench groups path: ${BENCH_GROUPS_PATH}"
cd "${BENCH_GROUPS_PATH}"

log "Starting docker compose (detached)"
${DOCKER_COMPOSE_CMD} up -d

# -------- step 2: bench init (idempotency: skip if bench exists) --------
if [[ -d "${BENCH_PATH}" ]]; then
  log "Bench already exists at ${BENCH_PATH} (skipping bench init)"
else
  log "Preparing bench init args from config"

  INIT_ARGS=()

  # base: bench init <name>
  # optional toggles
  if [[ "${BENCH_INIT_DEV:-0}" == "1" ]]; then INIT_ARGS+=("--dev"); fi
  if [[ -n "${BENCH_INIT_FRAPPE_BRANCH:-}" ]]; then
    INIT_ARGS+=("--frappe-branch" "${BENCH_INIT_FRAPPE_BRANCH}")
  fi
  if [[ "${BENCH_INIT_SKIP_ASSETS:-0}" == "1" ]]; then
    INIT_ARGS+=("--skip-assets")
  fi
  if [[ "${BENCH_INIT_NO_BACKUPS:-0}" == "1" ]]; then
    INIT_ARGS+=("--no-backups")
  fi
  if [[ "${BENCH_INIT_VERBOSE:-0}" == "1" ]]; then
    INIT_ARGS+=("--verbose")
  fi
  if [[ -n "${BENCH_INIT_APPS_PATH:-}" ]]; then
    INIT_ARGS+=("--apps_path" "${BENCH_INIT_APPS_PATH}")
  fi

  log "Running: bench init ${BENCH_NAME} ${INIT_ARGS[*]}"
  bench init "${BENCH_NAME}" "${INIT_ARGS[@]}"
fi

# -------- step 3: requirements + venv activate --------
log "Entering bench: ${BENCH_PATH}"
cd "${BENCH_PATH}"

log "Running: bench setup requirements"
bench setup requirements

if [[ -f "env/bin/activate" ]]; then
  log "Activating venv: env/bin/activate"
  # shellcheck disable=SC1091
  source "env/bin/activate"
else
  die "Virtualenv activate script not found at: ${BENCH_PATH}/env/bin/activate"
fi

# -------- step 4: git remote/branch operations --------
APP_PATH="${BENCH_PATH}/apps/${SUNTEK_APP_DIR_NAME}"
[[ -d "${APP_PATH}" ]] || die "App directory not found: ${APP_PATH}"

log "Entering app: ${APP_PATH}"
cd "${APP_PATH}"

# Remove remote if requested (ignore if missing)
if [[ -n "${GIT_REMOVE_REMOTE:-}" ]]; then
  if git remote get-url "${GIT_REMOVE_REMOTE}" >/dev/null 2>&1; then
    log "Removing remote: ${GIT_REMOVE_REMOTE}"
    git remote remove "${GIT_REMOVE_REMOTE}"
  else
    log "Remote '${GIT_REMOVE_REMOTE}' not present (skipping remove)"
  fi
fi

# Ensure desired remote exists and points to configured URL
if git remote get-url "${GIT_REMOTE_NAME}" >/dev/null 2>&1; then
  CURRENT_URL="$(git remote get-url "${GIT_REMOTE_NAME}")"
  if [[ "${CURRENT_URL}" != "${GIT_REMOTE_URL}" ]]; then
    log "Updating remote '${GIT_REMOTE_NAME}' URL to ${GIT_REMOTE_URL}"
    git remote set-url "${GIT_REMOTE_NAME}" "${GIT_REMOTE_URL}"
  else
    log "Remote '${GIT_REMOTE_NAME}' already set correctly"
  fi
else
  log "Adding remote '${GIT_REMOTE_NAME}': ${GIT_REMOTE_URL}"
  git remote add "${GIT_REMOTE_NAME}" "${GIT_REMOTE_URL}"
fi

log "Fetching from ${GIT_REMOTE_NAME}"
git fetch "${GIT_REMOTE_NAME}" --prune

log "Switching to branch: ${GIT_BRANCH}"
git switch "${GIT_BRANCH}"

# -------- step 5: new site + use + restore --------
log "Returning to bench: ${BENCH_PATH}"
cd "${BENCH_PATH}"

[[ -n "${SITE_NAME:-}" ]] || die "SITE_NAME is not set"
[[ -n "${DB_NAME:-}" ]] || die "DB_NAME is not set"
[[ -n "${DB_ROOT_PASSWORD:-}" ]] || die "DB_ROOT_PASSWORD is not set"
[[ -n "${ADMIN_PASSWORD:-}" ]] || die "ADMIN_PASSWORD is not set"
[[ -n "${BACKUP_PATH:-}" ]] || die "BACKUP_PATH is not set"
[[ -f "${BACKUP_PATH}" ]] || die "Backup file not found: ${BACKUP_PATH}"

if [[ -d "sites/${SITE_NAME}" ]]; then
  log "Site already exists: ${SITE_NAME} (skipping bench new-site)"
else
  log "Creating new site: ${SITE_NAME}"
  bench new-site "${SITE_NAME}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-name "${DB_NAME}"
fi

log "Setting default site: ${SITE_NAME}"
bench use "${SITE_NAME}"

log "Restoring backup into site: ${SITE_NAME}"
bench --site "${SITE_NAME}" restore "${BACKUP_PATH}" --db-root-password "${DB_ROOT_PASSWORD}"

log "Done."
