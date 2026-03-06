#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        fail "Missing required environment variable: $name"
        exit 1
    fi
}

require_env QUARTUS_HOST
require_env QUARTUS_PROJECT
require_env QUARTUS_LOCAL_JOB_DIR
require_env QUARTUS_LOCAL_LOG
require_env QUARTUS_FULL_COMPILE
require_env QUARTUS_JOB_ID
require_env QUARTUS_PARALLEL

NAS_USER="${QUARTUS_NAS_USER:-admin}"
NAS_REMOTE_ROOT="${QUARTUS_NAS_REMOTE_ROOT:-/share/CACHEDEV1_DATA/quartus/projects/fabi386_jobs}"
NAS_DOCKER="${QUARTUS_NAS_DOCKER:-/share/CACHEDEV1_DATA/.qpkg/container-station/bin/system-docker}"
NAS_CONTAINER="${QUARTUS_NAS_CONTAINER:-quartus}"
NAS_QUARTUS_BIN="${QUARTUS_NAS_QUARTUS_BIN:-/opt/intelFPGA/quartus/bin}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
REMOTE_WORKDIR="${NAS_REMOTE_ROOT}/${QUARTUS_JOB_ID}"
CONTAINER_WORKDIR="/projects/fabi386_jobs/${QUARTUS_JOB_ID}"
PARALLEL="$QUARTUS_PARALLEL"

ssh_cmd() {
    ssh $SSH_OPTS "$NAS_USER@$QUARTUS_HOST" "$@"
}

scp_cmd() {
    scp $SSH_OPTS "$@"
}

run_container() {
    local cmd="$1"
    ssh_cmd "$NAS_DOCKER exec $NAS_CONTAINER bash -c $(printf '%q' "$cmd")"
}

fetch_if_exists() {
    local relpath="$1"
    local local_target="$QUARTUS_LOCAL_JOB_DIR/$(dirname "$relpath")"
    mkdir -p "$local_target"
    if ssh_cmd "test -e '$REMOTE_WORKDIR/$relpath'" >/dev/null 2>&1; then
        scp_cmd "${NAS_USER}@${QUARTUS_HOST}:$REMOTE_WORKDIR/$relpath" "$local_target/"
    fi
}

info "Connecting to Quartus NAS at $QUARTUS_HOST..."
if ! ssh_cmd 'echo ok' >/dev/null 2>&1; then
    fail "Cannot reach NAS at $QUARTUS_HOST"
    exit 1
fi
ok "NAS reachable"

if ! ssh_cmd "test -x '$NAS_DOCKER'" >/dev/null 2>&1; then
    fail "Docker binary not found on NAS: $NAS_DOCKER"
    exit 1
fi

if ! ssh_cmd "$NAS_DOCKER ps --format '{{.Names}}' | grep -qx '$NAS_CONTAINER'" >/dev/null 2>&1; then
    fail "Quartus container '$NAS_CONTAINER' is not running on NAS"
    exit 1
fi

info "Setting up NAS job workspace..."
if ssh_cmd "test -e '$REMOTE_WORKDIR'" 2>/dev/null; then
    fail "Remote job dir already exists: $REMOTE_WORKDIR"
    fail "Delete it or use a different --job-name"
    exit 1
fi
ssh_cmd "mkdir -p '$NAS_REMOTE_ROOT'" >/dev/null

if [[ "$PARALLEL" == "auto" ]]; then
    PARALLEL=$(run_container "nproc 2>/dev/null || echo 4")
    if [[ ! "$PARALLEL" =~ ^[0-9]+$ ]]; then
        PARALLEL=4
    elif (( PARALLEL > 8 )); then
        PARALLEL=8
    elif (( PARALLEL < 1 )); then
        PARALLEL=1
    fi
fi

info "Copying staged Quartus job to NAS..."
scp_cmd -r "$QUARTUS_LOCAL_JOB_DIR" "${NAS_USER}@${QUARTUS_HOST}:$NAS_REMOTE_ROOT/"
ok "Copied job → $REMOTE_WORKDIR"

: > "$QUARTUS_LOCAL_LOG"

info "Running quartus_map in NAS container..."
run_container "export PATH=$NAS_QUARTUS_BIN:\$PATH; cd $CONTAINER_WORKDIR; quartus_map --parallel=$PARALLEL --read_settings_files=on --write_settings_files=off $QUARTUS_PROJECT -c $QUARTUS_PROJECT" >> "$QUARTUS_LOCAL_LOG" 2>&1

if [[ "$QUARTUS_FULL_COMPILE" == "1" ]]; then
    info "Running quartus_fit in NAS container..."
    run_container "export PATH=$NAS_QUARTUS_BIN:\$PATH; cd $CONTAINER_WORKDIR; quartus_fit --parallel=$PARALLEL $QUARTUS_PROJECT -c $QUARTUS_PROJECT" >> "$QUARTUS_LOCAL_LOG" 2>&1

    info "Running quartus_sta in NAS container..."
    run_container "export PATH=$NAS_QUARTUS_BIN:\$PATH; cd $CONTAINER_WORKDIR; quartus_sta $QUARTUS_PROJECT -c $QUARTUS_PROJECT" >> "$QUARTUS_LOCAL_LOG" 2>&1
fi

info "Fetching Quartus reports from NAS..."
fetch_if_exists "${QUARTUS_PROJECT}.map.rpt"
fetch_if_exists "${QUARTUS_PROJECT}.fit.rpt"
fetch_if_exists "${QUARTUS_PROJECT}.sta.rpt"
fetch_if_exists "output_files/${QUARTUS_PROJECT}.sof"
fetch_if_exists "output_files/${QUARTUS_PROJECT}.rbf"

ok "NAS backend complete"
