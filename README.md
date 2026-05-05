# Ubuntu-Y2K

> Custom post-install setup script for **Ubuntu 26.04 LTS** (Resolute Raccoon).  
> Automates repos, packages, codecs, Flatpaks, GNOME extensions and visual settings — with a menu-driven interface so you can run everything at once or step by step.

---

## Requirements

- Ubuntu 26.04 LTS (fresh install recommended)
- Regular user account (do **not** run as root)
- Internet connection
- `git` installed — if not: `sudo apt install git -y`

---

## Usage

```bash
git clone https://github.com/felipy2k/Ubuntu-Y2K.git
cd Ubuntu-Y2K
bash ubuntu-y2k.sh
```

---

## Menu

| Option | Action |
|--------|--------|
| `[1]` | **Run EVERYTHING** (recommended) |
| `[2]` | Update system only |
| `[3]` | Remove bloatware only |
| `[4]` | Install APT packages only |
| `[5]` | Install Flatpaks only |
| `[6]` | Install CUDA Toolkit only (driver must already exist) |
| `[7]` | Install GNOME extensions only |
| `[8]` | Apply visual settings only |
| `[9]` | Final verification |
| `[r]` | Reboot |

---

## What it does

### Repositories
- Enables `universe` and `multiverse` components
- Adds **Google Chrome** official repo (`.deb`)
- Adds **Brave Browser** official repo (`.deb`)
- Adds **Mozilla Team PPA** for native Firefox `.deb` (replaces Ubuntu's snap shim)

### APT Packages

| Category | Packages |
|----------|----------|
| Browsers | Google Chrome, Brave, Firefox (native .deb), Tor Browser |
| Multimedia | VLC, Audacity, Darktable, HandBrake, EasyEffects, OBS Studio |
| Graphics / 3D | GIMP, Inkscape, Blender |
| Gaming | Steam |
| GNOME Apps | Tweaks, Boxes, Backups, Calculator, Calendar, Snapshot, Connections, Contacts, Simple Scan, Disk Utility, Text Editor, Font Viewer, Software, Clocks, Logs, Evince, Loupe |
| Utilities | Timeshift, Solaar, Dreamchess, lm-sensors |
| VPN | NordVPN (official installer) |
| Office | FreeOffice 2024 (replaces LibreOffice) |

### Multimedia Codecs
- `ubuntu-restricted-extras` (libavcodec-extra, lame, MS fonts, unrar)
- Full GStreamer plugin stack (base, good, bad, ugly, libav, vaapi)
- `ffmpeg`
- Hardware VA-API/VDPAU drivers — auto-detected (AMD / Intel)

### Flatpaks (from Flathub)

| Category | Apps |
|----------|------|
| System | Extension Manager, Flatseal, PeaZip, Popsicle, Raider, LocalSend, Switcheroo, Podman Desktop |
| Multimedia | Shotcut, Video Trimmer, Camera Controls, Converseen |
| Productivity | FreeCAD, Upscayl, Exhibit, Minder, Motrix |
| Entertainment | Blanket, Shortwave, Podcasts, Color Picker, Sticky Notes, Alpaca |

### GNOME Extensions
Installed via `gnome-extensions-cli`:
- AppIndicator Support
- Caffeine
- Clipboard Indicator
- GSConnect
- Tiling Shell
- Vitals

### Visual Settings
- Dark mode
- Papirus icon theme
- NASA wallpaper
- Minimize + Maximize title bar buttons
- Home icon hidden from desktop
- Ubuntu Dock → bottom, centered, floating (not extended)
- Dock shortcuts: Chrome · Files · Text Editor · Terminal · Calculator
- Google Chrome as default browser (with Wayland + touchpad gesture flags)
- VLC as default audio and video player
- Clock shows date and seconds

### Bloatware Removed
- LibreOffice (replaced by FreeOffice)
- Showtime, Decibels, Totem, Rhythmbox, GNOME Music (replaced by VLC)
- Shotwell, Thunderbird, Transmission
- Snap Store / App Center (replaced by GNOME Software + Flatpak)
- Firefox snap (replaced by Mozilla PPA .deb)
- GNOME games (Aisleriot, Mahjongg, Mines, Sudoku, 2048)
- Cheese, GNOME Tour, Weather, Maps, Notes, Foliate, Paperboy, Yelp, dconf-editor, htop

### CUDA Toolkit (optional)
The script does **not** install the NVIDIA driver — Ubuntu handles that natively via:
- The "Install third-party software" checkbox during setup
- **Software & Updates → Additional Drivers** tab
- CLI: `sudo ubuntu-drivers install`

Option `[6]` installs the full **CUDA Toolkit** (nvcc, cuBLAS, headers) on top of an already-installed driver, using the official NVIDIA repo — with a pin to prevent NVIDIA's repo from overriding Ubuntu's driver packages.

---

## Notes

- The script runs as a regular user — `sudo` is called internally only where needed
- All output is saved to `~/ubuntu-y2k-TIMESTAMP.log`
- A package list backup is saved before any removals (`~/ubuntu-y2k-packages-before-cleanup-*.txt`)
- Options can be re-run individually after a failed first attempt (e.g. if run without internet)
- Reboot after running to activate all drivers and settings

---

## License

MIT
