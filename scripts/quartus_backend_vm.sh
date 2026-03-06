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

VM_USER="${QUARTUS_VM_USER:-quartus}"
VM_PASS="${QUARTUS_VM_PASS:-quartus}"
VM_RAMDISK_ROOT="${QUARTUS_VM_RAMDISK_ROOT:-/tmp/ramdisk}"
VM_JOB_ROOT="${QUARTUS_VM_JOB_ROOT:-${VM_RAMDISK_ROOT}/fabi386_jobs}"
VM_QUARTUS_BIN="${QUARTUS_VM_QUARTUS_BIN:-\$HOME/intelFPGA_lite/21.1/quartus/bin}"
SSH_OPTS="-o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=5"
REMOTE_WORKDIR="${VM_JOB_ROOT}/${QUARTUS_JOB_ID}"
PARALLEL="$QUARTUS_PARALLEL"

if [[ "$PARALLEL" == "auto" ]]; then
    PARALLEL=1
fi

if ! command -v sshpass >/dev/null 2>&1; then
    fail "sshpass not found in PATH"
    exit 1
fi

ssh_cmd() {
    sshpass -p "$VM_PASS" ssh $SSH_OPTS "$VM_USER@$QUARTUS_HOST" "$@"
}

scp_cmd() {
    sshpass -p "$VM_PASS" scp $SSH_OPTS "$@"
}

fetch_if_exists() {
    local relpath="$1"
    local local_target="$QUARTUS_LOCAL_JOB_DIR/$(dirname "$relpath")"
    mkdir -p "$local_target"
    if ssh_cmd "test -e '$REMOTE_WORKDIR/$relpath'" >/dev/null 2>&1; then
        scp_cmd "${VM_USER}@${QUARTUS_HOST}:$REMOTE_WORKDIR/$relpath" "$local_target/"
    fi
}

info "Connecting to Quartus VM at $QUARTUS_HOST..."
if ! ssh_cmd 'echo ok' >/dev/null 2>&1; then
    fail "Cannot reach VM at $QUARTUS_HOST"
    exit 1
fi
ok "VM reachable"

info "Setting up VM ramdisk workspace..."
ssh_cmd "
    if ! mountpoint -q $VM_RAMDISK_ROOT 2>/dev/null; then
        mkdir -p $VM_RAMDISK_ROOT
        echo '$VM_PASS' | sudo -S mount -t tmpfs -o size=2G tmpfs $VM_RAMDISK_ROOT 2>/dev/null || true
        echo '$VM_PASS' | sudo -S chown $VM_USER:$VM_USER $VM_RAMDISK_ROOT 2>/dev/null || true
    fi
    mkdir -p $VM_JOB_ROOT
" >/dev/null

if ssh_cmd "test -e '$REMOTE_WORKDIR'" 2>/dev/null; then
    fail "Remote job dir already exists: $REMOTE_WORKDIR"
    fail "Delete it or use a different --job-name"
    exit 1
fi

info "Copying staged Quartus job to VM..."
scp_cmd -r "$QUARTUS_LOCAL_JOB_DIR" "${VM_USER}@${QUARTUS_HOST}:$VM_JOB_ROOT/"
ok "Copied job → $REMOTE_WORKDIR"

: > "$QUARTUS_LOCAL_LOG"

info "Running quartus_map on VM..."
ssh_cmd "
    export PATH=$VM_QUARTUS_BIN:\$PATH
    cd $REMOTE_WORKDIR
    quartus_map --parallel=$PARALLEL --read_settings_files=on --write_settings_files=off $QUARTUS_PROJECT -c $QUARTUS_PROJECT
" >> "$QUARTUS_LOCAL_LOG" 2>&1

if [[ "$QUARTUS_FULL_COMPILE" == "1" ]]; then
    info "Running quartus_fit on VM..."
    ssh_cmd "
        export PATH=$VM_QUARTUS_BIN:\$PATH
        cd $REMOTE_WORKDIR
        quartus_fit --parallel=$PARALLEL $QUARTUS_PROJECT -c $QUARTUS_PROJECT
    " >> "$QUARTUS_LOCAL_LOG" 2>&1

    info "Running quartus_sta on VM..."
    ssh_cmd "
        export PATH=$VM_QUARTUS_BIN:\$PATH
        cd $REMOTE_WORKDIR
        quartus_sta $QUARTUS_PROJECT -c $QUARTUS_PROJECT
    " >> "$QUARTUS_LOCAL_LOG" 2>&1
fi

info "Fetching Quartus reports from VM..."
fetch_if_exists "${QUARTUS_PROJECT}.map.rpt"
fetch_if_exists "${QUARTUS_PROJECT}.fit.rpt"
fetch_if_exists "${QUARTUS_PROJECT}.sta.rpt"
fetch_if_exists "output_files/${QUARTUS_PROJECT}.sof"
fetch_if_exists "output_files/${QUARTUS_PROJECT}.rbf"

ok "VM backend complete"
