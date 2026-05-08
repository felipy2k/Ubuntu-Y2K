#!/usr/bin/env bash

set -uo pipefail

# Setup logging — captures all output to a timestamped log file in $HOME
LOG_FILE="$HOME/ubuntu-y2k-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "\n${GREEN}▶ $*${NC}"; }
step()    { echo -e "  ${CYAN}→ $*${NC}"; }
warning() { echo -e "  ${YELLOW}⚠ $*${NC}"; ((WARN_COUNT++)) || true; }
fail()    { echo -e "${RED}✗ $*${NC}"; }
ok()      { echo -e "  ${GREEN}✓ $*${NC}"; }

# Counter to summarize warnings at the end
WARN_COUNT=0

# Robust try() — works correctly with set -e/pipefail by toggling it locally.
# Returns 0 always, so a failure inside try() never aborts the script.
try() {
  set +e
  "$@"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warning "Failed (exit $rc), continuing: $*"
  fi
  return 0
}

# Purge packages, silently skipping those not installed.
# apt-get purge aborts the whole transaction on a single missing package, so
# we filter the list to only what's actually installed first.
# Supports glob patterns (e.g. 'libreoffice*', 'transmission-*').
purge_if_installed() {
  local pkgs
  # dpkg-query expands globs and filters to actually-installed packages.
  pkgs=$(dpkg-query -W -f='${Package}\n' "$@" 2>/dev/null || true)
  if [[ -n "$pkgs" ]]; then
    # shellcheck disable=SC2086  # we want word-splitting here
    try sudo apt-get purge -y $pkgs
  fi
}

# Wait for any background apt/dpkg/snapd process to release the lock.
# snapd on Ubuntu 26.04 runs automatic snap refreshes that hold dpkg's lock,
# causing 'apt-get' to fail with "Could not get lock /var/lib/dpkg/lock-frontend".
wait_for_apt() {
  local lock_files=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )
  local waited=0
  while true; do
    local locked=false
    for f in "${lock_files[@]}"; do
      if sudo fuser "$f" &>/dev/null 2>&1; then
        locked=true
        break
      fi
    done
    $locked || break
    if [[ $waited -eq 0 ]]; then
      step "Waiting for apt/dpkg lock to be released (snapd may be refreshing)..."
    fi
    sleep 2
    (( waited += 2 ))
    if [[ $waited -ge 120 ]]; then
      warning "apt lock held for over 2 minutes — forcing release and continuing."
      sudo killall apt apt-get dpkg 2>/dev/null || true
      sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
                 /var/lib/apt/lists/lock /var/cache/apt/archives/lock
      sudo dpkg --configure -a 2>/dev/null || true
      break
    fi
  done
}

if [[ "$EUID" -eq 0 ]]; then
  fail "Do not run as root. Run as a regular user."
  exit 1
fi

# Detect Ubuntu version from /etc/os-release (e.g. "26.04")
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  UBUNTU_VER="${VERSION_ID:-unknown}"
  UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}"
else
  UBUNTU_VER="unknown"
  UBUNTU_CODENAME="unknown"
fi

# Non-interactive frontend so apt doesn't prompt during the run
export DEBIAN_FRONTEND=noninteractive

# Apt flags reused everywhere — quiet but informative, no recommends to keep things lean.
# --allow-downgrades is required to swap the Firefox snap shim (whose '1:' epoch
# makes its version appear higher) for the real .deb from the Mozilla Team PPA.
APT_INSTALL=(sudo apt-get install -y --no-install-recommends --allow-downgrades)

show_menu() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║          Ubuntu 26.04 — Custom Post-Install Setup             ║"
  echo "║          User: ${USER}                                        ║"
  echo "╠═══════════════════════════════════════════════════════════════╣"
  echo "║  [1] Run EVERYTHING (recommended)                            ║"
  echo "║  [2] Update system only                                      ║"
  echo "║  [3] Remove bloatware only                                   ║"
  echo "║  [4] Install APT packages only                               ║"
  echo "║  [5] Install Flatpaks only                                   ║"
  echo "║  [6] Install CUDA Toolkit only (driver must already exist)   ║"
  echo "║  [7] Install GNOME extensions only                           ║"
  echo "║  [8] Apply visual settings only                              ║"
  echo "║  [9] Final verification                                      ║"
  echo "║  [0] Exit                                                    ║"
  echo "║  [r] Exit and reboot the system                              ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  read -rp "  Choose an option: " CHOICE
}

# ─────────────────────────────────────────────
# REPOS
# ─────────────────────────────────────────────
add_repos() {
  info "[REPOS] Adding repositories"
  wait_for_apt

  step "Ensuring keyrings directory exists"
  try sudo install -d -m 0755 /etc/apt/keyrings

  # IMPORTANT: software-properties-common provides 'add-apt-repository' itself —
  # it MUST be installed before any add-apt-repository call. On Desktop installs
  # it's preinstalled, but Server/minimal/container installs need this first.
  step "Installing prerequisites for adding third-party repos"
  try sudo apt-get update
  try "${APT_INSTALL[@]}" curl wget gnupg ca-certificates apt-transport-https \
    software-properties-common

  step "Enabling universe and multiverse components"
  # 'universe' provides VLC, OBS, Steam metapackage; 'multiverse' provides
  # ubuntu-restricted-extras (MS Core fonts, libavcodec-extra, lame).
  try sudo add-apt-repository -y universe
  try sudo add-apt-repository -y multiverse

  step "Google Chrome"
  if [[ ! -f /etc/apt/keyrings/google-chrome.gpg ]]; then
    try sudo bash -c '
      curl -fsSL https://dl.google.com/linux/linux_signing_key.pub |
        gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
      chmod a+r /etc/apt/keyrings/google-chrome.gpg
    '
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
      | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
  fi

  step "Brave Browser"
  if [[ ! -f /etc/apt/keyrings/brave-browser-archive-keyring.gpg ]]; then
    try sudo curl -fsSLo /etc/apt/keyrings/brave-browser-archive-keyring.gpg \
      https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
    try sudo chmod a+r /etc/apt/keyrings/brave-browser-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
      | sudo tee /etc/apt/sources.list.d/brave-browser-release.list > /dev/null
  fi

  step "Mozilla Team PPA (native Firefox .deb instead of snap shim)"
  # The 'firefox' package in main is a transitional shim that pulls the snap.
  # The Mozilla Team PPA ships the real .deb. Priority 1001 is mandatory:
  #   - 1001 lets apt downgrade across origins (the snap shim sometimes carries
  #     a higher version string than the PPA, blocking the swap without 1001)
  #   - It also prevents unattended-upgrades from quietly switching back to
  #     the snap on future updates.
  if ! grep -rq 'mozillateam' /etc/apt/sources.list.d/ 2>/dev/null; then
    try sudo add-apt-repository -y ppa:mozillateam/ppa
  fi
  sudo tee /etc/apt/preferences.d/mozilla-firefox > /dev/null <<'EOF'
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF

  try sudo apt-get update
}

# ─────────────────────────────────────────────
# SYSTEM UPDATE
# ─────────────────────────────────────────────
update_system() {
  info "[SYSTEM] Updating system"
  wait_for_apt
  try sudo apt-get update
  # --allow-downgrades is needed because the Mozilla PPA's Firefox replaces the
  # snap shim (which carries a '1:' epoch and therefore looks "newer" to apt).
  try sudo apt-get upgrade -y --allow-downgrades
  try sudo apt-get full-upgrade -y --allow-downgrades
}

# ─────────────────────────────────────────────
# CODECS — ubuntu-restricted-extras + libavcodec-extra + GPU VAAPI
# Equivalent to RPM Fusion's "Multimedia" group on Fedora.
# ─────────────────────────────────────────────
install_codecs() {
  info "[CODECS] Installing multimedia codecs"

  step "Pre-accepting Microsoft EULAs (so the install runs unattended)"
  echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
    | sudo debconf-set-selections
  echo "ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note" \
    | sudo debconf-set-selections

  step "Installing ubuntu-restricted-extras (codecs, MS fonts, lame, libavcodec-extra)"
  # ubuntu-restricted-extras is the canonical entry point: pulls in libavcodec-extra,
  # gstreamer1.0-libav, gstreamer1.0-plugins-ugly, ttf-mscorefonts-installer,
  # unrar, and the right GStreamer plugin set for the desktop.
  try "${APT_INSTALL[@]}" ubuntu-restricted-extras

  step "Installing only what ubuntu-restricted-extras does NOT already include"
  # gstreamer1.0-vaapi — VA-API bridge for GStreamer (hardware decode/encode)
  # ffmpeg             — full CLI binary (restricted-extras only pulls the libs)
  try "${APT_INSTALL[@]}" \
    gstreamer1.0-vaapi \
    ffmpeg

  step "Hardware video acceleration (VA-API/VDPAU)"
  # Auto-detects GPU to apply the correct drivers
  if lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -qi 'amd\|radeon\|ati'; then
    step "AMD GPU detected — installing mesa VA-API/VDPAU drivers"
    # On Ubuntu the mesa-va-drivers / mesa-vdpau-drivers packages from main already
    # include H.264/H.265 support (no 'freeworld' split like on Fedora/RPM Fusion).
    try "${APT_INSTALL[@]}" mesa-va-drivers mesa-vdpau-drivers vainfo vdpauinfo
  fi

  if lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -qi 'intel'; then
    step "Intel GPU detected — installing intel-media-va-driver-non-free"
    # The 'non-free' variant (from multiverse) enables HEVC/VP9 decode on Gen9+ iGPUs.
    try "${APT_INSTALL[@]}" intel-media-va-driver-non-free i965-va-driver-shaders vainfo
  fi
}

# ─────────────────────────────────────────────
# APT PACKAGES
# Install EVERYTHING before removing anything
# to avoid breaking dependencies
# ─────────────────────────────────────────────
install_apt_packages() {
  info "[APT] Installing APT packages"

  install_codecs

  # Install in logical groups so a failure in one group doesn't silently
  # cascade and skip everything else. Each group has its own try().

  step "Base tools"
  try "${APT_INSTALL[@]}" \
    git wget curl fastfetch pipx papirus-icon-theme \
    build-essential dkms pciutils

  step "Flatpak runtime + GNOME Software integration plugin"
  # flatpak provides the runtime; gnome-software-plugin-flatpak is what makes
  # Flatpak apps show up and update inside GNOME Software's UI.
  # Note: Ubuntu 26.04's App Center does not yet integrate Flatpak (planned for
  # later), but we install gnome-software in [GNOME apps] below, which does.
  try "${APT_INSTALL[@]}" flatpak gnome-software-plugin-flatpak

  step "Browsers (Chrome, Brave, Tor)"
  # Firefox is split into its own step below — installing it via apt requires
  # --allow-downgrades to swap the snap shim, and a single failure here would
  # otherwise abort the whole transaction and take Chrome/Brave down with it.
  try "${APT_INSTALL[@]}" \
    google-chrome-stable brave-browser torbrowser-launcher

  step "Firefox (.deb from Mozilla Team PPA)"
  # The PPA pin (priority 1001, set in add_repos) selects this version.
  # The snap shim's '1:' epoch makes apt see this as a downgrade — that's
  # what --allow-downgrades in APT_INSTALL handles.
  try "${APT_INSTALL[@]}" firefox

  step "Multimedia apps"
  try "${APT_INSTALL[@]}" \
    vlc audacity darktable handbrake easyeffects obs-studio

  step "Graphics / 3D"
  try "${APT_INSTALL[@]}" \
    gimp inkscape blender

  step "Gaming"
  try "${APT_INSTALL[@]}" steam-installer

  step "GNOME apps"
  # Note: Ptyxis is the default terminal on Ubuntu 26.04 — no need to install gnome-terminal.
  try "${APT_INSTALL[@]}" \
    gnome-tweaks baobab nautilus deja-dup gnome-boxes gnome-calculator \
    gnome-calendar gnome-snapshot gnome-characters gnome-connections \
    gnome-contacts simple-scan gnome-disk-utility gnome-text-editor \
    gnome-font-viewer gnome-color-manager gnome-software gnome-clocks \
    gnome-logs evince loupe

  step "Utilities"
  try "${APT_INSTALL[@]}" \
    timeshift solaar dreamchess lm-sensors

  step "InputLeap (share mouse/keyboard across computers)"
  # input-leap isn't in Ubuntu 26.04's archives yet — try apt first, fall back
  # to Flatpak so the app is at least available (with sandbox limitations on
  # input device access). Re-run option [4] later when the .deb lands.
  if apt-cache show input-leap &>/dev/null; then
    try "${APT_INSTALL[@]}" input-leap
  else
    warning "input-leap not in apt archives — installing via Flatpak as fallback."
    if ! command -v flatpak &>/dev/null; then
      try "${APT_INSTALL[@]}" flatpak gnome-software-plugin-flatpak
    fi
    try flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo
    try flatpak install -y flathub io.github.input_leap.InputLeap
  fi

  # ── NordVPN — official installer (handles repo + GPG + install) ──
  step "NordVPN"
  if ! command -v nordvpn &>/dev/null; then
    if curl -sSf --max-time 10 -o /dev/null https://downloads.nordcdn.com/apps/linux/install.sh 2>/dev/null; then
      step "Running official NordVPN installer (CLI + GUI)"
      if sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh) -p nordvpn-gui; then
        ok "NordVPN installed."
        try sudo systemctl enable --now nordvpnd
        try sudo usermod -aG nordvpn "$USER"
        ok "Log in with: nordvpn login"
        warning "Group membership requires logout/reboot. For immediate use: newgrp nordvpn"
      else
        warning "NordVPN installer failed. Try manually after reboot:"
        echo "  sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)"
      fi
    else
      warning "Cannot reach nordcdn.com — skipping NordVPN."
    fi
  else
    ok "NordVPN already installed (skipping)."
  fi
}

# ─────────────────────────────────────────────
# FREEOFFICE
# Replaces LibreOffice (removed afterwards)
# ─────────────────────────────────────────────
install_freeoffice() {
  info "[FREEOFFICE] Installing FreeOffice 2024"

  # Check connectivity before attempting curl | bash
  if ! curl -fsSL --max-time 5 -o /dev/null https://softmaker.net/down/install-softmaker-freeoffice-2024.sh 2>/dev/null; then
    warning "Cannot reach softmaker.net — skipping FreeOffice installation."
    warning "Run option [4] later when connected, or install manually:"
    echo "  curl -fsSL https://softmaker.net/down/install-softmaker-freeoffice-2024.sh | sudo bash"
    return
  fi

  step "Downloading and running official installer"
  # The same SoftMaker installer auto-detects DEB vs RPM — works on Ubuntu unchanged.
  # Also configures the apt repo so future updates flow through 'apt upgrade'.
  if curl -fsSL https://softmaker.net/down/install-softmaker-freeoffice-2024.sh | sudo bash; then
    ok "FreeOffice installed successfully."
  else
    warning "Failed to install FreeOffice. Try manually:"
    echo "  curl -fsSL https://softmaker.net/down/install-softmaker-freeoffice-2024.sh | sudo bash"
  fi
}

# ─────────────────────────────────────────────
# FLATPAKS
# ─────────────────────────────────────────────
install_flatpaks() {
  info "[FLATPAK] Installing apps from Flathub"

  # Defensive: install_apt_packages already installs flatpak +
  # gnome-software-plugin-flatpak; this check only fires when the user runs
  # option [5] standalone without having run [1] or [4] first.
  if ! command -v flatpak &>/dev/null; then
    step "flatpak not found — installing it now"
    try "${APT_INSTALL[@]}" flatpak gnome-software-plugin-flatpak
  fi

  try flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo

  FLATPAK_IDS=(
    # System utilities
    com.mattjakeman.ExtensionManager        # GNOME Extension Manager
    com.github.tchx84.Flatseal              # Flatpak permissions manager
    io.github.peazip.PeaZip                 # Archive manager
    com.system76.Popsicle                   # USB image flasher
    com.github.ADBeveridge.Raider           # File Shredder
    org.localsend.localsend_app             # LocalSend (LAN file sharing)
    io.gitlab.adhami3310.Converter          # Switcheroo (image format converter)
    io.podman_desktop.PodmanDesktop         # Podman Desktop (container management)
    # NOTE: Resources (net.nokyan.Resources) is NOT installed via Flatpak —
    # Ubuntu 26.04 ships Resources natively as the default system monitor.

    # Multimedia
    org.shotcut.Shotcut                     # Video editor
    org.gnome.gitlab.YaLTeR.VideoTrimmer    # Video trimmer
    hu.irl.cameractrls                      # Camera controls
    net.fasterland.converseen               # Batch image converter

    # Productivity / Creativity
    org.freecad.FreeCAD                     # 3D CAD
    org.upscayl.Upscayl                     # AI image upscaler
    io.github.nokse22.Exhibit               # 3D model viewer
    com.github.phase1geo.Minder             # Mind mapping
    com.motrix.Motrix                       # Download manager

    # Entertainment / Sound / Other
    com.rafaelmardojai.Blanket              # Ambient sounds
    de.haeckerfelix.Shortwave               # Internet radio
    org.gnome.Podcasts                      # Podcasts
    nl.hjdskes.gcolor3                      # Color picker
    com.vixalien.sticky                     # Sticky Notes
    com.jeffser.Alpaca                      # Alpaca (local LLM)
  )

  for app in "${FLATPAK_IDS[@]}"; do
    # Strip inline comments
    app="${app%%#*}"
    app="${app//[[:space:]]/}"
    [[ -z "$app" ]] && continue
    step "$app"
    try flatpak install -y flathub "$app"
  done
}

# ─────────────────────────────────────────────
# CUDA TOOLKIT (driver-less)
# This script intentionally does NOT install the NVIDIA driver itself —
# Ubuntu already exposes that through:
#   • The "Install third-party software" checkbox during a fresh install
#   • Software & Updates → "Additional Drivers" tab (apt: software-properties-gtk)
#   • CLI: sudo ubuntu-drivers install
# This function only adds the FULL CUDA Toolkit (nvcc, cuBLAS, headers,
# samples) on top of an already-installed driver, for build-time workloads.
# ─────────────────────────────────────────────
install_cuda() {
  info "[CUDA] CUDA Toolkit installation"

  # Precise filter using PCI class codes:
  #   0300 = VGA, 0302 = 3D controller, 0380 = Display controller
  if ! lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -qi nvidia; then
    warning "No NVIDIA GPU detected. Skipping CUDA installation."
    return
  fi

  GPU_INFO="$(lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -i nvidia | head -1)"
  ok "NVIDIA GPU detected: $GPU_INFO"

  # Driver presence check — CUDA Toolkit needs the proprietary driver to be
  # useful, and our pin (below) blocks NVIDIA's own driver packages, so we
  # warn loudly if none is found.
  if ! dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -qE '^nvidia-driver-[0-9]+$'; then
    warning "No NVIDIA driver detected on this system."
    echo "  CUDA Toolkit needs the proprietary driver. Install it first via:"
    echo "    1. Software & Updates → 'Additional Drivers' tab"
    echo "       (run: sudo apt install software-properties-gtk if not present)"
    echo "    2. CLI:  sudo ubuntu-drivers install"
    echo "    3. The 'Install third-party software' checkbox during Ubuntu setup"
    echo
    read -rp "  Continue with CUDA install anyway? [y/N]: " NO_DRIVER_CONFIRM
    [[ "${NO_DRIVER_CONFIRM,,}" != "y" ]] && { warning "CUDA installation cancelled."; return; }
  else
    ok "NVIDIA driver present — proceeding."
  fi

  echo
  echo -e "${BOLD}── Full CUDA Toolkit (nvcc, cuBLAS, headers, samples) ──${NC}"
  echo "Note: an installed NVIDIA driver already provides CUDA RUNTIME support for"
  echo "apps (Blender, OBS, PyTorch wheels, etc.). This step adds the BUILD-time"
  echo "toolkit on top — only useful if you're compiling CUDA code."
  read -rp "  Add the official NVIDIA CUDA repo and install cuda-toolkit? [y/N]: " CUDA_CONFIRM
  if [[ "${CUDA_CONFIRM,,}" != "y" ]]; then
    ok "Skipped — driver-only CUDA support is sufficient for most applications."
    return
  fi

  # Build the distro tag that NVIDIA's repo expects, e.g. "ubuntu2604"
  DISTRO_TAG="ubuntu${UBUNTU_VER//./}"
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64)  CUDA_ARCH="x86_64" ;;
    arm64)  CUDA_ARCH="sbsa"   ;;
    *)      CUDA_ARCH=""       ;;
  esac

  if [[ -z "$CUDA_ARCH" ]]; then
    warning "Unsupported architecture for CUDA: $ARCH — skipping."
    return
  fi

  step "Adding NVIDIA CUDA repository for ${DISTRO_TAG} (${CUDA_ARCH})"
  KEYRING_DEB="/tmp/cuda-keyring.deb"
  if curl -fsSL --max-time 30 \
      "https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO_TAG}/${CUDA_ARCH}/cuda-keyring_1.1-1_all.deb" \
      -o "$KEYRING_DEB"; then
    try sudo dpkg -i "$KEYRING_DEB"
    rm -f "$KEYRING_DEB"
    try sudo apt-get update

    step "Pinning Ubuntu's NVIDIA driver packages so the CUDA repo doesn't override them"
    # Without this pin, NVIDIA's repo can replace driver packages mid-upgrade
    # and leave a broken module. The pin keeps Ubuntu in charge of the driver
    # while NVIDIA only supplies cuda-toolkit and friends.
    sudo tee /etc/apt/preferences.d/cuda-pin-nvidia-driver > /dev/null <<'EOF'
Package: nvidia-driver-* nvidia-dkms-* nvidia-kernel-* libnvidia-* nvidia-utils-* nvidia-compute-utils-* xserver-xorg-video-nvidia-*
Pin: origin developer.download.nvidia.com
Pin-Priority: -1
EOF

    step "Installing cuda-toolkit (nvcc, libs, headers)"
    try "${APT_INSTALL[@]}" cuda-toolkit
    ok "CUDA Toolkit installed. Run 'nvcc --version' after rebooting."
  else
    warning "Failed to download cuda-keyring.deb — check that ${DISTRO_TAG} is published by NVIDIA yet."
  fi
}

# ─────────────────────────────────────────────
# GNOME EXTENSIONS
# ─────────────────────────────────────────────
install_gnome_extensions() {
  info "[EXTENSIONS] Installing GNOME extensions"

  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v pipx &>/dev/null; then
    step "Installing pipx"
    try "${APT_INSTALL[@]}" pipx
    try pipx ensurepath
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if ! command -v gext &>/dev/null; then
    step "Installing gnome-extensions-cli via pipx"
    try pipx install gnome-extensions-cli
    export PATH="$HOME/.local/bin:$PATH"
  fi

  # Ubuntu's own AppIndicator extension — disable to let the upstream version take over.
  # (Ubuntu Dock is left enabled — Dash to Dock is no longer installed.)
  if gnome-extensions list 2>/dev/null | grep -q '^ubuntu-appindicators@ubuntu.com$'; then
    step "Disabling Ubuntu AppIndicators in favor of the upstream version"
    try gnome-extensions disable ubuntu-appindicators@ubuntu.com
  fi

  # NOTE: Dash to Dock is NOT installed — we keep Ubuntu Dock (the default,
  # itself a fork of Dash to Dock) and just reconfigure it in apply_settings()
  # to behave as a centered floating dock at the bottom.
  EXTENSIONS=(
    appindicatorsupport@rgcjonas.gmail.com    # AppIndicator (system tray support)
    caffeine@patapon.info                     # Caffeine (prevent suspend)
    clipboard-indicator@tudmotu.com           # Clipboard Indicator (clipboard manager)
    gsconnect@andyholmes.github.io            # GSConnect (KDE Connect for GNOME)
    tilingshell@ferrarodomenico.com           # Tiling Shell
    Vitals@CoreCoding.com                     # Vitals (CPU/RAM/temp/network monitor in panel)
    AlphabeticalAppGrid@stuarthayhurst        # Alphabetical App Grid
  )

  if command -v gext &>/dev/null; then
    for ext in "${EXTENSIONS[@]}"; do
      ext="${ext%%#*}"
      ext="${ext//[[:space:]]/}"
      [[ -z "$ext" ]] && continue
      step "$ext"
      try gext install "$ext"
      try gext enable "$ext"
    done
    ok "Extensions installed. Some may show errors until the next GNOME Shell update."
  else
    warning "gext not available. Install manually via Extension Manager."
    echo "  Required extensions:"
    printf '    - %s\n' "${EXTENSIONS[@]}"
  fi
}

# ─────────────────────────────────────────────
# BLOATWARE REMOVAL
# Run AFTER installing everything to avoid
# breaking dependencies during installation
# ─────────────────────────────────────────────
remove_bloat() {
  info "[CLEANUP] Removing bloatware"
  warning "Run this step AFTER installing everything to avoid dependency issues."

  # Backup the package list before removing anything (recovery aid)
  BACKUP_FILE="$HOME/ubuntu-y2k-packages-before-cleanup-$(date +%Y%m%d-%H%M%S).txt"
  step "Backing up current package list to $BACKUP_FILE"
  if dpkg-query -W -f='${Package}\n' 2>/dev/null | sort > "$BACKUP_FILE"; then
    ok "Backup saved (restore with: sudo apt-get install \$(cat $BACKUP_FILE))."
  else
    warning "Failed to write backup."
  fi

  step "Removing LibreOffice (replaced by FreeOffice)"
  purge_if_installed 'libreoffice*'

  step "Removing default GNOME media players (replaced by VLC)"
  # Ubuntu 26.04 ships Showtime + Decibels as new defaults. Keep cleanup compatible
  # with upgrades from 24.04/25.10 by also removing legacy Totem/Rhythmbox.
  # purge_if_installed silently skips packages that aren't there (e.g. Decibels
  # may not be in the archives yet, Cheese was removed from default installs).
  purge_if_installed \
    showtime \
    decibels \
    totem \
    totem-plugins \
    rhythmbox \
    rhythmbox-plugins \
    gnome-music

  step "Removing default photo/scanner apps replaced by Loupe / Simple Scan"
  purge_if_installed shotwell

  step "Removing default mail client (using Chrome/web mail)"
  purge_if_installed 'thunderbird*'

  step "Removing default torrent client (replaced by Motrix Flatpak)"
  purge_if_installed 'transmission-*'

  step "Removing GNOME Extensions Manager apt app (replaced by Extension Manager Flatpak)"
  purge_if_installed gnome-shell-extension-prefs

  step "Removing Snap Store / App Center (keeping GNOME Software as default store)"
  # On Ubuntu 26.04 the App Center is delivered as a snap named 'snap-store'.
  # We keep gnome-software (installed in [GNOME apps]) as the unified store —
  # it now handles Flatpaks too via gnome-software-plugin-flatpak. snapd itself
  # stays installed in case any other snap is still in use.
  # SAFETY: only remove snap-store if gnome-software is already present —
  # otherwise we'd leave the system with no app store at all (matters if the
  # user runs option [3] standalone without having run [4] first).
  if ! dpkg -s gnome-software &>/dev/null; then
    warning "gnome-software not installed — skipping snap-store removal to avoid"
    warning "leaving the system without any app store. Run option [4] first."
  elif command -v snap &>/dev/null && snap list snap-store &>/dev/null 2>&1; then
    try sudo snap remove --purge snap-store
  fi
  # Defensive: remove any apt-side shim if it exists under either name.
  purge_if_installed ubuntu-software

  step "Removing Firefox snap (replaced by the native .deb from Mozilla PPA)"
  # SAFETY: only remove the snap if the REAL .deb is installed — not just the
  # snap shim. The shim (package: firefox, version: 1:1snap1-*) is also an apt
  # package, so dpkg -s firefox returns 0 for both. We check the version string:
  # the shim always contains 'snap', the real .deb never does.
  # Without this check, a failed .deb install would cause us to remove the snap
  # and leave the user with no browser at all.
  FIREFOX_VER=$(dpkg-query -W -f='${Version}' firefox 2>/dev/null || true)
  if [[ -z "$FIREFOX_VER" ]] || [[ "$FIREFOX_VER" == *snap* ]]; then
    warning "Firefox .deb not installed (snap shim still active) — skipping snap"
    warning "removal to avoid losing the browser. Run option [4] first."
  elif command -v snap &>/dev/null && snap list firefox &>/dev/null 2>&1; then
    try sudo snap remove --purge firefox
  fi

  # NOTE: gnome-system-monitor is no longer installed by default on Ubuntu 26.04
  # (replaced upstream by Resources, which is now the apt default). Nothing to remove.

  step "Removing GNOME games"
  purge_if_installed \
    aisleriot \
    gnome-mahjongg \
    gnome-mines \
    gnome-sudoku \
    gnome-2048

  step "Removing unnecessary apps"
  purge_if_installed \
    cheese \
    gnome-tour \
    gnome-weather \
    gnome-maps \
    gnome-notes \
    foliate \
    paperboy \
    yelp \
    yelp-xsl \
    dconf-editor \
    htop

  step "Cleaning orphan dependencies"
  try sudo apt-get autoremove --purge -y
  try sudo apt-get autoclean -y

  ok "Cleanup complete."
}

# ─────────────────────────────────────────────
# VISUAL SETTINGS & DEFAULT APPS
# ─────────────────────────────────────────────
apply_settings() {
  info "[SETTINGS] Applying GNOME settings and default apps"

  # ── Appearance ──
  try gsettings set org.gnome.desktop.interface icon-theme         'Papirus'
  try gsettings set org.gnome.desktop.interface color-scheme       'prefer-dark'
  try gsettings set org.gnome.desktop.interface clock-show-date    true
  try gsettings set org.gnome.desktop.interface clock-show-seconds true

  # ── Title bar buttons: add Minimize and Maximize (right side) ──
  try gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'

  # ── Desktop icons (DING — Desktop Icons NG) ──
  # Hide the Home folder shortcut on the desktop. Trash and other defaults stay.
  step "Hiding Home icon from the desktop"
  try gsettings set org.gnome.shell.extensions.ding show-home false

  # ── Ubuntu Dock layout — centered floating dock at the bottom ──
  # Ubuntu Dock is a fork of Dash to Dock and shares its schema, so the same
  # keys configure both. We don't replace the dock — we just reshape it:
  #   - dock-position=BOTTOM  → move from the default left side to the bottom
  #   - extend-height=false   → don't span the full screen edge; sit centered
  #     on the visible apps only (the Dash to Dock floating look)
  step "Configuring Ubuntu Dock (bottom, centered, not extended)"
  try gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'
  try gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false

  # ── Dock favorites (Chrome, Files, Text Editor, Terminal, Calculator) ──
  # Note: Ubuntu 26.04 ships Ptyxis as the default terminal (same as Fedora 41+).
  step "Setting dock shortcuts"
  try gsettings set org.gnome.shell favorite-apps \
    "['google-chrome.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Ptyxis.desktop', 'org.gnome.Calculator.desktop']"

  # ── Default browser: Google Chrome ──
  step "Setting Google Chrome as default web browser"
  try xdg-settings set default-web-browser google-chrome.desktop

  # ── Default media player: VLC ──
  # Uses three methods combined for reliability on modern GNOME:
  #   1. xdg-mime  — writes to ~/.config/mimeapps.list
  #   2. gio mime  — GNOME's own tool, overrides gnome-mimeapps.list entries
  #   3. Direct write to mimeapps.list — guarantees persistence across sessions
  step "Setting VLC as default audio and video player"

  if [[ ! -f /usr/share/applications/vlc.desktop ]]; then
    warning "VLC is not installed yet — skipping default media player setup."
    warning "Re-run option [8] after installing VLC (apt: vlc)."
  else
    MEDIA_TYPES=(
    video/mp4
    video/x-matroska
    video/webm
    video/avi
    video/quicktime
    video/x-msvideo
    video/mpeg
    video/x-flv
    video/3gpp
    video/ogg
    audio/mpeg
    audio/ogg
    audio/flac
    audio/x-wav
    audio/aac
    audio/mp4
    audio/x-m4a
    audio/opus
    audio/webm
  )

  for mime in "${MEDIA_TYPES[@]}"; do
    try xdg-mime default vlc.desktop "$mime"
    gio mime "$mime" vlc.desktop 2>/dev/null || true
  done

  # Direct write to mimeapps.list as final guarantee
  MIMEAPPS="$HOME/.config/mimeapps.list"
  mkdir -p "$HOME/.config"

  # Ensure [Default Applications] section exists
  if ! grep -q '^\[Default Applications\]' "$MIMEAPPS" 2>/dev/null; then
    echo '[Default Applications]' >> "$MIMEAPPS"
  fi

  # For each MIME type: remove any existing entry then add VLC
  for mime in "${MEDIA_TYPES[@]}"; do
    sed -i "/^${mime//\//\\/}=/d" "$MIMEAPPS" 2>/dev/null || true
    sed -i "/^\[Default Applications\]/a ${mime}=vlc.desktop" "$MIMEAPPS"
  done

  ok "VLC set as default for audio and video (xdg-mime + gio mime + mimeapps.list)."
  fi

  # ── Chrome: Wayland + touchpad two-finger back/forward gestures ──
  # Ubuntu 26.04 is Wayland-only by default, but the flag is still useful to
  # force native Wayland in Chrome (otherwise it may run under XWayland).
  step "Configuring Chrome for Wayland touchpad gestures"

  FLAGS_FILE="$HOME/.config/chrome-flags.conf"
  mkdir -p "$HOME/.config"
  grep -qxF -- '--ozone-platform=wayland' "$FLAGS_FILE" 2>/dev/null \
    || echo '--ozone-platform=wayland' >> "$FLAGS_FILE"
  grep -qxF -- '--enable-features=TouchpadOverscrollHistoryNavigation' "$FLAGS_FILE" 2>/dev/null \
    || echo '--enable-features=TouchpadOverscrollHistoryNavigation' >> "$FLAGS_FILE"

  DESKTOP_SRC="/usr/share/applications/google-chrome.desktop"
  DESKTOP_DEST="$HOME/.local/share/applications/google-chrome.desktop"
  mkdir -p "$HOME/.local/share/applications"
  if [[ -f "$DESKTOP_SRC" ]]; then
    cp "$DESKTOP_SRC" "$DESKTOP_DEST"
    sed -i '/^Exec=\/usr\/bin\/google-chrome-stable/ s|%U|--ozone-platform=wayland --enable-features=TouchpadOverscrollHistoryNavigation %U|g' "$DESKTOP_DEST"
    ok "Chrome configured for Wayland and touchpad gestures."
  else
    warning "google-chrome.desktop not found — Chrome may not be installed yet. Re-run option [8] after installing Chrome."
  fi

  # ── Wallpaper ──
  step "Downloading and applying wallpaper"
  WALLPAPER_URL="https://www.nasa.gov/wp-content/uploads/2026/04/art002e009288orig.jpg"
  WALLPAPER_PATH="$HOME/Pictures/nasa-wallpaper.jpg"
  mkdir -p "$HOME/Pictures"
  if curl -fsSL "$WALLPAPER_URL" -o "$WALLPAPER_PATH"; then
    try gsettings set org.gnome.desktop.background picture-uri      "file://$WALLPAPER_PATH"
    try gsettings set org.gnome.desktop.background picture-uri-dark "file://$WALLPAPER_PATH"
    try gsettings set org.gnome.desktop.background picture-options  'zoom'
    ok "Wallpaper applied."
  else
    warning "Failed to download wallpaper. Check your connection."
  fi

  ok "Settings applied."
}

# ─────────────────────────────────────────────
# FINAL VERIFICATION
# ─────────────────────────────────────────────
verify_final() {
  info "[VERIFICATION] Checking final system state"

  echo
  echo -e "${BOLD}── Packages that should have been REMOVED ──${NC}"
  REMOVED_CHECK=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E \
    "^libreoffice|^showtime$|^decibels$|^totem$|^totem-plugins$|^rhythmbox$|^gnome-music$|^shotwell$|^thunderbird|^transmission-|^gnome-shell-extension-prefs$|^aisleriot$|^gnome-mahjongg$|^gnome-mines$|^gnome-sudoku$|^cheese$|^gnome-tour$|^gnome-weather$|^gnome-maps$|^gnome-notes$|^foliate$|^paperboy$|^yelp$|^dconf-editor$|^htop$" \
    || true)
  if [[ -z "$REMOVED_CHECK" ]]; then
    ok "No unwanted packages found."
  else
    warning "Still present:"
    echo "$REMOVED_CHECK"
  fi

  echo
  echo -e "${BOLD}── APT packages that should exist ──${NC}"
  dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E \
    "^google-chrome-stable$|^brave-browser$|^firefox$|^vlc$|^audacity$|^darktable$|^handbrake$|^inkscape$|^easyeffects$|^gimp$|^blender$|^steam|^dreamchess$|^nordvpn$|^obs-studio$|^gnome-software$|^papirus-icon-theme$|^softmaker-freeoffice|^solaar$|^timeshift$|^deja-dup$" \
    || warning "Some APT packages may not be installed."

  echo
  echo -e "${BOLD}── Essential codecs ──${NC}"
  if dpkg -s ubuntu-restricted-extras &>/dev/null; then
    ok "ubuntu-restricted-extras installed."
  else
    warning "ubuntu-restricted-extras NOT installed — proprietary codecs may be missing."
  fi
  if dpkg -s libavcodec-extra &>/dev/null; then
    ok "libavcodec-extra installed."
  else
    warning "libavcodec-extra NOT installed."
  fi

  echo
  echo -e "${BOLD}── Default applications ──${NC}"
  BROWSER=$(xdg-settings get default-web-browser 2>/dev/null || echo "not set")
  echo "  Default browser : $BROWSER"
  VIDEO_DEFAULT=$(xdg-mime query default video/mp4 2>/dev/null || echo "not set")
  echo "  Default video   : $VIDEO_DEFAULT"
  AUDIO_DEFAULT=$(xdg-mime query default audio/mpeg 2>/dev/null || echo "not set")
  echo "  Default audio   : $AUDIO_DEFAULT"
  BUTTONS=$(gsettings get org.gnome.desktop.wm.preferences button-layout 2>/dev/null || echo "not set")
  echo "  Title bar btns  : $BUTTONS"
  if [[ "$BROWSER" == *"google-chrome"* ]]; then ok "Chrome is default browser."; else warning "Chrome is NOT the default browser."; fi
  if [[ "$VIDEO_DEFAULT" == *"vlc"* ]];     then ok "VLC is default video player."; else warning "VLC is NOT the default video player."; fi
  if [[ "$AUDIO_DEFAULT" == *"vlc"* ]];     then ok "VLC is default audio player."; else warning "VLC is NOT the default audio player."; fi
  if [[ "$BUTTONS" == *"minimize,maximize"* ]]; then ok "Minimize/Maximize buttons active."; else warning "Minimize/Maximize buttons not set."; fi

  echo
  echo -e "${BOLD}── Installed Flatpaks ──${NC}"
  flatpak list --app --columns=application 2>/dev/null | grep -E \
    "Alpaca|Flatseal|Blanket|Raider|FreeCAD|Upscayl|Shotcut|VideoTrimmer|cameractrls|converseen|nokse22.Exhibit|Minder|Motrix|localsend|PeaZip|Podcasts|Popsicle|Shortwave|sticky|Converter|ExtensionManager|PodmanDesktop" \
    || warning "Some expected Flatpaks may not be installed."

  echo
  echo -e "${BOLD}── NVIDIA GPU ──${NC}"
  if lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -qi nvidia; then
    if dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -qE '^nvidia-driver-[0-9]+$|^nvidia-dkms-[0-9]+$'; then
      ok "NVIDIA driver installed."
      nvidia-smi 2>/dev/null | head -4 || warning "nvidia-smi not available (reboot to load the module)."
      if command -v nvcc &>/dev/null; then
        ok "Full CUDA Toolkit present: $(nvcc --version | grep release)"
      else
        echo "  ℹ CUDA Toolkit (nvcc) not installed — driver-only CUDA support active."
      fi
    else
      warning "NVIDIA GPU detected but driver NOT installed."
      echo "  Install via: Software & Updates → Additional Drivers, or:"
      echo "    sudo ubuntu-drivers install"
    fi
  else
    ok "No NVIDIA GPU (no driver needed)."
  fi

  echo
  echo -e "${BOLD}── GNOME Extensions ──${NC}"
  if command -v gnome-extensions &>/dev/null; then
    gnome-extensions list --enabled 2>/dev/null || true
  else
    warning "gnome-extensions not available."
  fi
}

# ─────────────────────────────────────────────
# RUN EVERYTHING
# Correct order: install everything → remove bloat
# ─────────────────────────────────────────────
run_all() {
  echo
  echo -e "${YELLOW}This will run all steps in the correct order.${NC}"
  echo -e "${CYAN}Order: repos → update → APT pkgs → FreeOffice → Flatpaks → CUDA → Extensions → Remove bloat → Settings${NC}"
  echo

  # Disk space check — full install needs roughly 15+ GB free
  AVAIL_GB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -n "$AVAIL_GB" ]]; then
    echo -e "${BOLD}Free space on /: ${AVAIL_GB} GB${NC}"
    if [[ "$AVAIL_GB" -lt 15 ]]; then
      warning "Less than 15 GB free — full install may run out of space (Steam + Blender + CUDA can easily exceed this)."
      read -rp "Continue anyway? [y/N]: " DISK_CONFIRM
      [[ "${DISK_CONFIRM,,}" != "y" ]] && { warning "Cancelled."; return; }
    fi
  fi

  read -rp "Confirm? [y/N]: " CONFIRM
  [[ "${CONFIRM,,}" != "y" ]] && { warning "Cancelled."; return; }

  # Reset warning counter for clean final summary
  WARN_COUNT=0

  add_repos
  update_system
  install_apt_packages  # Installs everything (including codecs)
  install_freeoffice    # FreeOffice before removing LibreOffice
  install_flatpaks
  install_cuda          # CUDA Toolkit only — driver is user's responsibility
  install_gnome_extensions
  remove_bloat          # Removes LibreOffice and bloat AFTER installing everything
  apply_settings        # Visual settings + default apps
  verify_final

  echo
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo -e "${BOLD}   SETUP SUMMARY${NC}"
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  if [[ "$WARN_COUNT" -eq 0 ]]; then
    ok "Setup complete with no warnings!"
  else
    warning "Setup complete with $WARN_COUNT warning(s) — review the log above."
  fi
  echo "  Full log saved to: $LOG_FILE"
  echo -e "${YELLOW}⚠ Reboot the system to activate all drivers and settings.${NC}"
}

# ─────────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────────
while true; do
  show_menu

  case "$CHOICE" in
    1) run_all ;;
    2) add_repos; update_system ;;
    3) remove_bloat ;;
    4) add_repos; install_apt_packages ;;
    5) install_flatpaks ;;
    6) install_cuda ;;
    7) install_gnome_extensions ;;
    8) apply_settings ;;
    9) verify_final ;;
    0) echo "Exiting."; exit 0 ;;
    r|R) echo "Rebooting..."; sudo reboot ;;
    *) warning "Invalid option." ;;
  esac

  echo
  read -rp "Press ENTER to return to the menu..." _
done
