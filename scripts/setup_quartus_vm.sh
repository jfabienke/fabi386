#!/usr/bin/env bash
# ============================================================================
# fabi386: Quartus VM Setup — UTM + Ubuntu ARM64 + Rosetta + Quartus Lite
# ============================================================================
# Creates an Ubuntu ARM64 VM with Rosetta x86_64 translation for running
# Intel Quartus Prime Lite (x86_64) on Apple Silicon.
#
# NOTE: Quartus 25.1 crashes under Rosetta (uses AVX in SQLite).
#       Use Quartus 21.1 which works correctly.
#
# NOTE: Must use --parallel=1 when running quartus_map under Rosetta.
#       Multi-process IPC (named pipes) deadlocks under Rosetta translation.
#
# NOTE: Run synthesis from tmpfs (/tmp/ramdisk), not VirtIO shared mount.
#       The shared filesystem is too slow for Quartus's random I/O patterns.
#
# Usage:
#   ./scripts/setup_quartus_vm.sh download     # Download Ubuntu ISO + Quartus
#   ./scripts/setup_quartus_vm.sh create-vm    # Create UTM VM (after downloads)
#   ./scripts/setup_quartus_vm.sh post-install # Print commands for inside VM
# ============================================================================

set -euo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

DOWNLOAD_DIR="$HOME/Downloads/quartus_vm"

UBUNTU_ISO="ubuntu-24.04.4-live-server-arm64.iso"
UBUNTU_URL="https://cdimage.ubuntu.com/releases/24.04/release/$UBUNTU_ISO"

# Quartus Prime Lite 21.1 — works under Rosetta (no AVX)
QUARTUS_INSTALLER="QuartusLiteSetup-21.1.0.842-linux.run"
QUARTUS_URL="https://downloads.intel.com/akdlm/software/acdsinst/21.1std/842/ib_installers/$QUARTUS_INSTALLER"

CYCLONEV_PKG="cyclonev-21.1.0.842.qdz"
CYCLONEV_URL="https://downloads.intel.com/akdlm/software/acdsinst/21.1std/842/ib_installers/$CYCLONEV_PKG"

download_files() {
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Downloading Ubuntu ISO + Quartus Lite 21.1${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""

    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR"

    # Download Ubuntu ISO (~2.8 GB)
    if [[ -f "$UBUNTU_ISO" ]]; then
        echo -e "${GREEN}[OK]${NC} $UBUNTU_ISO already exists"
    else
        echo -e "${CYAN}[DL]${NC} Ubuntu 24.04 ARM64 server ISO (~2.8 GB)..."
        curl -L -o "$UBUNTU_ISO.part" "$UBUNTU_URL"
        mv "$UBUNTU_ISO.part" "$UBUNTU_ISO"
        echo -e "${GREEN}[OK]${NC} $UBUNTU_ISO"
    fi

    # Download Quartus installer (~1.8 GB)
    if [[ -f "$QUARTUS_INSTALLER" ]]; then
        echo -e "${GREEN}[OK]${NC} $QUARTUS_INSTALLER already exists"
    else
        echo -e "${CYAN}[DL]${NC} Quartus Prime Lite 21.1 installer (~1.8 GB)..."
        curl -L -o "$QUARTUS_INSTALLER.part" "$QUARTUS_URL"
        mv "$QUARTUS_INSTALLER.part" "$QUARTUS_INSTALLER"
        echo -e "${GREEN}[OK]${NC} $QUARTUS_INSTALLER"
    fi

    # Download Cyclone V device support (~1.3 GB)
    if [[ -f "$CYCLONEV_PKG" ]]; then
        echo -e "${GREEN}[OK]${NC} $CYCLONEV_PKG already exists"
    else
        echo -e "${CYAN}[DL]${NC} Cyclone V device support (~1.3 GB)..."
        curl -L -o "$CYCLONEV_PKG.part" "$CYCLONEV_URL"
        mv "$CYCLONEV_PKG.part" "$CYCLONEV_PKG"
        echo -e "${GREEN}[OK]${NC} $CYCLONEV_PKG"
    fi

    echo ""
    echo -e "${GREEN}[DONE]${NC} All files in $DOWNLOAD_DIR"
    echo -e "  Total: ~5.9 GB"
    echo ""
    echo -e "${BOLD}Next step:${NC} Create the VM with: $0 create-vm"
}

create_vm() {
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Creating UTM VM for Quartus${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""

    if [[ ! -f "$DOWNLOAD_DIR/$UBUNTU_ISO" ]]; then
        echo -e "${RED}[ERR]${NC} Ubuntu ISO not found. Run: $0 download"
        exit 1
    fi

    echo -e "${YELLOW}Manual steps in UTM:${NC}"
    echo ""
    echo "  1. Open UTM (it should launch now)"
    echo "  2. Click '+' → Virtualize → Linux"
    echo "  3. Check 'Use Apple Virtualization'"
    echo "  4. Check 'Enable Rosetta (x86_64 Emulation)'"
    echo "  5. Boot ISO: Browse → $DOWNLOAD_DIR/$UBUNTU_ISO"
    echo "  6. Hardware:"
    echo "       CPU cores: 8  (of your 20)"
    echo "       RAM: 8192 MB  (of your 64 GB)"
    echo "  7. Storage: 40 GB  (Quartus needs ~22 GB installed)"
    echo "  8. Shared Directory: $HOME/Development/fabi386"
    echo "       (this shares your project into the VM)"
    echo "  9. Name the VM: 'quartus'"
    echo " 10. Click Save, then Start"
    echo ""
    echo -e "${CYAN}[INFO]${NC} During Ubuntu install:"
    echo "  - Choose 'Ubuntu Server (minimized)' if available"
    echo "  - Username: quartus"
    echo "  - Hostname: quartus-vm"
    echo "  - Enable OpenSSH server"
    echo "  - No snaps needed"
    echo ""

    # Launch UTM
    open /Applications/UTM.app
}

post_install() {
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Post-Install: Rosetta + Quartus 21.1 Setup${NC}"
    echo -e "${BOLD}  (Run this INSIDE the Ubuntu VM)${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    cat << 'SCRIPT'
# ---- Run these commands inside the Ubuntu VM ----

# 1. Mount Rosetta
sudo mkdir -p /media/rosetta
sudo mount -t virtiofs rosetta /media/rosetta

# Add to fstab for persistence
echo 'rosetta	/media/rosetta	virtiofs	ro,nofail	0	0' | sudo tee -a /etc/fstab

# 2. Install binfmt and register Rosetta
sudo apt update
sudo apt install -y binfmt-support

sudo /usr/sbin/update-binfmts --install rosetta /media/rosetta/rosetta \
    --magic "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00" \
    --mask "\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff" \
    --credentials yes --preserve yes --fix-binary yes

# 3. Enable x86_64 packages
sudo dpkg --add-architecture amd64
sudo apt update

# 4. Install Quartus dependencies (x86_64)
sudo apt install -y \
    libc6:amd64 \
    libstdc++6:amd64 \
    libncurses5:amd64 \
    libxtst6:amd64 \
    libxft2:amd64 \
    libxrender1:amd64 \
    libxi6:amd64 \
    libfreetype6:amd64 \
    libsm6:amd64 \
    libxext6:amd64 \
    zlib1g:amd64 \
    libpng16-16:amd64 \
    libglib2.0-0:amd64

# 5. Mount shared directory (your fabi386 project)
sudo mkdir -p /mnt/fabi386
sudo mount -t virtiofs share /mnt/fabi386
echo 'share	/mnt/fabi386	virtiofs	rw,nofail	0	0' | sudo tee -a /etc/fstab

# 6. Copy Quartus files from shared dir and install
cd /tmp
# SCP from host: scp QuartusLiteSetup-21.1.0.842-linux.run cyclonev-21.1.0.842.qdz quartus@<vm-ip>:/tmp/

chmod +x QuartusLiteSetup-21.1.0.842-linux.run
./QuartusLiteSetup-21.1.0.842-linux.run \
    --mode unattended \
    --installdir $HOME/intelFPGA_lite/21.1 \
    --accept_eula 1

# 7. Patch qenv.sh for Rosetta (uname -m returns aarch64, not x86_64)
QENV="$HOME/intelFPGA_lite/21.1/quartus/adm/qenv.sh"
sed -i 's/QUARTUS_MAINDIR=.*/QUARTUS_MAINDIR="$HOME\/intelFPGA_lite\/21.1\/quartus"/' "$QENV"
# Comment out the uname -m check that rejects non-x86_64
sed -i '/uname -m/s/^/#/' "$QENV"
# Comment out the SSE check
sed -i '/sse/s/^/#/' "$QENV"

# 8. Add to PATH
echo 'export PATH="$HOME/intelFPGA_lite/21.1/quartus/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 9. Verify installation
quartus_map --version

SCRIPT
    echo ""
    echo -e "${CYAN}[INFO]${NC} Copy-paste the commands above into your VM terminal."
    echo ""
    echo -e "${YELLOW}IMPORTANT — Rosetta synthesis caveats:${NC}"
    echo "  1. Must use --parallel=1  (Rosetta deadlocks on Quartus IPC pipes)"
    echo "  2. Run from tmpfs, not VirtIO shared mount (too slow for random I/O)"
    echo "  3. Use scripts/quartus_synth_check.sh to run synthesis correctly"
    echo ""
}

# --- Main ---
case "${1:-}" in
    download)    download_files ;;
    create-vm)   create_vm ;;
    post-install) post_install ;;
    *)
        echo "Usage: $0 {download|create-vm|post-install}"
        echo ""
        echo "  download      Download Ubuntu ISO + Quartus 21.1 (~5.9 GB)"
        echo "  create-vm     Open UTM with VM creation instructions"
        echo "  post-install  Print commands to run inside the VM"
        exit 1
        ;;
esac
