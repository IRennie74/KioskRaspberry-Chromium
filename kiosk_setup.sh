#!/bin/bash

# ============================================================================
#  kiosk_setup.sh
#  Raspberry Pi Kiosk Display Setup
#
#  Interactive setup for a Chromium kiosk on Raspberry Pi OS (Wayland/labwc).
#  Tested on Raspberry Pi OS / Debian-based systems.
#
#  Do NOT run as root. Run as a regular user with sudo privileges.
#
#  Features:
#    - Wayland/labwc compositor with greetd auto-login
#    - Chromium kiosk autostart (optional incognito + network wait)
#    - Crash/freeze protection (restart loop + DevTools watchdog)
#    - Periodic page auto-refresh (default: every 3 hours)
#    - Scheduled nightly reboot (default: 02:00)
#    - Cursor hiding, boot splash, resolution, rotation, HDMI audio, CEC
#
#  Based on TOLDOTECHNIK/Raspberry-Pi-Kiosk-Display-System (kiosk_setup.sh)
#
#  History
#  2026-07-07 v2.0: Rewrite — restructured into functions, shared
#                   helpers, sudo keepalive, custom splash URL, setup summary
# ============================================================================

set -u

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------
SCRIPT_VERSION="2.0"
CURRENT_USER=$(whoami)
HOME_DIR=$(eval echo "~$CURRENT_USER")
LABWC_DIR="$HOME_DIR/.config/labwc"
AUTOSTART_FILE="$LABWC_DIR/autostart"
RC_XML="$LABWC_DIR/rc.xml"
CONFIG_TXT="/boot/firmware/config.txt"
CMDLINE_TXT="/boot/firmware/cmdline.txt"
REBOOT_CRON_FILE="/etc/cron.d/kiosk-nightly-reboot"
DEBUG_PORT=9222

# Collected for the final summary
CONFIGURED=()

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
log_step() { echo -e "\e[90m$1\e[0m"; }
log_ok()   { echo -e "\e[32m✔\e[0m $1"; }
log_warn() { echo -e "\e[33m$1\e[0m"; }
log_head() { echo -e "\n\e[94m── $1 ──\e[0m"; }

banner() {
    echo -e "\e[35m"
    echo "  ┌──────────────────────────────────────────────┐"
    echo "  │       Kiosk Display Setup  ·  v$SCRIPT_VERSION            │"
    echo "  └──────────────────────────────────────────────┘"
    echo -e "\e[0m"
}

# Spinner shown while a background job (PID $1) runs
spinner() {
    local pid=$1
    local message=$2
    local delay=0.1
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    tput civis 2>/dev/null || true
    local i=0
    while [ -d /proc/$pid ]; do
        printf "\r\e[35m%s\e[0m %s" "${frames[$i]}" "$message"
        i=$(((i + 1) % ${#frames[@]}))
        sleep $delay
    done
    printf "\r\e[32m✔\e[0m %s\n" "$message"
    tput cnorm 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Input helpers
# ----------------------------------------------------------------------------

# ask_user "Question?" "y"|"n"  ->  returns 0 for yes, 1 for no
ask_user() {
    local prompt="$1"
    local default="$2"
    local default_text=""
    [ "$default" = "y" ] && default_text=" [default: yes]"
    [ "$default" = "n" ] && default_text=" [default: no]"

    while true; do
        read -r -p "$prompt$default_text (y/n): " yn
        yn="${yn:-$default}"
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

# prompt_value "Prompt text" "default"  ->  echoes the entered value or default
prompt_value() {
    local prompt="$1"
    local default="$2"
    local value
    read -r -p "$prompt [default: $default]: " value
    echo "${value:-$default}"
}

# ----------------------------------------------------------------------------
# System helpers
# ----------------------------------------------------------------------------

# apt_install "Message..." pkg [pkg...]      (full install)
apt_install() {
    local message="$1"; shift
    sudo apt-get install -y "$@" > /dev/null 2>&1 &
    spinner $! "$message"
}

# apt_install_min "Message..." pkg [pkg...]  (--no-install-recommends)
apt_install_min() {
    local message="$1"; shift
    sudo apt-get install --no-install-recommends -y "$@" > /dev/null 2>&1 &
    spinner $! "$message"
}

# ensure_installed <command> <package> ["Message..."]
ensure_installed() {
    local cmd="$1" pkg="$2" message="${3:-Installing $2...}"
    if ! command -v "$cmd" &> /dev/null; then
        apt_install "$message" "$pkg"
    fi
}

# Make sure the labwc config dir and autostart file exist
ensure_autostart() {
    mkdir -p "$LABWC_DIR"
    touch "$AUTOSTART_FILE"
}

# append_once <grep-pattern> <file>   (content piped via heredoc on stdin)
# Returns 0 if appended, 1 if the pattern was already present.
append_once() {
    local pattern="$1" file="$2"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        return 1
    fi
    cat >> "$file"
}

# ----------------------------------------------------------------------------
# Feature sections
# ----------------------------------------------------------------------------

section_system_update() {
    log_head "System packages"
    if ask_user "Update the package list?" "y"; then
        sudo apt-get update > /dev/null 2>&1 &
        spinner $! "Updating package list..."
    fi
    echo
    if ask_user "Upgrade installed packages? (this may take a while)" "y"; then
        sudo apt-get upgrade -y > /dev/null 2>&1 &
        spinner $! "Upgrading installed packages..."
        CONFIGURED+=("System packages upgraded")
    fi
}

section_wayland() {
    log_head "Wayland / labwc compositor"
    if ask_user "Install Wayland and labwc packages?" "y"; then
        apt_install_min "Installing Wayland packages..." labwc wlr-randr seatd
        CONFIGURED+=("Wayland + labwc installed")
    fi
}

section_chromium() {
    log_head "Chromium browser"
    if ! ask_user "Install Chromium Browser?" "y"; then
        return
    fi

    # Detect the available chromium package name (prefer 'chromium')
    local pkg=""
    if apt-cache show chromium >/dev/null 2>&1; then
        pkg="chromium"
    elif apt-cache show chromium-browser >/dev/null 2>&1; then
        pkg="chromium-browser"
    fi

    if [ -z "$pkg" ]; then
        log_warn "No chromium package found in APT. Enable the appropriate repository or install manually."
    else
        apt_install_min "Installing $pkg (this may take a while)..." "$pkg"
        CONFIGURED+=("Chromium installed ($pkg)")
    fi
}

section_greetd() {
    log_head "Auto-login (greetd)"
    if ! ask_user "Install and configure greetd for auto start of labwc?" "y"; then
        return
    fi

    apt_install "Installing greetd..." greetd

    log_step "Writing /etc/greetd/config.toml..."
    sudo mkdir -p /etc/greetd
    sudo tee /etc/greetd/config.toml > /dev/null << EOL
[terminal]
vt = 7
[default_session]
command = "/usr/bin/labwc"
user = "$CURRENT_USER"
EOL
    log_ok "/etc/greetd/config.toml written."

    sudo systemctl enable greetd > /dev/null 2>&1 &
    spinner $! "Enabling greetd service..."
    sudo systemctl set-default graphical.target > /dev/null 2>&1 &
    spinner $! "Setting graphical target as default..."
    CONFIGURED+=("greetd auto-login for $CURRENT_USER")
}

section_browser_autostart() {
    log_head "Kiosk browser autostart"
    if ! ask_user "Create the Chromium kiosk autostart entry?" "y"; then
        return
    fi

    local url incognito_flag="" network_wait="" watchdog=false watchdog_flags=""

    url=$(prompt_value "Enter the URL to open in Chromium" "https://webglsamples.org/aquarium/aquarium.html")

    echo
    if ask_user "Start browser in incognito mode?" "n"; then
        incognito_flag="--incognito "
    fi

    echo
    if ask_user "Wait for network connectivity before launching Chromium?" "y"; then
        local ping_host max_wait
        ping_host=$(prompt_value "Host to ping for the network check" "8.8.8.8")
        max_wait=$(prompt_value "Maximum wait time in seconds" "30")
        if ! [[ "$max_wait" =~ ^[0-9]+$ ]]; then
            log_warn "Invalid wait time. Using 30 seconds."
            max_wait=30
        fi
        network_wait="  # Wait for network connectivity (max ${max_wait}s)
  for i in \$(seq 1 $max_wait); do
    if ping -c 1 -W 2 $ping_host > /dev/null 2>&1; then
      break
    fi
    sleep 1
  done
"
    fi

    echo
    if ask_user "Enable automatic restart if Chromium crashes or freezes (watchdog)?" "y"; then
        watchdog=true
        # --noerrdialogs / --disable-session-crashed-bubble suppress the
        # "Restore pages?" prompt after a crash. --remote-debugging-port
        # exposes a local-only (127.0.0.1) health endpoint used to detect freezes.
        watchdog_flags="--noerrdialogs --disable-session-crashed-bubble --remote-debugging-port=$DEBUG_PORT "
        ensure_installed curl curl "Installing curl for the watchdog health check..."
    fi

    # Locate the chromium binary (prefer PATH, fall back to common locations)
    local chromium_bin
    chromium_bin="$(command -v chromium || command -v chromium-browser || true)"
    if [ -z "$chromium_bin" ]; then
        if [ -x "/usr/bin/chromium" ]; then
            chromium_bin="/usr/bin/chromium"
        elif [ -x "/usr/bin/chromium-browser" ]; then
            chromium_bin="/usr/bin/chromium-browser"
        else
            chromium_bin="/usr/bin/chromium"
            log_warn "Couldn't find a chromium binary in PATH. Using $chromium_bin in autostart — adjust if needed."
        fi
    fi

    ensure_autostart

    if grep -qE "chromium|chromium-browser" "$AUTOSTART_FILE" 2>/dev/null; then
        log_warn "Chromium autostart entry already exists in $AUTOSTART_FILE. No changes made."
        return
    fi

    log_step "Adding Chromium to labwc autostart..."
    local chromium_cmd="$chromium_bin ${incognito_flag}${watchdog_flags}--autoplay-policy=no-user-gesture-required --kiosk --no-memcheck $url"

    if [ "$watchdog" = true ]; then
        cat >> "$AUTOSTART_FILE" << EOL
# Launch Chromium in kiosk mode (auto-restart on crash)
(
$network_wait
  while true; do
    $chromium_cmd
    sleep 2
  done
) &

# Watchdog: if Chromium freezes (DevTools endpoint unresponsive twice in a row),
# kill it — the restart loop above relaunches it automatically
(
  sleep 60
  FAILS=0
  while true; do
    if pgrep -f "$chromium_bin" > /dev/null 2>&1; then
      if curl -s --max-time 10 http://127.0.0.1:$DEBUG_PORT/json/version > /dev/null 2>&1; then
        FAILS=0
      else
        FAILS=\$((FAILS + 1))
        if [ "\$FAILS" -ge 2 ]; then
          pkill -9 -f "$chromium_bin"
          FAILS=0
          sleep 10
        fi
      fi
    fi
    sleep 30
  done
) &
EOL
        CONFIGURED+=("Kiosk browser: $url (crash/freeze protection ON)")
    elif [ -n "$network_wait" ]; then
        cat >> "$AUTOSTART_FILE" << EOL
# Launch Chromium in kiosk mode (with network wait)
(
$network_wait
    $chromium_cmd
) &
EOL
        CONFIGURED+=("Kiosk browser: $url")
    else
        echo "$chromium_cmd &" >> "$AUTOSTART_FILE"
        CONFIGURED+=("Kiosk browser: $url")
    fi

    log_ok "labwc autostart updated at $AUTOSTART_FILE."
}

section_cursor_hide() {
    log_head "Mouse cursor"
    if ! ask_user "Hide the mouse cursor in kiosk mode?" "y"; then
        return
    fi

    ensure_installed wtype wtype "Installing wtype for cursor control..."
    mkdir -p "$LABWC_DIR"

    if [ -f "$RC_XML" ]; then
        if grep -q "HideCursor" "$RC_XML" 2>/dev/null; then
            log_warn "rc.xml already contains a HideCursor configuration. No changes made."
        elif grep -q "</keyboard>" "$RC_XML"; then
            log_step "Adding HideCursor keybind to existing rc.xml..."
            sed -i 's|</keyboard>|  <keybind key="W-h">\n    <action name="HideCursor"/>\n    <action name="WarpCursor" to="output" x="1" y="1"/>\n  </keybind>\n</keyboard>|' "$RC_XML"
            log_ok "HideCursor keybind added."
        else
            log_warn "Couldn't find </keyboard> tag in rc.xml. Please add the HideCursor keybind manually."
        fi
    else
        log_step "Creating rc.xml with HideCursor configuration..."
        cat > "$RC_XML" << 'EOL'
<?xml version="1.0"?>
<labwc_config>
  <keyboard>
    <keybind key="W-h">
      <action name="HideCursor"/>
      <action name="WarpCursor" to="output" x="1" y="1"/>
    </keybind>
  </keyboard>
</labwc_config>
EOL
        log_ok "rc.xml created."
    fi

    ensure_autostart
    if append_once "wtype.*logo.*-k h" "$AUTOSTART_FILE" << 'EOL'

# Hide cursor on startup (simulate Win+H hotkey)
sleep 1 && wtype -M logo -k h -m logo &
EOL
    then
        log_ok "Cursor hiding configured."
        CONFIGURED+=("Cursor hidden on startup")
    else
        log_warn "Autostart already contains the cursor hiding command. No changes made."
    fi
}

section_auto_refresh() {
    log_head "Page auto-refresh"
    if ! ask_user "Automatically refresh the browser page periodically?" "y"; then
        return
    fi

    local minutes
    minutes=$(prompt_value "Refresh interval in minutes" "180")
    if ! [[ "$minutes" =~ ^[0-9]+$ ]] || [ "$minutes" -lt 1 ]; then
        log_warn "Invalid interval. Using default of 180 minutes."
        minutes=180
    fi

    ensure_installed wtype wtype "Installing wtype for page refresh..."
    ensure_autostart

    if append_once "wtype -k F5" "$AUTOSTART_FILE" << EOL

# Refresh browser page every $minutes minutes (simulate F5 key)
(
  while true; do
    sleep $((minutes * 60))
    wtype -k F5
  done
) &
EOL
    then
        log_ok "Page auto-refresh configured (every $minutes minutes)."
        CONFIGURED+=("Page refresh every $minutes min")
    else
        log_warn "Autostart already contains a page refresh command. No changes made."
    fi
}

section_splash() {
    log_head "Boot splash screen"
    if ! ask_user "Install the boot splash screen?" "y"; then
        return
    fi

    apt_install "Installing splash screen and themes (this may take a while)..." plymouth plymouth-themes pix-plym-splash

    if [ ! -e /usr/share/plymouth/themes/pix/pix.script ]; then
        log_warn "pix theme not found after installation. Splash screen may not work correctly."
    else
        log_step "Setting splash screen theme to pix..."
        sudo plymouth-set-default-theme pix

        echo
        local splash_url
        splash_url=$(prompt_value "URL of a custom splash image (PNG), or leave blank to keep default" "")
        if [ -n "$splash_url" ]; then
            if sudo wget -q "$splash_url" -O /usr/share/plymouth/themes/pix/splash.png; then
                log_ok "Custom splash image installed."
            else
                log_warn "Failed to download the custom splash image. Keeping the default."
            fi
        fi

        sudo update-initramfs -u > /dev/null 2>&1 &
        spinner $! "Updating initramfs..."
    fi

    if [ -f "$CONFIG_TXT" ]; then
        if ! grep -q "disable_splash" "$CONFIG_TXT"; then
            log_step "Adding disable_splash=1 to $CONFIG_TXT..."
            echo 'disable_splash=1' | sudo tee -a "$CONFIG_TXT" > /dev/null
        else
            log_warn "$CONFIG_TXT already contains a disable_splash option. No changes made — please check manually."
        fi
    else
        log_warn "$CONFIG_TXT not found — skipping config.txt modification."
    fi

    if [ -f "$CMDLINE_TXT" ]; then
        if ! grep -q "splash" "$CMDLINE_TXT"; then
            log_step "Adding quiet splash plymouth.ignore-serial-consoles to $CMDLINE_TXT..."
            sudo sed -i 's/$/ quiet splash plymouth.ignore-serial-consoles/' "$CMDLINE_TXT"
        fi
        if grep -q "console=tty1" "$CMDLINE_TXT"; then
            log_step "Replacing console=tty1 with console=tty3 in $CMDLINE_TXT..."
            sudo sed -i 's/console=tty1/console=tty3/' "$CMDLINE_TXT"
        elif ! grep -q "console=tty3" "$CMDLINE_TXT"; then
            log_step "Adding console=tty3 to $CMDLINE_TXT..."
            sudo sed -i 's/$/ console=tty3/' "$CMDLINE_TXT"
        fi
        log_ok "Splash screen installed and configured."
        CONFIGURED+=("Boot splash screen (pix theme)")
    else
        log_warn "$CMDLINE_TXT not found — skipping cmdline.txt modification."
    fi
}

section_resolution() {
    log_head "Screen resolution"
    if ! ask_user "Set the screen resolution (cmdline.txt + labwc autostart)?" "y"; then
        return
    fi

    ensure_installed edid-decode edid-decode "Installing edid-decode..."

    # Try to read EDID; Pi setups vary between card0 and card1
    local edid_path=""
    if [ -r /sys/class/drm/card1-HDMI-A-1/edid ]; then
        edid_path="/sys/class/drm/card1-HDMI-A-1/edid"
    elif [ -r /sys/class/drm/card0-HDMI-A-1/edid ]; then
        edid_path="/sys/class/drm/card0-HDMI-A-1/edid"
    fi

    local available_resolutions=()
    if [ -n "$edid_path" ]; then
        local edid_output line resolution frequency
        edid_output=$(sudo cat "$edid_path" | edid-decode 2>/dev/null || true)
        while IFS= read -r line; do
            if [[ "$line" =~ ([0-9]+)x([0-9]+)[[:space:]]+([0-9]+\.[0-9]+|[0-9]+)\ Hz ]]; then
                resolution="${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"
                frequency="${BASH_REMATCH[3]}"
                available_resolutions+=("${resolution}@${frequency}")
            fi
        done <<< "$edid_output"
    fi

    if [ ${#available_resolutions[@]} -eq 0 ]; then
        log_warn "No resolutions found via EDID. Using default list."
        available_resolutions=("1920x1080@60" "1280x720@60" "1024x768@60" "1600x900@60" "1366x768@60")
    fi

    echo -e "\e[94mPlease choose a resolution (type in the number):\e[0m"
    local RESOLUTION
    select RESOLUTION in "${available_resolutions[@]}"; do
        if [[ -n "$RESOLUTION" ]]; then
            echo -e "\e[32mYou selected $RESOLUTION\e[0m"
            break
        else
            log_warn "Invalid selection, please try again."
        fi
    done

    if [ -f "$CMDLINE_TXT" ]; then
        if ! grep -q "video=" "$CMDLINE_TXT"; then
            log_step "Adding video=HDMI-A-1:$RESOLUTION to $CMDLINE_TXT..."
            sudo sed -i "1s/^/video=HDMI-A-1:$RESOLUTION /" "$CMDLINE_TXT"
            log_ok "Resolution added to cmdline.txt."
        else
            log_warn "cmdline.txt already contains a video entry. No changes made."
        fi
    else
        log_warn "$CMDLINE_TXT not found — skipping cmdline modification."
    fi

    ensure_autostart
    if ! grep -q "wlr-randr --output HDMI-A-1 --mode $RESOLUTION" "$AUTOSTART_FILE" 2>/dev/null; then
        echo "wlr-randr --output HDMI-A-1 --mode $RESOLUTION" >> "$AUTOSTART_FILE"
        log_ok "Resolution command added to labwc autostart."
        CONFIGURED+=("Resolution: $RESOLUTION")
    else
        log_warn "Autostart already contains this resolution command. No changes made."
    fi
}

section_rotation() {
    log_head "Screen orientation"
    if ! ask_user "Set the screen orientation (rotation)?" "n"; then
        return
    fi

    echo -e "\e[94mPlease choose an orientation:\e[0m"
    local orientations=("normal (0°)" "90° clockwise" "180°" "270° clockwise")
    local transform_values=("normal" "90" "180" "270")
    local orientation TRANSFORM

    select orientation in "${orientations[@]}"; do
        if [[ -n "$orientation" ]]; then
            TRANSFORM="${transform_values[$((REPLY - 1))]}"
            echo -e "\e[32mYou selected $orientation\e[0m"
            break
        else
            log_warn "Invalid selection, please try again."
        fi
    done

    ensure_autostart
    if ! grep -qE "wlr-randr.*--transform" "$AUTOSTART_FILE" 2>/dev/null; then
        echo "wlr-randr --output HDMI-A-1 --transform $TRANSFORM" >> "$AUTOSTART_FILE"
        log_ok "Screen orientation added to labwc autostart."
        CONFIGURED+=("Rotation: $orientation")
    else
        log_warn "Autostart already contains a transform command. No changes made."
    fi
}

section_audio_hdmi() {
    log_head "Audio output"
    if ! ask_user "Force audio output to HDMI?" "y"; then
        return
    fi

    if [ ! -f "$CONFIG_TXT" ]; then
        log_warn "$CONFIG_TXT not found — skipping audio configuration."
        return
    fi

    if grep -q "^dtparam=audio=off" "$CONFIG_TXT"; then
        log_warn "$CONFIG_TXT already has dtparam=audio=off. No changes made."
    elif grep -q "^dtparam=audio=" "$CONFIG_TXT"; then
        log_step "Updating existing dtparam=audio in $CONFIG_TXT..."
        sudo sed -i 's/^dtparam=audio=.*/dtparam=audio=off/' "$CONFIG_TXT"
        log_ok "Audio parameter updated to force HDMI output."
        CONFIGURED+=("Audio forced to HDMI")
    elif grep -q "^#dtparam=audio=" "$CONFIG_TXT"; then
        log_step "Uncommenting and setting dtparam=audio=off in $CONFIG_TXT..."
        sudo sed -i 's/^#dtparam=audio=.*/dtparam=audio=off/' "$CONFIG_TXT"
        log_ok "Audio parameter set to force HDMI output."
        CONFIGURED+=("Audio forced to HDMI")
    else
        log_step "Adding dtparam=audio=off to $CONFIG_TXT..."
        echo 'dtparam=audio=off' | sudo tee -a "$CONFIG_TXT" > /dev/null
        log_ok "Audio parameter added to force HDMI output."
        CONFIGURED+=("Audio forced to HDMI")
    fi
}

section_cec() {
    log_head "TV remote (HDMI-CEC)"
    if ! ask_user "Enable TV remote control via HDMI-CEC?" "n"; then
        return
    fi

    apt_install "Installing CEC utilities..." ir-keytable

    log_step "Creating custom CEC keymap..."
    sudo mkdir -p /etc/rc_keymaps
    sudo tee /etc/rc_keymaps/custom-cec.toml > /dev/null << 'EOL'
[[protocols]]
name = "custom_cec"
protocol = "cec"
[protocols.scancodes]
0x00 = "KEY_ENTER"
0x01 = "KEY_UP"
0x02 = "KEY_DOWN"
0x03 = "KEY_LEFT"
0x04 = "KEY_RIGHT"
0x09 = "KEY_EXIT"
0x0d = "KEY_BACK"
0x44 = "KEY_PLAYPAUSE"
0x45 = "KEY_STOPCD"
0x46 = "KEY_PAUSECD"
EOL
    log_ok "Custom CEC keymap created."

    log_step "Creating CEC setup service..."
    sudo tee /etc/systemd/system/cec-setup.service > /dev/null << 'EOL'
[Unit]
Description=CEC Remote Control Setup
After=multi-user.target
Before=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/bin/cec-ctl -d /dev/cec1 --playback
ExecStart=/bin/sleep 2
ExecStart=/usr/bin/cec-ctl -d /dev/cec1 --active-source phys-addr=1.0.0.0
ExecStart=/bin/sleep 1
ExecStart=/usr/bin/ir-keytable -c -s rc0 -w /etc/rc_keymaps/custom-cec.toml
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload > /dev/null 2>&1
    sudo systemctl enable cec-setup.service > /dev/null 2>&1 &
    spinner $! "Enabling CEC service..."

    log_ok "TV remote CEC support configured."
    log_step "Note: Make sure HDMI-CEC (SimpLink/Anynet+/Bravia Sync) is enabled on your TV."
    CONFIGURED+=("HDMI-CEC remote support")
}

section_nightly_reboot() {
    log_head "Nightly reboot"
    if ! ask_user "Schedule an automatic nightly reboot?" "y"; then
        return
    fi

    local reboot_time
    reboot_time=$(prompt_value "Reboot time in 24h HH:MM format" "02:00")
    if ! [[ "$reboot_time" =~ ^([0-9]|[01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        log_warn "Invalid time format. Using default of 02:00."
        reboot_time="02:00"
    fi

    local hour="${reboot_time%%:*}"
    local minute="${reboot_time##*:}"

    if [ -f "$REBOOT_CRON_FILE" ]; then
        log_warn "$REBOOT_CRON_FILE already exists. No changes made — please check manually."
        return
    fi

    log_step "Creating cron job for nightly reboot at $reboot_time..."
    sudo tee "$REBOOT_CRON_FILE" > /dev/null << EOL
# Kiosk display: nightly reboot
$minute $hour * * * root /sbin/shutdown -r now
EOL
    sudo chmod 644 "$REBOOT_CRON_FILE"
    log_ok "Nightly reboot scheduled at $reboot_time."
    CONFIGURED+=("Nightly reboot at $reboot_time")
}

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
    echo "This script should not be run as root. Please run as a regular user with sudo permissions."
    exit 1
fi

if ! command -v apt-get &> /dev/null; then
    echo "This script requires a Debian-based system (apt-get not found)."
    exit 1
fi

banner

# Prime sudo once and keep it alive so prompts don't stall mid-script
echo "Some steps require sudo — you may be asked for your password once."
sudo -v || exit 1
( while true; do sudo -n true; sleep 60; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null; tput cnorm 2>/dev/null || true' EXIT

# ----------------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------------

section_system_update
section_wayland
section_chromium
section_greetd
section_browser_autostart
section_cursor_hide
section_auto_refresh
section_splash
section_resolution
section_rotation
section_audio_hdmi
section_cec
section_nightly_reboot

# Cleanup
log_head "Cleanup"
sudo apt-get clean > /dev/null 2>&1 &
spinner $! "Cleaning up apt caches..."

# ----------------------------------------------------------------------------
# Summary + reboot
# ----------------------------------------------------------------------------

echo
log_ok "\e[32mSetup completed successfully!\e[0m"
if [ ${#CONFIGURED[@]} -gt 0 ]; then
    echo -e "\n\e[94mConfigured in this run:\e[0m"
    for item in "${CONFIGURED[@]}"; do
        echo -e "  \e[32m•\e[0m $item"
    done
fi

echo
if ask_user "Reboot now to apply all changes?" "n"; then
    log_step "Rebooting system..."
    sudo reboot
else
    log_warn "Please remember to reboot manually for all changes to take effect."
fi
