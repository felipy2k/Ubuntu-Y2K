# 🐧 Ubuntu-Y2K

An interactive post-installation script for **Ubuntu 26.04 LTS** (Resolute Raccoon), optimized for **GNOME 50**.  
Automates repositories, codecs, packages, Flatpaks, GNOME extensions, default apps, dock layout, and visual settings — all through a modular interactive menu.

---

## ⚙️ Requirements

- Ubuntu **26.04 LTS** (fresh install recommended)
- A user account with `sudo` access
- Internet connection
- `git` installed — if not: `sudo apt install git -y`

---

## 🚀 Usage

```bash
git clone https://github.com/felipy2k/Ubuntu-Y2K.git
cd Ubuntu-Y2K
bash ubuntu-y2k.sh
```

---

## 🗂️ Menu

| Option | Action |
|--------|--------|
| `[1]` | ✅ **Run EVERYTHING** (recommended) |
| `[2]` | 🔄 Update system only |
| `[3]` | 🗑️ Remove bloatware only |
| `[4]` | 📦 Install APT packages only |
| `[5]` | 📦 Install Flatpaks only |
| `[6]` | 🎮 Install CUDA Toolkit only (driver must already exist) |
| `[7]` | 🧩 Install GNOME extensions only |
| `[8]` | 🎨 Apply visual settings only |
| `[9]` | 🔍 Final verification |
| `[r]` | 🔁 Reboot |

---

## 📦 What Gets Installed

### 🌐 Repositories
- Enables `universe` and `multiverse` components
- **Google Chrome** official repo (native `.deb`)
- **Brave Browser** official repo (native `.deb`)
- **Mozilla Team PPA** — native Firefox `.deb` (replaces Ubuntu's snap shim)

---

### 💻 APT Packages

| Category | Apps |
|----------|------|
| 🌐 Browsers | Google Chrome, Brave, Firefox (native .deb), Tor Browser |
| 🎬 Multimedia | VLC, Audacity, Darktable, HandBrake, EasyEffects, OBS Studio |
| 🎨 Graphics / 3D | GIMP, Inkscape, Blender |
| 🎮 Gaming | Steam |
| 🖥️ GNOME Apps | Tweaks, Boxes, Backups, Calculator, Calendar, Snapshot, Connections, Contacts, Simple Scan, Disk Utility, Text Editor, Font Viewer, Software, Clocks, Logs, Evince, Loupe |
| 🔧 Utilities | Timeshift, Solaar, Dreamchess, lm-sensors, InputLeap |
| 🔒 VPN | NordVPN (official installer) |
| 📄 Office | FreeOffice 2024 (replaces LibreOffice) |

---

### 🎵 Multimedia Codecs
- `ubuntu-restricted-extras` — libavcodec-extra, lame, MS Core Fonts, unrar
- Full GStreamer plugin stack (base, good, bad, ugly, libav, vaapi)
- `ffmpeg`
- Hardware VA-API / VDPAU drivers — auto-detected per GPU (AMD / Intel)

---

### 🗃️ Flatpaks (from Flathub)

| Category | Apps |
|----------|------|
| 🔧 System | Extension Manager, Flatseal, PeaZip, Popsicle, Raider, LocalSend, Switcheroo, Podman Desktop |
| 🎬 Multimedia | Shotcut, Video Trimmer, Camera Controls, Converseen |
| 🚀 Productivity | FreeCAD, Upscayl, Exhibit, Minder, Motrix |
| 🎶 Entertainment | Blanket, Shortwave, Podcasts, Color Picker, Sticky Notes, Alpaca |

---

### 🧩 GNOME Extensions

Installed via `gnome-extensions-cli`:

| Extension | Description |
|-----------|-------------|
| AppIndicator Support | System tray icon support |
| Caffeine | Prevent automatic suspend |
| Clipboard Indicator | Clipboard history manager |
| GSConnect | KDE Connect integration for GNOME |
| Tiling Shell | Window tiling manager |
| Vitals | CPU / RAM / temp / network monitor in the top bar |
| Alphabetical App Grid | Sort the app grid alphabetically |

---

### 🎨 Visual Settings

- 🌑 Dark mode
- 🖼️ Papirus icon theme
- 🌌 NASA wallpaper
- 🪟 Minimize + Maximize title bar buttons
- 🏠 Home icon hidden from desktop
- 🞋 Ubuntu Dock → bottom, centered, floating (not extended)
- 📌 Dock shortcuts: Chrome · Files · Text Editor · Terminal · Calculator
- 🌐 Google Chrome as default browser (Wayland + touchpad gesture flags)
- 🎬 VLC as default audio and video player
- 🕐 Clock shows date and seconds

---

### 🗑️ Bloatware Removed

| Category | Removed |
|----------|---------|
| 📄 Office | LibreOffice (replaced by FreeOffice) |
| 🎬 Media players | Showtime, Decibels, Totem, Rhythmbox, GNOME Music |
| 📷 Photos | Shotwell |
| 📧 Mail | Thunderbird |
| 📥 Torrents | Transmission |
| 🏪 App stores | Snap Store / App Center (replaced by GNOME Software + Flatpak) |
| 🦊 Browser | Firefox snap (replaced by Mozilla PPA .deb) |
| 🎮 Games | Aisleriot, Mahjongg, Mines, Sudoku, 2048 |
| 🗃️ Misc | Cheese, GNOME Tour, Weather, Maps, Notes, Foliate, Paperboy, Yelp, dconf-editor, htop |

---

### 🎮 CUDA Toolkit (optional)

The script intentionally does **not** install the NVIDIA driver — Ubuntu handles that natively:

- ✅ **"Install third-party software"** checkbox during Ubuntu setup
- ✅ **Software & Updates → Additional Drivers** tab
- ✅ CLI: `sudo ubuntu-drivers install`

Option `[6]` installs the full **CUDA Toolkit** (nvcc, cuBLAS, headers) on top of an already-installed driver, using the official NVIDIA repo — with a pin to prevent NVIDIA's repo from overriding Ubuntu's driver packages.

---

## 📝 Important Notes

**Re-running individual steps**  
If the script fails partway through (e.g. no internet connection at the time), each menu option can be re-run independently. For example, after fixing a DNS issue, just run `[4]` and `[5]` again — already-installed packages are skipped automatically.

**Firefox .deb vs snap**  
The Mozilla Team PPA is added with `Pin-Priority: 1001` to ensure the `.deb` always wins over Ubuntu's transitional snap shim, including future `apt upgrade` runs.

**Snap Store removal safety**  
The script only removes `snap-store` if `gnome-software` is already installed, so you're never left without an app store.

**Log and backup**  
- Full output saved to `~/ubuntu-y2k-TIMESTAMP.log`  
- Package list snapshot saved to `~/ubuntu-y2k-packages-before-cleanup-*.txt` before any removals

**Reboot required**  
Always reboot after running the script to activate all drivers, extensions, and settings.

---

## 📄 License

MIT
