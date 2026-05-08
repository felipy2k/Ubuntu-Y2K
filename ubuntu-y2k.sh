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

WARN_COUNT=0

# Robust try() — returns 0 always so failures never abort the script
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

# Purge only packages that are actually installed.
# apt-get purge aborts the whole transaction on a single missing package,
# so we filter first. Supports globs (e.g. 'libreoffice*').
purge_if_installed() {
  local pkgs
  pkgs=$(dpkg-query -W -f='${Package}\n' "$@" 2>/dev/null || true)
  if [[ -n "$pkgs" ]]; then
    # shellcheck disable=SC2086
    try sudo apt-get purge -y $pkgs
  fi
}

# Wait for snapd / unattended-upgrades to release the apt lock before proceeding.
# Without this, apt-get fails with "Could not get lock /var/lib/dpkg/lock-frontend".
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
      step "Waiting for apt/dpkg lock (snapd may be refreshing)..."
    fi
    sleep 2
    (( waited += 2 ))
    if [[ $waited -ge 120 ]]; then
      warning "apt lock held for over 2 minutes — forcing release."
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

# Detect Ubuntu version from /etc/os-release
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  UBUNTU_VER="${VERSION_ID:-unknown}"
else
  UBUNTU_VER="unknown"
fi

export DEBIAN_FRONTEND=noninteractive

# --allow-downgrades is required to replace the Firefox snap shim
# (version 1:1snap1-* whose epoch makes it appear "newer" than the Mozilla PPA .deb)
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

  # software-properties-common provides add-apt-repository — must be installed first
  step "Installing prerequisites"
  try sudo apt-get update
  try "${APT_INSTALL[@]}" curl wget gnupg ca-certificates apt-transport-https \
    software-properties-common

  step "Enabling universe and multiverse"
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

  step "Mozilla Team PPA (native Firefox .deb)"
  # grep handles both legacy 'deb ...' and DEB822 '.sources' formats
  if ! grep -rq 'mozillateam' /etc/apt/sources.list.d/ 2>/dev/null; then
    try sudo add-apt-repository -y ppa:mozillateam/ppa
  fi
  # Priority 1001 forces the .deb to win over the snap shim's '1:' epoch
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
  try sudo apt-get upgrade -y --allow-downgrades
  try sudo apt-get full-upgrade -y --allow-downgrades
}

# ─────────────────────────────────────────────
# CODECS
# ─────────────────────────────────────────────
install_codecs() {
  info "[CODECS] Installing multimedia codecs"

  step "Pre-accepting Microsoft EULAs"
  echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
    | sudo debconf-set-selections
  echo "ttf-mscorefonts-installer msttcorefonts/present-mscorefonts-eula note" \
    | sudo debconf-set-selections

  step "ubuntu-restricted-extras (codecs, MS fonts, lame, libavcodec-extra)"
  try "${APT_INSTALL[@]}" ubuntu-restricted-extras

  step "gstreamer1.0-vaapi + ffmpeg (not included in restricted-extras)"
  try "${APT_INSTALL[@]}" gstreamer1.0-vaapi ffmpeg

  step "Hardware VA-API/VDPAU (auto-detected)"
  if lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -qi 'amd\|radeon\|ati'; then
    step "AMD GPU — mesa VA-API/VDPAU drivers"
    try "${APT_INSTALL[@]}" mesa-va-drivers mesa-vdpau-drivers vainfo vdpauinfo
  fi
  if lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -qi 'intel'; then
    step "Intel GPU — intel-media-va-driver-non-free"
    try "${APT_INSTALL[@]}" intel-media-va-driver-non-free i965-va-driver-shaders vainfo
  fi
}

# ─────────────────────────────────────────────
# APT PACKAGES
# Install everything BEFORE removing anything
# ─────────────────────────────────────────────
install_apt_packages() {
  info "[APT] Installing APT packages"

  install_codecs

  step "Base tools"
  try "${APT_INSTALL[@]}" \
    git wget curl fastfetch pipx papirus-icon-theme \
    build-essential dkms pciutils

  step "Flatpak + GNOME Software plugin"
  try "${APT_INSTALL[@]}" flatpak gnome-software-plugin-flatpak

  step "Browsers (Chrome, Brave, Tor)"
  # Firefox is intentionally separate — a failure here must not abort Chrome/Brave
  try "${APT_INSTALL[@]}" google-chrome-stable brave-browser torbrowser-launcher

  step "Firefox (.deb from Mozilla Team PPA)"
  # --allow-downgrades in APT_INSTALL handles the '1:' epoch of the snap shim
  try "${APT_INSTALL[@]}" firefox

  step "Multimedia"
  try "${APT_INSTALL[@]}" vlc audacity darktable handbrake easyeffects obs-studio

  step "Graphics / 3D"
  try "${APT_INSTALL[@]}" gimp inkscape blender

  step "Gaming"
  try "${APT_INSTALL[@]}" steam-installer

  step "GNOME apps"
  # Ptyxis is the default terminal on Ubuntu 26.04 — gnome-terminal not needed
  try "${APT_INSTALL[@]}" \
    gnome-tweaks baobab nautilus deja-dup gnome-boxes gnome-calculator \
    gnome-calendar gnome-snapshot gnome-characters gnome-connections \
    gnome-contacts simple-scan gnome-disk-utility gnome-text-editor \
    gnome-font-viewer gnome-color-manager gnome-software gnome-clocks \
    gnome-logs evince loupe

  step "Utilities"
  try "${APT_INSTALL[@]}" timeshift solaar dreamchess lm-sensors

  step "InputLeap (share mouse/keyboard across computers)"
  # input-leap may not be in 26.04 archives yet — fall back to Flatpak if absent
  if apt-cache show input-leap &>/dev/null; then
    try "${APT_INSTALL[@]}" input-leap
  else
    warning "input-leap not in apt — installing via Flatpak as fallback."
    if ! command -v flatpak &>/dev/null; then
      try "${APT_INSTALL[@]}" flatpak gnome-software-plugin-flatpak
    fi
    try flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo
    try flatpak install -y flathub io.github.input_leap.InputLeap
  fi

  step "NordVPN"
  if ! command -v nordvpn &>/dev/null; then
    if curl -sSf --max-time 10 -o /dev/null https://downloads.nordcdn.com/apps/linux/install.sh 2>/dev/null; then
      if sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh) -p nordvpn-gui; then
        ok "NordVPN installed."
        try sudo systemctl enable --now nordvpnd
        try sudo usermod -aG nordvpn "$USER"
        warning "Group membership requires logout/reboot. For immediate use: newgrp nordvpn"
      else
        warning "NordVPN installer failed. Try manually: sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)"
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
# ─────────────────────────────────────────────
install_freeoffice() {
  info "[FREEOFFICE] Installing FreeOffice 2024"
  if ! curl -fsSL --max-time 5 -o /dev/null https://softmaker.net/down/install-softmaker-freeoffice-2024.sh 2>/dev/null; then
    warning "Cannot reach softmaker.net — skipping. Run option [4] later or install manually:"
    echo "  curl -fsSL https://softmaker.net/down/install-softmaker-freeoffice-2024.sh | sudo bash"
    return
  fi
  if curl -fsSL https://softmaker.net/down/install-softmaker-freeoffice-2024.sh | sudo bash; then
    ok "FreeOffice installed."
  else
    warning "FreeOffice failed. Try: curl -fsSL https://softmaker.net/down/install-softmaker-freeoffice-2024.sh | sudo bash"
  fi
}

# ─────────────────────────────────────────────
# FLATPAKS
# ─────────────────────────────────────────────
install_flatpaks() {
  info "[FLATPAK] Installing apps from Flathub"

  if ! command -v flatpak &>/dev/null; then
    step "flatpak not found — installing now"
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
    com.github.ADBeveridge.Raider           # File shredder
    org.localsend.localsend_app             # LocalSend (LAN file sharing)
    io.gitlab.adhami3310.Converter          # Switcheroo (image format converter)
    io.podman_desktop.PodmanDesktop         # Podman Desktop

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
    net.agalwood.Motrix                     # Download manager

    # Entertainment / Sound / Other
    com.rafaelmardojai.Blanket              # Ambient sounds
    de.haeckerfelix.Shortwave               # Internet radio
    org.gnome.Podcasts                      # Podcasts
    nl.hjdskes.gcolor3                      # Color picker
    com.vixalien.sticky                     # Sticky notes
    com.jeffser.Alpaca                      # Local LLM
  )

  for app in "${FLATPAK_IDS[@]}"; do
    app="${app%%#*}"
    app="${app//[[:space:]]/}"
    [[ -z "$app" ]] && continue
    step "$app"
    try flatpak install -y flathub "$app"
  done
}

# ─────────────────────────────────────────────
# CUDA TOOLKIT
# Script does NOT install the NVIDIA driver —
# use the "Install third-party software" checkbox
# during Ubuntu setup, or: sudo ubuntu-drivers install
# ─────────────────────────────────────────────
install_cuda() {
  info "[CUDA] CUDA Toolkit installation"

  if ! lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -qi nvidia; then
    warning "No NVIDIA GPU detected. Skipping."
    return
  fi

  GPU_INFO="$(lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -i nvidia | head -1)"
  ok "NVIDIA GPU: $GPU_INFO"

  if ! dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -qE '^nvidia-driver-[0-9]+$'; then
    warning "No NVIDIA driver detected. Install it first via:"
    echo "    1. Software & Updates → Additional Drivers"
    echo "    2. CLI: sudo ubuntu-drivers install"
    echo
    read -rp "  Continue anyway? [y/N]: " NO_DRIVER_CONFIRM
    [[ "${NO_DRIVER_CONFIRM,,}" != "y" ]] && { warning "CUDA cancelled."; return; }
  else
    ok "NVIDIA driver present."
  fi

  echo
  echo -e "${BOLD}── Full CUDA Toolkit (nvcc, cuBLAS, headers) ──${NC}"
  echo "The installed driver already provides CUDA runtime for apps."
  echo "This step adds the build-time toolkit (nvcc) — only needed for compiling CUDA code."
  read -rp "  Install cuda-toolkit? [y/N]: " CUDA_CONFIRM
  [[ "${CUDA_CONFIRM,,}" != "y" ]] && { ok "Skipped."; return; }

  DISTRO_TAG="ubuntu${UBUNTU_VER//./}"
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) CUDA_ARCH="x86_64" ;;
    arm64) CUDA_ARCH="sbsa"   ;;
    *)     warning "Unsupported arch: $ARCH"; return ;;
  esac

  KEYRING_DEB="/tmp/cuda-keyring.deb"
  if curl -fsSL --max-time 30 \
      "https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO_TAG}/${CUDA_ARCH}/cuda-keyring_1.1-1_all.deb" \
      -o "$KEYRING_DEB"; then
    try sudo dpkg -i "$KEYRING_DEB"
    rm -f "$KEYRING_DEB"
    try sudo apt-get update

    # Pin prevents NVIDIA repo from overriding Ubuntu's driver packages
    sudo tee /etc/apt/preferences.d/cuda-pin-nvidia-driver > /dev/null <<'EOF'
Package: nvidia-driver-* nvidia-dkms-* nvidia-kernel-* libnvidia-* nvidia-utils-* nvidia-compute-utils-* xserver-xorg-video-nvidia-*
Pin: origin developer.download.nvidia.com
Pin-Priority: -1
EOF

    try "${APT_INSTALL[@]}" cuda-toolkit
    ok "CUDA Toolkit installed. Run 'nvcc --version' after rebooting."
  else
    warning "Failed to download cuda-keyring.deb — ${DISTRO_TAG} may not be published yet."
  fi
}

# ─────────────────────────────────────────────
# GNOME EXTENSIONS
# ─────────────────────────────────────────────
install_gnome_extensions() {
  info "[EXTENSIONS] Installing GNOME extensions"

  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v pipx &>/dev/null; then
    try "${APT_INSTALL[@]}" pipx
    try pipx ensurepath
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if ! command -v gext &>/dev/null; then
    try pipx install gnome-extensions-cli
    export PATH="$HOME/.local/bin:$PATH"
  fi

  # Disable Ubuntu's built-in AppIndicator to avoid conflict with upstream version
  if gnome-extensions list 2>/dev/null | grep -q '^ubuntu-appindicators@ubuntu.com$'; then
    step "Disabling ubuntu-appindicators in favor of upstream"
    try gnome-extensions disable ubuntu-appindicators@ubuntu.com
  fi

  # Ubuntu Dock is kept (not replaced by Dash to Dock)
  # It is reconfigured in apply_settings() to float centered at the bottom
  EXTENSIONS=(
    appindicatorsupport@rgcjonas.gmail.com    # AppIndicator
    caffeine@patapon.info                     # Caffeine
    clipboard-indicator@tudmotu.com           # Clipboard Indicator
    gsconnect@andyholmes.github.io            # GSConnect
    tilingshell@ferrarodomenico.com           # Tiling Shell
    Vitals@CoreCoding.com                     # Vitals
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
    ok "Extensions installed."
  else
    warning "gext not available — install manually via Extension Manager."
    printf '    - %s\n' "${EXTENSIONS[@]}"
  fi
}

# ─────────────────────────────────────────────
# BLOATWARE REMOVAL
# Run AFTER installing everything
# ─────────────────────────────────────────────
remove_bloat() {
  info "[CLEANUP] Removing bloatware"
  warning "Run this step AFTER installing everything to avoid dependency issues."

  BACKUP_FILE="$HOME/ubuntu-y2k-packages-before-cleanup-$(date +%Y%m%d-%H%M%S).txt"
  dpkg-query -W -f='${Package}\n' 2>/dev/null | sort > "$BACKUP_FILE" \
    && ok "Package backup: $BACKUP_FILE"

  step "LibreOffice (replaced by FreeOffice)"
  purge_if_installed 'libreoffice*'

  step "Default media players (replaced by VLC)"
  purge_if_installed showtime decibels totem totem-plugins \
    rhythmbox rhythmbox-plugins gnome-music

  step "Shotwell (replaced by Loupe)"
  purge_if_installed shotwell

  step "Thunderbird"
  purge_if_installed 'thunderbird*'

  step "Transmission (replaced by Motrix)"
  purge_if_installed 'transmission-*'

  step "GNOME Extensions apt app (replaced by Extension Manager Flatpak)"
  purge_if_installed gnome-shell-extension-prefs

  step "Snap Store / App Center (replaced by GNOME Software)"
  if ! dpkg -s gnome-software &>/dev/null; then
    warning "gnome-software not installed — skipping snap-store removal. Run [4] first."
  elif command -v snap &>/dev/null && snap list snap-store &>/dev/null 2>&1; then
    try sudo snap remove --purge snap-store
  fi
  purge_if_installed ubuntu-software

  step "Firefox snap (replaced by Mozilla PPA .deb)"
  # Check version string — snap shim always contains 'snap', real .deb never does
  FIREFOX_VER=$(dpkg-query -W -f='${Version}' firefox 2>/dev/null || true)
  if [[ -z "$FIREFOX_VER" ]] || [[ "$FIREFOX_VER" == *snap* ]]; then
    warning "Firefox .deb not installed (snap shim still active) — skipping snap removal."
    warning "Run option [4] first to install the .deb from Mozilla PPA."
  elif command -v snap &>/dev/null && snap list firefox &>/dev/null 2>&1; then
    try sudo snap remove --purge firefox
  fi

  step "GNOME games"
  purge_if_installed aisleriot gnome-mahjongg gnome-mines gnome-sudoku gnome-2048

  step "Unnecessary apps"
  purge_if_installed cheese gnome-tour gnome-weather gnome-maps gnome-notes \
    foliate paperboy yelp yelp-xsl dconf-editor htop

  step "Orphan cleanup"
  try sudo apt-get autoremove --purge -y
  try sudo apt-get autoclean -y

  ok "Cleanup complete."
}

# ─────────────────────────────────────────────
# VISUAL SETTINGS & DEFAULT APPS
# ─────────────────────────────────────────────
apply_settings() {
  info "[SETTINGS] Applying GNOME settings and default apps"

  try gsettings set org.gnome.desktop.interface icon-theme         'Papirus'
  try gsettings set org.gnome.desktop.interface color-scheme       'prefer-dark'
  try gsettings set org.gnome.desktop.interface clock-show-date    true
  try gsettings set org.gnome.desktop.interface clock-show-seconds true
  try gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'

  step "Hiding Home icon from desktop"
  try gsettings set org.gnome.shell.extensions.ding show-home false

  step "Ubuntu Dock — bottom, centered, floating"
  try gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'
  try gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false

  step "Dock shortcuts"
  try gsettings set org.gnome.shell favorite-apps \
    "['google-chrome.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Ptyxis.desktop', 'org.gnome.Calculator.desktop']"

  step "Google Chrome as default browser"
  try xdg-settings set default-web-browser google-chrome.desktop

  step "VLC as default audio and video player"
  if [[ ! -f /usr/share/applications/vlc.desktop ]]; then
    warning "VLC not installed — skipping. Re-run [8] after [4]."
  else
    MEDIA_TYPES=(
      video/mp4 video/x-matroska video/webm video/avi video/quicktime
      video/x-msvideo video/mpeg video/x-flv video/3gpp video/ogg
      audio/mpeg audio/ogg audio/flac audio/x-wav audio/aac
      audio/mp4 audio/x-m4a audio/opus audio/webm
    )
    for mime in "${MEDIA_TYPES[@]}"; do
      try xdg-mime default vlc.desktop "$mime"
      gio mime "$mime" vlc.desktop 2>/dev/null || true
    done

    MIMEAPPS="$HOME/.config/mimeapps.list"
    mkdir -p "$HOME/.config"
    grep -q '^\[Default Applications\]' "$MIMEAPPS" 2>/dev/null \
      || echo '[Default Applications]' >> "$MIMEAPPS"
    for mime in "${MEDIA_TYPES[@]}"; do
      sed -i "/^${mime//\//\\/}=/d" "$MIMEAPPS" 2>/dev/null || true
      sed -i "/^\[Default Applications\]/a ${mime}=vlc.desktop" "$MIMEAPPS"
    done
    ok "VLC set as default."
  fi

  step "Chrome — Wayland + touchpad gestures"
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
    ok "Chrome configured for Wayland."
  else
    warning "google-chrome.desktop not found — re-run [8] after [4]."
  fi

  step "Wallpaper"
  WALLPAPER_PATH="$HOME/Pictures/nasa-wallpaper.jpg"
  mkdir -p "$HOME/Pictures"
  if curl -fsSL "https://www.nasa.gov/wp-content/uploads/2026/04/art002e009288orig.jpg" \
      -o "$WALLPAPER_PATH"; then
    try gsettings set org.gnome.desktop.background picture-uri      "file://$WALLPAPER_PATH"
    try gsettings set org.gnome.desktop.background picture-uri-dark "file://$WALLPAPER_PATH"
    try gsettings set org.gnome.desktop.background picture-options  'zoom'
    ok "Wallpaper applied."
  else
    warning "Failed to download wallpaper."
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
    "^libreoffice|^showtime$|^decibels$|^totem$|^rhythmbox$|^gnome-music$|^shotwell$|\
^thunderbird|^transmission-|^gnome-shell-extension-prefs$|^aisleriot$|^gnome-mahjongg$|\
^gnome-mines$|^gnome-sudoku$|^cheese$|^gnome-tour$|^gnome-weather$|^gnome-maps$|\
^gnome-notes$|^foliate$|^paperboy$|^yelp$|^dconf-editor$|^htop$" || true)
  if [[ -z "$REMOVED_CHECK" ]]; then
    ok "No unwanted packages found."
  else
    warning "Still present:"; echo "$REMOVED_CHECK"
  fi

  echo
  echo -e "${BOLD}── APT packages ──${NC}"
  dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E \
    "^google-chrome-stable$|^brave-browser$|^firefox$|^vlc$|^audacity$|^darktable$|\
^handbrake$|^inkscape$|^easyeffects$|^gimp$|^blender$|^steam|^dreamchess$|^nordvpn$|\
^obs-studio$|^gnome-software$|^papirus-icon-theme$|^softmaker-freeoffice|^solaar$|\
^timeshift$|^deja-dup$" || warning "Some APT packages may not be installed."

  echo
  echo -e "${BOLD}── Codecs ──${NC}"
  dpkg -s ubuntu-restricted-extras &>/dev/null \
    && ok "ubuntu-restricted-extras installed." \
    || warning "ubuntu-restricted-extras NOT installed."
  dpkg -s libavcodec-extra &>/dev/null \
    && ok "libavcodec-extra installed." \
    || warning "libavcodec-extra NOT installed."

  echo
  echo -e "${BOLD}── Default apps ──${NC}"
  BROWSER=$(xdg-settings get default-web-browser 2>/dev/null || echo "not set")
  VIDEO=$(xdg-mime query default video/mp4 2>/dev/null || echo "not set")
  AUDIO=$(xdg-mime query default audio/mpeg 2>/dev/null || echo "not set")
  BUTTONS=$(gsettings get org.gnome.desktop.wm.preferences button-layout 2>/dev/null || echo "not set")
  echo "  Browser : $BROWSER"
  echo "  Video   : $VIDEO"
  echo "  Audio   : $AUDIO"
  echo "  Buttons : $BUTTONS"
  [[ "$BROWSER" == *"google-chrome"* ]] && ok "Chrome is default." || warning "Chrome NOT default."
  [[ "$VIDEO" == *"vlc"* ]]            && ok "VLC is default video." || warning "VLC NOT default video."
  [[ "$AUDIO" == *"vlc"* ]]            && ok "VLC is default audio." || warning "VLC NOT default audio."
  [[ "$BUTTONS" == *"minimize,maximize"* ]] && ok "Min/Max buttons active." || warning "Min/Max buttons not set."

  echo
  echo -e "${BOLD}── Flatpaks ──${NC}"
  flatpak list --app --columns=application 2>/dev/null | grep -E \
    "Alpaca|Flatseal|Blanket|Raider|FreeCAD|Upscayl|Shotcut|VideoTrimmer|\
cameractrls|converseen|Exhibit|Minder|Motrix|localsend|PeaZip|Podcasts|\
Popsicle|Shortwave|sticky|Converter|ExtensionManager|PodmanDesktop" \
    || warning "Some Flatpaks may not be installed."

  echo
  echo -e "${BOLD}── NVIDIA ──${NC}"
  if lspci -d ::0300 -d ::0302 -d ::0380 2>/dev/null | grep -qi nvidia; then
    if dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -qE '^nvidia-driver-[0-9]+$'; then
      ok "NVIDIA driver installed."
      nvidia-smi 2>/dev/null | head -4 || warning "nvidia-smi unavailable — reboot needed."
      command -v nvcc &>/dev/null \
        && ok "CUDA Toolkit: $(nvcc --version | grep release)" \
        || echo "  ℹ Driver-only CUDA (no nvcc)."
    else
      warning "NVIDIA GPU found but driver NOT installed."
      echo "  → sudo ubuntu-drivers install"
    fi
  else
    ok "No NVIDIA GPU."
  fi

  echo
  echo -e "${BOLD}── GNOME Extensions ──${NC}"
  command -v gnome-extensions &>/dev/null \
    && gnome-extensions list --enabled 2>/dev/null \
    || warning "gnome-extensions not available."
}

# ─────────────────────────────────────────────
# RUN EVERYTHING
# ─────────────────────────────────────────────
run_all() {
  echo
  echo -e "${YELLOW}This will run all steps in the correct order.${NC}"
  echo -e "${CYAN}repos → update → APT → FreeOffice → Flatpaks → CUDA → Extensions → Bloat removal → Settings${NC}"
  echo

  AVAIL_GB=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -n "$AVAIL_GB" ]]; then
    echo -e "${BOLD}Free space on /: ${AVAIL_GB} GB${NC}"
    if [[ "$AVAIL_GB" -lt 15 ]]; then
      warning "Less than 15 GB free — Steam + Blender + CUDA can exceed this."
      read -rp "Continue anyway? [y/N]: " DISK_CONFIRM
      [[ "${DISK_CONFIRM,,}" != "y" ]] && { warning "Cancelled."; return; }
    fi
  fi

  read -rp "Confirm? [y/N]: " CONFIRM
  [[ "${CONFIRM,,}" != "y" ]] && { warning "Cancelled."; return; }

  WARN_COUNT=0

  add_repos
  update_system
  install_apt_packages
  install_freeoffice
  install_flatpaks
  install_cuda
  install_gnome_extensions
  remove_bloat
  apply_settings
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
  echo "  Log: $LOG_FILE"
  echo -e "${YELLOW}⚠ Reboot to activate all drivers and settings.${NC}"
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
