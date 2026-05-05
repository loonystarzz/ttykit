##!/usr/bin/env bash
# sysctl.sh — system management TUI + hardware key daemon
#
# usage:
#   sudo ./sysctl.sh --firstrun   → install deps, self-install to ~/.local/bin/ttykit,
#                                   configure prompt + MOTD (run once)
#   ./sysctl.sh                   → interactive menu
#   ttykit                        → interactive menu (after firstrun install)
#   sudo ./sysctl.sh --keys       → run hardware key daemon (safe to call if already running)
#
# quick info commands (no root needed):
#   ./sysctl.sh bat               → battery status
#   ./sysctl.sh audio             → current sink + volume
#   ./sysctl.sh net               → active connection + IP
#   ./sysctl.sh bt                → bluetooth status + connected devices
#   ./sysctl.sh bri               → screen brightness
#   ./sysctl.sh all               → everything at once

set -euo pipefail

# ─── config ────────────────────────────────────────────────────────────────────
VOLUME_STEP=5          # percent per keypress
BRIGHTNESS_STEP=5      # percent per keypress
NOTIFY_CMD=""          # auto-detected below
KEY_DAEMON_PIDFILE="/var/run/sysctl-keys.pid"
KEY_DAEMON_LOG="/var/log/sysctl-keys.log"

# ─── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "${RED}✗${RESET} $*" >&2; }
hdr()  { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}\n"; }

# ─── dependency check / first-run install ─────────────────────────────────────
DEPS_FILE="/etc/sysctl-script-installed"

check_cmd() { command -v "$1" &>/dev/null; }

install_deps() {
    hdr "First-run setup"
    echo "Checking and installing dependencies..."

    local pkgs=()

    check_cmd brightnessctl    || pkgs+=(brightnessctl)
    check_cmd aplay            || pkgs+=(alsa-utils)
    check_cmd wpctl            || pkgs+=(wireplumber pipewire-utils)
    check_cmd nmcli            || pkgs+=(NetworkManager)
    check_cmd fzf              || pkgs+=(fzf)
    check_cmd kmscon           || pkgs+=(kmscon)
    check_cmd python3          || pkgs+=(python3)
    # python3-evdev for key daemon
    python3 -c "import evdev" 2>/dev/null || pkgs+=(python3-evdev)
    # whiptail for TUI
    check_cmd whiptail         || pkgs+=(newt)
    # pactl as fallback audio info
    check_cmd pactl            || pkgs+=(pipewire-pulse)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        echo "Installing: ${pkgs[*]}"
        if [[ $EUID -ne 0 ]]; then
            warn "Need sudo to install packages"
            sudo dnf install -y "${pkgs[@]}"
        else
            dnf install -y "${pkgs[@]}"
        fi
    else
        ok "All dependencies already installed"
    fi

    # bluetuith — not in official Fedora repos, install binary from GitHub releases
    if ! check_cmd bluetuith; then
        echo "Installing bluetuith from GitHub releases..."
        local arch
        arch=$(uname -m)
        # map uname arch to release archive naming
        case "$arch" in
            x86_64)  arch="x86_64"  ;;
            aarch64) arch="arm64"   ;;
            armv7l)  arch="armv7"   ;;
            *)       warn "Unknown arch $arch — skipping bluetuith install"; arch="" ;;
        esac
        if [[ -n "$arch" ]]; then
            local tag url tmp
            # get latest release tag from GitHub API
            tag=$(curl -fsSL https://api.github.com/repos/darkhz/bluetuith/releases/latest \
                2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
            # strip leading v for filename
            local ver="${tag#v}"
            url="https://github.com/darkhz/bluetuith/releases/download/${tag}/bluetuith_${ver}_Linux_${arch}.tar.gz"
            tmp=$(mktemp -d)
            if curl -fsSL "$url" | tar -xz -C "$tmp" 2>/dev/null; then
                install -m 755 "$tmp/bluetuith" /usr/local/bin/bluetuith
                rm -rf "$tmp"
                ok "bluetuith ${tag} installed to /usr/local/bin/bluetuith"
            else
                rm -rf "$tmp"
                warn "bluetuith download failed (url: $url) — bluetooth TUI unavailable"
            fi
        fi
    fi
#rights for key daemon thing
sudo usermod -aG video $USER
#kmscon
sudo systemctl disable getty@tty1 
sudo systemctl enable kmscon.service 
    # allow brightnessctl without sudo for current user
    if check_cmd brightnessctl; then
        local user="${SUDO_USER:-$USER}"
        if ! groups "$user" | grep -q video; then
            usermod -aG video "$user" 2>/dev/null || \
                warn "Could not add $user to video group — brightness may need sudo"
        fi
        # setuid bit as fallback
        chmod u+s "$(command -v brightnessctl)" 2>/dev/null || true
    fi

    touch "$DEPS_FILE"
    ok "Setup complete; may need to install wifi drivers and networkmanager wifi plugin if not already installed."
}



# ─── audio helpers (PipeWire via wpctl) ───────────────────────────────────────
audio_vol_up()   { wpctl set-volume @DEFAULT_AUDIO_SINK@ "${VOLUME_STEP}%+"; }
audio_vol_down() { wpctl set-volume @DEFAULT_AUDIO_SINK@ "${VOLUME_STEP}%-"; }
audio_mute()     { wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle; }
audio_mic_mute() { wpctl set-mute   @DEFAULT_AUDIO_SOURCE@ toggle; }

get_volume() {
    wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null \
        | awk '{printf "%d", $2 * 100}'
}

get_mute() {
    wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q MUTED && echo "MUTED" || echo "on"
}

# ─── brightness helpers ────────────────────────────────────────────────────────
brightness_up()   { brightnessctl set "${BRIGHTNESS_STEP}%+" -q; }
brightness_down() { brightnessctl set "${BRIGHTNESS_STEP}%-" -q; }

get_brightness() {
    brightnessctl -m 2>/dev/null | awk -F, '{gsub(/%/,"",$4); print int($4)}'
}

# ─── status bar ───────────────────────────────────────────────────────────────
show_status() {
    hdr "System Status"
    local vol mute bri
    vol=$(get_volume 2>/dev/null || echo "?")
    mute=$(get_mute 2>/dev/null || echo "?")
    bri=$(get_brightness 2>/dev/null || echo "?")

    printf "  ${BOLD}Volume${RESET}      : %s%% (%s)\n" "$vol" "$mute"
    printf "  ${BOLD}Brightness${RESET}  : %s%%\n" "$bri"
    printf "  ${BOLD}Key daemon${RESET}  : "
    if [[ -f "$KEY_DAEMON_PIDFILE" ]] && kill -0 "$(cat "$KEY_DAEMON_PIDFILE")" 2>/dev/null; then
        echo -e "${GREEN}running${RESET} (pid $(cat "$KEY_DAEMON_PIDFILE"))"
    else
        echo -e "${RED}stopped${RESET}"
    fi
    echo
}

# ─── audio menu ───────────────────────────────────────────────────────────────
menu_audio() {
    local last="1"
    while true; do
        local vol mute
        vol=$(get_volume 2>/dev/null || echo "?")
        mute=$(get_mute 2>/dev/null || echo "?")

        local choice
        choice=$(whiptail --title "Audio  [vol: ${vol}% | ${mute}]" \
            --default-item "$last" \
            --menu "Choose action" 18 50 8 \
            "1" "Volume up   (+${VOLUME_STEP}%)" \
            "2" "Volume down (-${VOLUME_STEP}%)" \
            "3" "Toggle mute" \
            "4" "Toggle mic mute" \
            "5" "Set volume (custom %)" \
            "6" "Show sinks (wpctl)" \
            "b" "← Back" \
            3>&1 1>&2 2>&3) || return
        # guard against empty or invalid choice
        [[ -z "$choice" || "$choice" == "-1" ]] && continue
        last="$choice"

        case "$choice" in
            1) audio_vol_up   ;;
            2) audio_vol_down ;;
            3) audio_mute     ;;
            4) audio_mic_mute ;;
            5)
                local val
                val=$(whiptail --inputbox "Enter volume (0-100):" 8 40 "$vol" \
                    --title "Set Volume" 3>&1 1>&2 2>&3) || continue
                # validate it's a plain integer before passing to wpctl
                if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -le 150 ]]; then
                    wpctl set-volume @DEFAULT_AUDIO_SINK@ "${val}%"
                else
                    warn "Invalid volume: $val"
                fi
                ;;
            6)
                clear
                hdr "Audio Sinks"
                wpctl status | grep -A30 "Sinks"
                echo; read -rp "Press enter to continue..."
                ;;
            b) return ;;
        esac
    done
}

# ─── brightness menu ──────────────────────────────────────────────────────────
menu_brightness() {
    local last="1"
    while true; do
        local bri
        bri=$(get_brightness 2>/dev/null || echo "?")

        local choice
        choice=$(whiptail --title "Brightness  [${bri}%]" \
            --default-item "$last" \
            --menu "Choose action" 15 50 6 \
            "1" "Increase (+${BRIGHTNESS_STEP}%)" \
            "2" "Decrease (-${BRIGHTNESS_STEP}%)" \
            "3" "Set custom %" \
            "4" "Max (100%)" \
            "5" "Dim (10%)" \
            "b" "← Back" \
            3>&1 1>&2 2>&3) || return
        [[ -n "$choice" ]] && last="$choice"

        case "$choice" in
            1) brightness_up;   ok "Brightness: $(get_brightness)%" ;;
            2) brightness_down; ok "Brightness: $(get_brightness)%" ;;
            3)
                local val
                val=$(whiptail --inputbox "Enter brightness (0-100):" 8 40 "$bri" \
                    --title "Set Brightness" 3>&1 1>&2 2>&3) || continue
                brightnessctl set "${val}%" -q
                ok "Brightness set to ${val}%"
                ;;
            4) brightnessctl set 100% -q; ok "Brightness: 100%" ;;
            5) brightnessctl set 10%  -q; ok "Brightness: 10%" ;;
            b) return ;;
        esac
    done
}

# ─── wifi fzf picker ──────────────────────────────────────────────────────────
wifi_connect() {
    clear
    hdr "WiFi — scanning..."

    # rescan (background, give it a moment)
    nmcli device wifi rescan 2>/dev/null &
    sleep 2

    # build a pretty list: signal bars, SSID, security, known marker
    # columns: IN-USE, BSSID, SSID, MODE, CHAN, RATE, SIGNAL, BARS, SECURITY
    local networks
    networks=$(nmcli -t -f IN-USE,SSID,SIGNAL,BARS,SECURITY device wifi list 2>/dev/null \
        | awk -F: '
            {
                inuse  = ($1 == "*") ? "▶" : " "
                ssid   = $2
                signal = $3
                bars   = $4
                sec    = ($5 == "" || $5 == "--") ? "open" : $5
                if (ssid == "") next
                printf "%s  %-35s  %s  %3s%%  %s\n", inuse, ssid, bars, signal, sec
            }
        ')

    if [[ -z "$networks" ]]; then
        err "No networks found. Is WiFi enabled?"
        read -rp "Press enter..."
        return
    fi

    # fzf picker — header row explains columns
    local selected
    selected=$(echo "$networks" \
        | fzf --ansi \
              --prompt="WiFi > " \
              --header="  SSID                                BARS  SIG   SECURITY  (Enter=connect, Esc=back)" \
              --height=70% \
              --border=rounded \
              --bind="ctrl-r:reload(nmcli device wifi rescan 2>/dev/null; sleep 1; nmcli -t -f IN-USE,SSID,SIGNAL,BARS,SECURITY device wifi list 2>/dev/null | awk -F: '{inuse=(\$1==\"*\")?\"▶\":\" \"; ssid=\$2; signal=\$3; bars=\$4; sec=(\$5==\"\"||  \$5==\"--\")?\"open\":\$5; if(ssid==\"\") next; printf \"%s  %-35s  %s  %3s%%  %s\n\",inuse,ssid,bars,signal,sec}')" \
              --bind="ctrl-r:+first" \
              --info=inline) || return

    # extract SSID (field 2, trimmed)
    local ssid
    ssid=$(echo "$selected" | awk '{$1=""; gsub(/^ +| +$/, ""); print $1}' \
        | awk '{print $1}')
    # simpler: grab col2 (after the ▶/ prefix)
    ssid=$(echo "$selected" | sed 's/^[▶ ]  //' | awk '{print $1}')

    [[ -z "$ssid" ]] && return

    # check if we already have a saved connection for this SSID
    if nmcli connection show "$ssid" &>/dev/null; then
        ok "Connecting to saved network: $ssid"
        nmcli connection up "$ssid"
    else
        # prompt for password if secured
        local sec
        sec=$(echo "$selected" | awk '{print $NF}')
        local pass=""
        if [[ "$sec" != "open" ]]; then
            read -rsp "Password for '$ssid': " pass
            echo
        fi

        if [[ -n "$pass" ]]; then
            nmcli device wifi connect "$ssid" password "$pass"
        else
            nmcli device wifi connect "$ssid"
        fi
    fi

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "Connected to $ssid"
    else
        err "Failed to connect to $ssid"
    fi
    sleep 1
}

# ─── adapter overview ─────────────────────────────────────────────────────────
network_adapters() {
    while true; do
        clear
        hdr "Network Adapters"

        # build adapter list with state, type, IP, MAC
        local lines=()
        while IFS= read -r iface; do
            [[ "$iface" == "lo" ]] && continue
            local state ip mac type_icon
            state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "?")
            mac=$(cat "/sys/class/net/${iface}/address"    2>/dev/null || echo "?")
            ip=$(ip -4 -brief addr show "$iface" 2>/dev/null | awk '{print $3}')
            # guess type from name / sys
            if [[ -d "/sys/class/net/${iface}/wireless" ]]; then
                type_icon="wifi"
            elif [[ "$iface" == eth* || "$iface" == en* ]]; then
                type_icon="eth "
            elif [[ "$iface" == wg*  || "$iface" == tun* || "$iface" == tap* ]]; then
                type_icon="vpn "
            else
                type_icon="    "
            fi
            local state_str
            [[ "$state" == "up" ]] && state_str="UP  " || state_str="DOWN"
            lines+=("${iface}|${type_icon}|${state_str}|${ip:-no ip}|${mac}")
        done < <(ls /sys/class/net/)

        if [[ ${#lines[@]} -eq 0 ]]; then
            echo "  No adapters found"
            read -rp "Press enter..."; return
        fi

        # print table
        printf "  %-12s  %-4s  %-4s  %-18s  %s\n" "INTERFACE" "TYPE" "STATE" "IP" "MAC"
        printf "  %s\n" "$(printf '─%.0s' {1..60})"
        local fzf_input=""
        for line in "${lines[@]}"; do
            IFS='|' read -r iface type_icon state_str ip mac <<< "$line"
            printf "  %-12s  %-4s  %-4s  %-18s  %s\n" \
                "$iface" "$type_icon" "$state_str" "$ip" "$mac"
            fzf_input+="$iface  [$state_str]  $ip  $mac"$'\n'
        done
        echo

        # fzf picker for actions
        local selected
        selected=$(echo "$fzf_input" \
            | fzf --prompt="Adapter > " \
                  --header="Enter=manage  Esc=back" \
                  --height=40% --border=rounded) || return

        local sel_iface
        sel_iface=$(echo "$selected" | awk '{print $1}')
        [[ -z "$sel_iface" ]] && return

        local sel_state
        sel_state=$(cat "/sys/class/net/${sel_iface}/operstate" 2>/dev/null || echo "?")

        local action
        action=$(whiptail --title "Adapter: $sel_iface  [$sel_state]" \
            --menu "Choose action" 14 50 5 \
            "1" "Enable  (ip link set up)" \
            "2" "Disable (ip link set down)" \
            "3" "Restart via NetworkManager" \
            "4" "Show full details" \
            "b" "← Back" \
            3>&1 1>&2 2>&3) || continue

        case "$action" in
            1)
                sudo ip link set "$sel_iface" up   && ok "$sel_iface enabled"  || err "Failed"
                sleep 1 ;;
            2)
                sudo ip link set "$sel_iface" down && ok "$sel_iface disabled" || err "Failed"
                sleep 1 ;;
            3)
                nmcli device disconnect "$sel_iface" 2>/dev/null || true
                nmcli device connect    "$sel_iface" 2>/dev/null \
                    && ok "$sel_iface reconnected" || err "Failed — check nmcli"
                sleep 1 ;;
            4)
                clear; hdr "Details: $sel_iface"
                ip -s link show "$sel_iface"
                echo
                ip -4 addr show "$sel_iface"
                ip -6 addr show "$sel_iface"
                echo; read -rp "Press enter..." ;;
            b) ;;
        esac
    done
}

# ─── networking menu ──────────────────────────────────────────────────────────
menu_network() {
    while true; do
        # get current connection name + IP for status line
        local conn ip status_line
        conn=$(nmcli -t -f NAME,STATE connection show --active 2>/dev/null \
            | grep ":activated" | head -1 | cut -d: -f1)
        ip=$(ip -4 -brief addr show up 2>/dev/null \
            | awk '$1 != "lo" {print $3; exit}' | cut -d/ -f1)
        if [[ -n "$conn" ]]; then
            status_line="${conn}  ${ip:-no ip}"
        else
            status_line="disconnected"
        fi

        local choice
        choice=$(whiptail --title "Networking  [${status_line}]" \
            --menu "Choose action" 18 55 7 \
            "1" "Connect to WiFi (fzf picker)" \
            "2" "Disconnect current" \
            "3" "Saved connections" \
            "4" "Adapters (enable/disable/details)" \
            "5" "Show IP addresses" \
            "6" "Restart NetworkManager" \
            "b" "← Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) wifi_connect ;;
            2)
                if [[ -n "$conn" ]]; then
                    nmcli connection down "$conn" && ok "Disconnected from $conn" || err "Failed"
                else
                    warn "Not connected to anything"
                fi
                sleep 1
                ;;
            3)
                clear; hdr "Saved Connections"
                local saved
                saved=$(nmcli -t -f NAME,TYPE,TIMESTAMP-REAL connection show 2>/dev/null \
                    | awk -F: '{printf "%-30s  %-12s  %s\n", $1, $2, $3}' \
                    | fzf --prompt="Connections > " \
                          --header="Enter=connect  ctrl-d=delete  Esc=back" \
                          --bind="ctrl-d:execute(nmcli connection delete {1} 2>&1)+reload(nmcli -t -f NAME,TYPE,TIMESTAMP-REAL connection show | awk -F: '{printf \"%-30s  %-12s  %s\n\", \$1, \$2, \$3}')" \
                          --height=60% --border=rounded) || continue
                local cname
                cname=$(echo "$saved" | awk '{print $1}')
                [[ -n "$cname" ]] && nmcli connection up "$cname" \
                    && ok "Connected: $cname" || true
                sleep 1
                ;;
            4) network_adapters ;;
            5)
                clear; hdr "IP Addresses"
                ip -brief addr
                echo; read -rp "Press enter..."
                ;;
            6)
                systemctl restart NetworkManager
                ok "NetworkManager restarted"
                sleep 2
                ;;
            b) return ;;
        esac
    done
}

# ─── bluetooth menu ───────────────────────────────────────────────────────────
menu_bluetooth() {
    while true; do
        local bt_status
        bt_status=$(bluetoothctl show 2>/dev/null | grep "Powered" | awk '{print $2}' || echo "?")

        local choice
        choice=$(whiptail --title "Bluetooth  [powered: ${bt_status}]" \
            --menu "Choose action" 15 50 5 \
            "1" "bluetuith (full BT TUI)" \
            "2" "Toggle power" \
            "3" "Show paired devices" \
            "4" "Restart bluetooth service" \
            "b" "← Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) bluetuith ;;
            2)
                if [[ "$bt_status" == "yes" ]]; then
                    bluetoothctl power off && ok "Bluetooth off"
                else
                    bluetoothctl power on  && ok "Bluetooth on"
                fi
                ;;
            3)
                clear; hdr "Paired Devices"
                bluetoothctl paired-devices
                echo; read -rp "Press enter..."
                ;;
            4)
                systemctl restart bluetooth
                ok "Bluetooth restarted"
                sleep 1
                ;;
            b) return ;;
        esac
    done
}

# ─── key daemon menu ──────────────────────────────────────────────────────────
menu_keydaemon() {
    while true; do
        local running=false
        [[ -f "$KEY_DAEMON_PIDFILE" ]] && kill -0 "$(cat "$KEY_DAEMON_PIDFILE")" 2>/dev/null && running=true

        local choice
        choice=$(whiptail --title "Hardware Key Daemon" \
            --menu "Status: $( $running && echo RUNNING || echo STOPPED)" 15 55 5 \
            "1" "$( $running && echo 'Stop daemon' || echo 'Start daemon (requires root)')" \
            "2" "View log" \
            "3" "Autostart enable" \
            "b" "← Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1)
                if $running; then
                    kill "$(cat "$KEY_DAEMON_PIDFILE")" 2>/dev/null || true
                    # wait for process to actually die before removing pidfile
                    local pid
                    pid=$(cat "$KEY_DAEMON_PIDFILE" 2>/dev/null || true)
                    for _ in 1 2 3 4 5; do
                        kill -0 "$pid" 2>/dev/null || break
                        sleep 0.3
                    done
                    rm -f "$KEY_DAEMON_PIDFILE"
                    ok "Daemon stopped"
                else
                    if [[ $EUID -ne 0 ]]; then
                        warn "Starting daemon requires root. Running: sudo $0 --keys &"
                        sudo "$0" --keys &
                    else
                        "$0" --keys &
                    fi
                    # wait for daemon to write its pidfile (up to 3s)
                    local waited=0
                    while [[ $waited -lt 10 ]]; do
                        sleep 0.3
                        (( waited++ ))
                        [[ -f "$KEY_DAEMON_PIDFILE" ]] && \
                            kill -0 "$(cat "$KEY_DAEMON_PIDFILE")" 2>/dev/null && break
                    done
                    ok "Daemon started"
                fi
                # loop back — menu re-checks $running at top
                ;;
            2)
                clear; hdr "Key Daemon Log"
                tail -40 "$KEY_DAEMON_LOG" 2>/dev/null || echo "(no log yet)"
                echo; read -rp "Press enter..."
                ;;
            b) return ;;
        esac
    done
}

# ─── hardware key daemon ──────────────────────────────────────────────────────
# uses python3-evdev to listen on all input devices for key events
# runs as root, but calls wpctl via the logged-in user's session bus

run_key_daemon() {
    [[ $EUID -ne 0 ]] && { err "Key daemon must run as root (use sudo $0 --keys)"; exit 1; }

    # ── guard: exit silently if already running ────────────────────────────────
    if [[ -f "$KEY_DAEMON_PIDFILE" ]]; then
        local _existing_pid
        _existing_pid=$(cat "$KEY_DAEMON_PIDFILE" 2>/dev/null)
        if [[ -n "$_existing_pid" ]] && kill -0 "$_existing_pid" 2>/dev/null; then
            echo "[$(date)] Key daemon already running (pid ${_existing_pid}) — exiting" >> "$KEY_DAEMON_LOG"
            exit 0
        fi
        # stale pidfile — remove it and continue
        rm -f "$KEY_DAEMON_PIDFILE"
    fi

    echo $$ > "$KEY_DAEMON_PIDFILE"
    echo "[$(date)] Key daemon started (pid $$)" >> "$KEY_DAEMON_LOG"

    # find the user running a display/tty session to run wpctl under their bus
    get_session_user() {
        # prefer loginctl active session
        loginctl list-sessions --no-legend 2>/dev/null \
            | awk '$3 != "root" {print $3; exit}' \
            || echo "${SUDO_USER:-}"
    }

    # run a command as the session user with their dbus/pipewire env
    as_user() {
        local user="$1"; shift
        local uid
        uid=$(id -u "$user" 2>/dev/null) || return 1
        local bus="/run/user/${uid}/bus"
        sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="unix:path=${bus}" \
            XDG_RUNTIME_DIR="/run/user/${uid}" "$@"
    }

    # write the python listener inline
    python3 - <<'PYEOF' "$VOLUME_STEP" "$BRIGHTNESS_STEP" "$KEY_DAEMON_LOG"
import sys, subprocess, os, time, glob, signal, threading

vol_step   = sys.argv[1]  # e.g. "5"
bri_step   = sys.argv[2]
log_file   = sys.argv[3]

TMUX_SESSION = "workspaces"
MAX_WORKSPACES = 16

try:
    import evdev
    from evdev import InputDevice, categorize, ecodes
except ImportError:
    print("python3-evdev not installed — run the script without --keys first to install deps", flush=True)
    sys.exit(1)

def log(msg):
    ts = time.strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        with open(log_file, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass

def get_session_user():
    try:
        out = subprocess.check_output(
            ["loginctl", "list-sessions", "--no-legend"],
            text=True
        )
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[2] != "root":
                return parts[2]
    except Exception:
        pass
    return os.environ.get("SUDO_USER") or ""

def as_user(*cmd):
    user = get_session_user()
    if not user:
        log(f"no session user found, running as root")
        return subprocess.run(list(cmd), capture_output=True)
    try:
        uid = int(subprocess.check_output(["id", "-u", user], text=True).strip())
    except Exception:
        uid = None
    env = os.environ.copy()
    if uid:
        env["XDG_RUNTIME_DIR"] = f"/run/user/{uid}"
        env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{uid}/bus"
    return subprocess.run(["sudo", "-u", user] + list(cmd),
                          env=env, capture_output=True)

def vol_up():
    as_user("wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{vol_step}%+")
    log("volume up")

def vol_down():
    as_user("wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", f"{vol_step}%-")
    log("volume down")

def vol_mute():
    as_user("wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle")
    log("volume mute toggle")

def mic_mute():
    as_user("wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle")
    log("mic mute toggle")

def bri_up():
    subprocess.run(["brightnessctl", "set", f"{bri_step}%+", "-q"])
    log("brightness up")

def bri_down():
    subprocess.run(["brightnessctl", "set", f"{bri_step}%-", "-q"])
    log("brightness down")

# ── workspace switching ────────────────────────────────────────────────────────
# chord state: did we just see Ctrl+W?
_ctrl_w_armed = False
_ctrl_w_timer = None
_ctrl_w_lock  = threading.Lock()

def _disarm():
    global _ctrl_w_armed
    with _ctrl_w_lock:
        _ctrl_w_armed = False

def _arm_ctrl_w():
    global _ctrl_w_armed, _ctrl_w_timer
    with _ctrl_w_lock:
        _ctrl_w_armed = True
        if _ctrl_w_timer:
            _ctrl_w_timer.cancel()
        # auto-disarm after 1.5s if no follow-up key
        _ctrl_w_timer = threading.Timer(1.5, _disarm)
        _ctrl_w_timer.start()
    log("Ctrl+W armed — waiting for workspace number")

def _key_to_ws(code):
    """Return workspace number 1-16 from a key code, or None."""
    from evdev import ecodes as e
    mapping = {
        e.KEY_1: 1,  e.KEY_2: 2,  e.KEY_3: 3,  e.KEY_4: 4,
        e.KEY_5: 5,  e.KEY_6: 6,  e.KEY_7: 7,  e.KEY_8: 8,
        e.KEY_9: 9,  e.KEY_0: 10,
        e.KEY_A: 11, e.KEY_B: 12, e.KEY_C: 13,
        e.KEY_D: 14, e.KEY_E: 15, e.KEY_F: 16,
    }
    return mapping.get(code)

def ws_switch(num):
    """Switch to tmux workspace number, creating it if needed."""
    try:
        # find tmux socket — daemon runs as root but tmux session belongs to the user
        user = get_session_user()
        uid = None
        if user:
            try:
                uid = int(subprocess.check_output(["id", "-u", user], text=True).strip())
            except Exception:
                pass

        def tmux_cmd(*args):
            """Run a tmux command, injecting TMUX_TMPDIR so root can reach the user's socket."""
            env = os.environ.copy()
            if uid:
                # tmux default socket lives in /tmp/tmux-<uid>/default
                env["TMUX_TMPDIR"] = f"/tmp/tmux-{uid}"
            return subprocess.run(["tmux"] + list(args), capture_output=True, text=True, env=env)

        def tmux_out(*args):
            env = os.environ.copy()
            if uid:
                env["TMUX_TMPDIR"] = f"/tmp/tmux-{uid}"
            return subprocess.check_output(["tmux"] + list(args), text=True, env=env)

        # check session exists
        r = tmux_cmd("has-session", "-t", TMUX_SESSION)
        if r.returncode != 0:
            log(f"workspace session '{TMUX_SESSION}' not found (uid={uid}) — is workspace.sh running?")
            return

        # check if window exists
        existing = tmux_out("list-windows", "-t", TMUX_SESSION, "-F", "#{window_index}").split()

        if str(num) not in existing:
            total = len(existing)
            if total >= MAX_WORKSPACES:
                log(f"max workspaces reached, cannot create ws{num}")
                return
            tmux_cmd("new-window", "-t", f"{TMUX_SESSION}:{num}", "-n", f"ws{num}")
            log(f"created workspace {num}")

        tmux_cmd("select-window", "-t", f"{TMUX_SESSION}:{num}")
        log(f"switched to workspace {num}")

        # ensure spare in background
        threading.Thread(target=lambda: _ensure_spare(tmux_cmd, tmux_out), daemon=True).start()

    except Exception as ex:
        log(f"ws_switch error: {ex}")

def _ensure_spare(tmux_cmd, tmux_out):
    """Keep at least one idle workspace pre-created."""
    try:
        existing = tmux_out("list-windows", "-t", TMUX_SESSION, "-F", "#{window_index}").split()
        total = len(existing)
        if total >= MAX_WORKSPACES:
            return
        # count idle (no child processes)
        idle = 0
        for idx in existing:
            try:
                pane_pid = subprocess.check_output(
                    ["tmux", "display-message", "-t", f"{TMUX_SESSION}:{idx}",
                     "-p", "#{pane_pid}"],
                    text=True
                ).strip()
                children = subprocess.run(
                    ["pgrep", "-P", pane_pid],
                    capture_output=True, text=True
                ).stdout.strip()
                if not children:
                    idle += 1
            except Exception:
                pass
        if idle < 1:
            # find next free index
            used = set(int(x) for x in existing)
            for i in range(1, MAX_WORKSPACES + 1):
                if i not in used:
                    tmux_cmd("new-window", "-t", f"{TMUX_SESSION}:{i}", "-n", f"ws{i}")
                    log(f"pre-created spare workspace {i}")
                    break
    except Exception as ex:
        log(f"ensure_spare error: {ex}")

# key code → action (for direct keys)
KEY_MAP = {
    ecodes.KEY_VOLUMEUP:         vol_up,
    ecodes.KEY_VOLUMEDOWN:       vol_down,
    ecodes.KEY_MUTE:             vol_mute,
    ecodes.KEY_MICMUTE:          mic_mute,
    ecodes.KEY_BRIGHTNESSUP:     bri_up,
    ecodes.KEY_BRIGHTNESSDOWN:   bri_down,
}

# keys that matter for workspace chord (Ctrl+W then number/letter)
WS_TRIGGER = ecodes.KEY_W
WS_TARGETS = {
    ecodes.KEY_1, ecodes.KEY_2, ecodes.KEY_3, ecodes.KEY_4,
    ecodes.KEY_5, ecodes.KEY_6, ecodes.KEY_7, ecodes.KEY_8,
    ecodes.KEY_9, ecodes.KEY_0,
    ecodes.KEY_A, ecodes.KEY_B, ecodes.KEY_C,
    ecodes.KEY_D, ecodes.KEY_E, ecodes.KEY_F,
}

def find_key_devices():
    devs = []
    # build full set of codes we care about
    all_codes = set(KEY_MAP.keys()) | {WS_TRIGGER} | WS_TARGETS | \
                {ecodes.KEY_LEFTCTRL, ecodes.KEY_RIGHTCTRL}
    for path in glob.glob("/dev/input/event*"):
        try:
            d = InputDevice(path)
            caps = d.capabilities()
            keys = set(caps.get(ecodes.EV_KEY, []))
            if keys & all_codes:
                devs.append(d)
                log(f"listening on {d.name} ({path})")
        except Exception:
            pass
    return devs

devices = find_key_devices()
if not devices:
    log("no suitable input devices found")
    sys.exit(1)

import asyncio

# track ctrl held state
_ctrl_held = False

async def read_device(dev):
    global _ctrl_w_armed, _ctrl_held
    async for event in dev.async_read_loop():
        if event.type != ecodes.EV_KEY:
            continue
        key = categorize(event)

        # track ctrl
        if event.code in (ecodes.KEY_LEFTCTRL, ecodes.KEY_RIGHTCTRL):
            _ctrl_held = (key.keystate != key.key_up)
            continue

        if key.keystate == key.key_down:
            # Ctrl+W arms the chord
            if event.code == WS_TRIGGER and _ctrl_held:
                _arm_ctrl_w()
                continue

            # if armed, next number/letter = workspace switch
            with _ctrl_w_lock:
                armed = _ctrl_w_armed
            if armed and event.code in WS_TARGETS:
                _disarm()
                ws_num = _key_to_ws(event.code)
                if ws_num:
                    threading.Thread(target=ws_switch, args=(ws_num,), daemon=True).start()
                continue

            # regular mapped key
            action = KEY_MAP.get(event.code)
            if action:
                try:
                    action()
                except Exception as e:
                    log(f"error handling key {event.code}: {e}")

async def main():
    await asyncio.gather(*[read_device(d) for d in devices])

asyncio.run(main())
PYEOF
}

# ─── prompt setup ─────────────────────────────────────────────────────────────
# writes a PS1 to ~/.bashrc showing:  user@host : [bat%] : [HH:MM]
#                                     $
setup_prompt() {
    local target_user="${SUDO_USER:-$USER}"
    local bashrc
    bashrc=$(eval echo "~${target_user}/.bashrc")

    local marker="# sysctl-prompt"
    if grep -q "$marker" "$bashrc" 2>/dev/null; then
        warn "Prompt already configured in $bashrc — skipping (remove the $marker block to redo)"
        return
    fi

    # the PS1 function reads battery inline each prompt
    # uses \[ \] around non-printing sequences to keep readline happy
    cat >> "$bashrc" <<'PROMPT'

# sysctl-prompt — managed by sysctl.sh, remove this block to revert
__sysctl_bat() {
    local bat_path
    bat_path=$(ls /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
    if [[ -z "$bat_path" ]]; then
        echo "no bat"
        return
    fi
    local pct status icon
    pct=$(cat "$bat_path")
    status=$(cat "${bat_path/capacity/status}" 2>/dev/null || echo "?")
    case "$status" in
        Charging)    icon="↑" ;;
        Discharging) icon="↓" ;;
        Full)        icon="=" ;;
        *)           icon="?" ;;
    esac
    echo "${pct}%${icon}"
}
__sysctl_prompt() {
    local cyan='\[\033[0;36m\]'
    local yellow='\[\033[1;33m\]'
    local green='\[\033[0;32m\]'
    local bold='\[\033[1m\]'
    local reset='\[\033[0m\]'
    local bat time_str
    bat=$(__sysctl_bat)
    time_str=$(date +%H:%M)
    PS1="${bold}${cyan}\u@\h${reset} : ${yellow}${bat}${reset} : ${green}${time_str}${reset} : ${bold}\w${reset}\n\$ "
}
PROMPT_COMMAND='__sysctl_prompt'
# sysctl-prompt-end
PROMPT

    ok "Prompt configured in $bashrc"
    echo "  Re-open your terminal (or: source $bashrc) to activate"
}

# ─── yes/no prompt helper ─────────────────────────────────────────────────────
_ask_yn() {
    # usage: _ask_yn "Question text" [default: y|n]
    local prompt="$1"
    local default="${2:-y}"
    local hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf "${BOLD}${CYAN}?${RESET} %s %s " "$prompt" "$hint"
        local reply
        read -r reply
        reply="${reply:-$default}"
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "  Please answer y or n." ;;
        esac
    done
}

# ─── motd ─────────────────────────────────────────────────────────────────────
setup_motd() {
    local target_user="${SUDO_USER:-$USER}"
    local home
    home=$(eval echo "~${target_user}")
    local motd_script="${home}/.ttykit-motd"
    local bashrc="${home}/.bashrc"

    cat > "$motd_script" <<'MOTD_SCRIPT'
#!/usr/bin/env bash
# ttykit motd — shown on login

_motd_bat() {
    local p=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)
    local s=$(cat /sys/class/power_supply/BAT*/status   2>/dev/null | head -1)
    [[ -z "$p" ]] && echo "no bat" && return
    local icon; case "$s" in Charging) icon="↑";; Discharging) icon="↓";; Full) icon="⚡";; *) icon="?";; esac
    local bar="" filled=$(( p * 10 / 100 ))
    for ((i=0;i<filled;i++));  do bar+="█"; done
    for ((i=filled;i<10;i++)); do bar+="░"; done
    echo "[${bar}] ${p}%${icon} ${s}"
}

_motd_net() {
    local conn ip
    conn=$(nmcli -t -f NAME,STATE connection show --active 2>/dev/null \
        | grep ":activated" | head -1 | cut -d: -f1)
    ip=$(ip -4 -brief addr show up 2>/dev/null \
        | awk '$1!="lo"{print $3;exit}' | cut -d/ -f1)
    if [[ -n "$conn" ]]; then
        echo "${conn}  ${ip:-no ip}"
    else
        local wifi_state
        wifi_state=$(nmcli radio wifi 2>/dev/null | head -1)
        echo "offline (wifi: ${wifi_state:-?})"
    fi
}

_motd_ws() {
    local session="workspaces"
    if tmux has-session -t "$session" 2>/dev/null; then
        local wins
        wins=$(tmux list-windows -t "$session" -F "#{window_index}" 2>/dev/null | tr '\n' ' ')
        echo "active  [${wins% }]"
    else
        echo "not started"
    fi
}

R='\033[0m'; BD='\033[1m'; DIM='\033[2m'
C1='\033[38;5;39m'   # sky blue
C2='\033[38;5;87m'   # cyan
C3='\033[38;5;245m'  # grey
CG='\033[38;5;83m'   # green
CY='\033[38;5;228m'  # yellow

# ── banner ────────────────────────────────────────────────────────────────────
echo -e "${C1}${BD}"
echo '  ████████╗████████╗██╗   ██╗██╗  ██╗██╗████████╗'
echo '     ██╔══╝╚══██╔══╝╚██╗ ██╔╝██║ ██╔╝██║╚══██╔══╝'
echo '     ██║      ██║    ╚████╔╝ █████╔╝ ██║   ██║   '
echo '     ██║      ██║     ╚██╔╝  ██╔═██╗ ██║   ██║   '
echo '     ██║      ██║      ██║   ██║  ██╗██║   ██║   '
echo '     ╚═╝      ╚═╝      ╚═╝   ╚═╝  ╚═╝╚═╝   ╚═╝   '
echo -e "${R}"

# ── stats ─────────────────────────────────────────────────────────────────────
local_ip=$(_motd_net)
bat_info=$(_motd_bat)
ws_info=$(_motd_ws)
uptime_str=$(uptime -p 2>/dev/null | sed 's/up //')
load_str=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
kernel=$(uname -r)
now=$(date '+%a %d %b  %H:%M')

echo -e "  ${C3}┌──────────────────────────────────────────┐${R}"
printf  "  ${C3}│${R}  ${BD}%-14s${R}  ${CG}%-26s${C3}│${R}\n" "host"     "$(hostname)"
printf  "  ${C3}│${R}  ${BD}%-14s${R}  ${CY}%-26s${C3}│${R}\n" "time"     "$now"
printf  "  ${C3}│${R}  ${BD}%-14s${R}  %-26s${C3}│${R}\n"      "uptime"   "$uptime_str"
printf  "  ${C3}│${R}  ${BD}%-14s${R}  %-26s${C3}│${R}\n"      "load"     "$load_str"
printf  "  ${C3}│${R}  ${BD}%-14s${R}  %-26s${C3}│${R}\n"      "kernel"   "$kernel"
echo -e "  ${C3}├──────────────────────────────────────────┤${R}"
printf  "  ${C3}│${R}  ${BD}%-14s${R}  %-26s${C3}│${R}\n"      "network"  "$local_ip"
printf  "  ${C3}│${R}  ${BD}%-14s${R}  %-26s${C3}│${R}\n"      "battery"  "$bat_info"
printf  "  ${C3}│${R}  ${BD}%-14s${R}  %-26s${C3}│${R}\n"      "workspaces" "$ws_info"
echo -e "  ${C3}└──────────────────────────────────────────┘${R}"
echo -e "  ${DIM}Ctrl+W → 1-9/0/a-f   switch workspace${R}"
echo -e "  ${DIM}./sysctl.sh           system controls${R}"
echo
MOTD_SCRIPT

    chmod +x "$motd_script"
    chown "${target_user}:${target_user}" "$motd_script" 2>/dev/null || true

    local marker="# ttykit-motd"
    if ! grep -q "$marker" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" <<BASHRC

${marker}
[[ -f "${motd_script}" ]] && bash "${motd_script}"
# ttykit-motd-end
BASHRC
        ok "MOTD installed → ${motd_script}"
        echo "  Will show on every new login shell"
    else
        warn "MOTD already configured in $bashrc — skipping"
    fi
}

# ─── ttykit self-install ──────────────────────────────────────────────────────
# Copies sysctl.sh to ~/.local/bin/.ttykit-bin/sysctl.sh and creates a symlink
# at ~/.local/bin/ttykit pointing to it.  Also wires the key daemon into .bashrc.
setup_ttykit() {
    local target_user="${SUDO_USER:-$USER}"
    local home
    home=$(eval echo "~${target_user}")
    local bin_dir="${home}/.local/bin"
    # Store the actual script in a dot-prefixed subdir so its name never
    # collides with the ~/.local/bin/ttykit symlink we create alongside it.
    local kit_dir="${bin_dir}/.ttykit-bin"
    local script_dst="${kit_dir}/sysctl.sh"
    local symlink_dst="${bin_dir}/ttykit"

    # resolve the actual path of the currently running script
    local script_src
    script_src=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}")

    mkdir -p "$kit_dir"
    chown "${target_user}:${target_user}" "$kit_dir" 2>/dev/null || true

    # copy the script into the kit dir
    install -m 755 "$script_src" "$script_dst"
    chown "${target_user}:${target_user}" "$script_dst" 2>/dev/null || true
    ok "Installed → ${script_dst}"

    # create / update the ~/.local/bin/ttykit symlink
    # If a real directory exists there we cannot overwrite it with ln — warn and bail.
    if [[ -d "$symlink_dst" && ! -L "$symlink_dst" ]]; then
        warn "Cannot create symlink at ${symlink_dst} — a real directory exists there."
        warn "Remove it manually first: rm -rf ${symlink_dst}"
        return 1
    fi
    rm -f "$symlink_dst"   # remove stale symlink or stale file
    ln -sf "$script_dst" "$symlink_dst"
    chown -h "${target_user}:${target_user}" "$symlink_dst" 2>/dev/null || true
    ok "Symlink → ${symlink_dst} → ${script_dst}"

    # ensure ~/.local/bin is on PATH in .bashrc
    local bashrc="${home}/.bashrc"
    local path_marker="# ttykit-path"
    if ! grep -q "$path_marker" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" <<BASHRC

${path_marker}
export PATH="\${HOME}/.local/bin:\${PATH}"
# ttykit-path-end
BASHRC
        ok "Added ~/.local/bin to PATH in ${bashrc}"
    fi

    # wire the key daemon autostart into .bashrc
    local daemon_marker="# ttykit-keydaemon"
    if ! grep -q "$daemon_marker" "$bashrc" 2>/dev/null; then
        # Use printf to avoid heredoc variable-expansion and nested-quote issues.
        # $script_dst and $KEY_DAEMON_PIDFILE are expanded NOW (correct — we want
        # the installed path baked in); $() and $? must be literal in the shell
        # code we're writing, so they are escaped.
        printf '\n%s\n' "$daemon_marker" >> "$bashrc"
        printf '# Auto-start hardware key daemon (only if not already running)\n' >> "$bashrc"
        printf 'if [[ -f "%s" ]] && kill -0 "$(cat "%s" 2>/dev/null)" 2>/dev/null; then\n' \
            "$KEY_DAEMON_PIDFILE" "$KEY_DAEMON_PIDFILE" >> "$bashrc"
        printf '    : # already running\n' >> "$bashrc"
        printf 'else\n' >> "$bashrc"
        printf '    sudo "%s" --keys &>/dev/null &\n' "$script_dst" >> "$bashrc"
        printf 'fi\n' >> "$bashrc"
        printf '# ttykit-keydaemon-end\n' >> "$bashrc"
        ok "Key daemon autostart added to ${bashrc}"
    else
        warn "Key daemon autostart already in ${bashrc} — skipping"
    fi
}

# ─── first-run ────────────────────────────────────────────────────────────────
first_run() {
    [[ $EUID -ne 0 ]] && { err "Run --firstrun with sudo"; exit 1; }

    echo
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════╗"
    echo -e "║       ttykit  first-run          ║"
    echo -e "╚══════════════════════════════════╝${RESET}"
    echo

    # ── step 1: packages ────────────────────────────────────────────────────
    echo -e "${BOLD}Step 1/4 — System packages${RESET}"
    echo "  Will install: brightnessctl alsa-utils wireplumber pipewire-utils"
    echo "                NetworkManager fzf python3 tmux python3-evdev newt"
    echo "                pipewire-pulse  + bluetuith from GitHub"
    echo
    if _ask_yn "Install packages and system deps?"; then
        install_deps
    else
        warn "Skipping package install — some features may not work"
    fi
    echo

    # ── step 2: ttykit self-install ─────────────────────────────────────────
    echo -e "${BOLD}Step 2/4 — Install / update ttykit${RESET}"
    local target_user="${SUDO_USER:-$USER}"
    local home; home=$(eval echo "~${target_user}")
    local kit_dir="${home}/.local/bin/.ttykit-bin"
    local script_dst="${kit_dir}/sysctl.sh"
    if [[ -f "$script_dst" ]]; then
        echo "  ttykit is already installed at ${script_dst}."
        echo "  Choosing 'yes' will overwrite it with this version."
        if _ask_yn "Overwrite / update ttykit?"; then
            setup_ttykit
        else
            warn "Skipping ttykit install"
        fi
    else
        echo "  Copies this script to ~/.local/bin/ttykit/sysctl.sh,"
        echo "  creates a ~/.local/bin/ttykit symlink, and wires the key"
        echo "  daemon to start automatically on login."
        echo
        if _ask_yn "Install ttykit to ~/.local/bin?"; then
            setup_ttykit
        else
            warn "Skipping ttykit install"
        fi
    fi
    echo

    # ── step 3: prompt ──────────────────────────────────────────────────────
    echo -e "${BOLD}Step 3/4 — Custom bash prompt${RESET}"
    echo "  Adds a prompt showing:  user@host : battery% : HH:MM : cwd"
    echo
    if _ask_yn "Set up custom bash prompt?"; then
        setup_prompt
    else
        warn "Skipping prompt setup"
    fi
    echo

    # ── step 4: motd ────────────────────────────────────────────────────────
    echo -e "${BOLD}Step 4/4 — Login MOTD${RESET}"
    echo "  Adds a status banner (host, time, battery, network, workspaces)"
    echo "  shown every time you open a new terminal."
    echo
    if _ask_yn "Install MOTD?"; then
        setup_motd
    else
        warn "Skipping MOTD setup"
    fi
    echo

    ok "First-run complete. Open a new shell to see your changes."
}

# ─── quick info commands ───────────────────────────────────────────────────────
info_bat() {
    hdr "Battery"
    local found=0
    for bat_dir in /sys/class/power_supply/BAT*/; do
        [[ -d "$bat_dir" ]] || continue
        found=1
        local name pct status capacity_full capacity_now power_now time_str=""
        name=$(basename "$bat_dir")
        pct=$(cat "$bat_dir/capacity" 2>/dev/null || echo "?")
        status=$(cat "$bat_dir/status"   2>/dev/null || echo "?")
        capacity_now=$(cat "$bat_dir/charge_now"  2>/dev/null \
                    || cat "$bat_dir/energy_now"  2>/dev/null || echo "")
        capacity_full=$(cat "$bat_dir/charge_full" 2>/dev/null \
                     || cat "$bat_dir/energy_full" 2>/dev/null || echo "")
        power_now=$(cat "$bat_dir/current_now" 2>/dev/null \
                 || cat "$bat_dir/power_now"   2>/dev/null || echo "")

        # estimate time remaining
        if [[ -n "$capacity_now" && -n "$power_now" && "$power_now" -gt 0 ]] 2>/dev/null; then
            local mins
            case "$status" in
                Discharging)
                    mins=$(( capacity_now * 60 / power_now ))
                    time_str="~$((mins/60))h $((mins%60))m remaining"
                    ;;
                Charging)
                    local empty=$(( capacity_full - capacity_now ))
                    mins=$(( empty * 60 / power_now ))
                    time_str="~$((mins/60))h $((mins%60))m to full"
                    ;;
            esac
        fi

        # draw a little bar
        local bar_len=20 filled
        filled=$(( pct * bar_len / 100 ))
        local bar=""
        for ((i=0; i<filled; i++));    do bar+="█"; done
        for ((i=filled; i<bar_len; i++)); do bar+="░"; done

        printf "  %-10s  [%s] %s%%\n" "$name" "$bar" "$pct"
        printf "  %-10s  Status: %s\n"  "" "$status"
        [[ -n "$time_str" ]] && printf "  %-10s  %s\n" "" "$time_str"
        echo
    done
    [[ $found -eq 0 ]] && echo "  No battery found"
}

info_audio() {
    hdr "Audio"
    local vol mute sink_name
    vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '{printf "%d", $2*100}')
    mute=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q MUTED && echo "MUTED" || echo "unmuted")
    # get sink description (friendly name)
    sink_name=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
        | grep -i "node.description\|node.nick\|media.name" \
        | head -1 | sed 's/.*= "\(.*\)"/\1/')
    [[ -z "$sink_name" ]] && sink_name="(unknown)"

    local mic_mute
    mic_mute=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null \
        | grep -q MUTED && echo "MUTED" || echo "unmuted")

    # volume bar
    local bar_len=20 filled
    filled=$(( vol * bar_len / 100 ))
    local bar=""
    for ((i=0; i<filled; i++));       do bar+="█"; done
    for ((i=filled; i<bar_len; i++)); do bar+="░"; done

    printf "  Sink    : %s\n"    "$sink_name"
    printf "  Volume  : [%s] %s%%\n" "$bar" "$vol"
    printf "  Output  : %s\n"    "$mute"
    printf "  Mic     : %s\n"    "$mic_mute"
    echo
}

info_net() {
    hdr "Network"
    # active connections
    local conns
    conns=$(nmcli -t -f NAME,TYPE,DEVICE,STATE connection show --active 2>/dev/null \
        | grep ":activated")
    if [[ -z "$conns" ]]; then
        echo "  Not connected"
    else
        while IFS=: read -r name type device state _; do
            local ip gw
            ip=$(ip -4 -brief addr show "$device" 2>/dev/null \
                | awk '{print $3}' | cut -d/ -f1)
            gw=$(ip route show default dev "$device" 2>/dev/null \
                | awk '{print $3}' | head -1)
            printf "  %-20s  dev=%-8s  ip=%-16s  gw=%s\n" \
                "$name" "$device" "${ip:--}" "${gw:--}"
        done <<< "$conns"
    fi

    # wifi signal if applicable
    local wifi_info
    wifi_info=$(nmcli -t -f ACTIVE,SSID,SIGNAL,BARS device wifi list 2>/dev/null \
        | grep "^yes:" | head -1)
    if [[ -n "$wifi_info" ]]; then
        local ssid signal bars
        IFS=: read -r _ ssid signal bars _ <<< "$wifi_info"
        printf "  WiFi    : %s  %s  %s%%\n" "$ssid" "$bars" "$signal"
    fi
    echo
}

info_bt() {
    hdr "Bluetooth"
    local powered
    powered=$(bluetoothctl show 2>/dev/null | awk '/Powered/{print $2}')
    printf "  Powered : %s\n" "${powered:-?}"
    if [[ "$powered" == "yes" ]]; then
        local devices
        devices=$(bluetoothctl info 2>/dev/null | grep -E "Name:|Connected:" \
            | paste - - | awk '{printf "  %-30s  %s\n", $2, $4}')
        if [[ -n "$devices" ]]; then
            echo "  Connected devices:"
            echo "$devices"
        else
            echo "  No devices connected"
        fi
    fi
    echo
}

info_bri() {
    hdr "Brightness"
    local pct cur max device
    pct=$(brightnessctl -m 2>/dev/null | awk -F, '{gsub(/%/,"",$4); print int($4)}')
    cur=$(brightnessctl -m 2>/dev/null | awk -F, '{print $3}')
    max=$(brightnessctl -m 2>/dev/null | awk -F, '{print $5}')
    device=$(brightnessctl -m 2>/dev/null | awk -F, '{print $1}')

    local bar_len=20 filled
    filled=$(( ${pct:-0} * bar_len / 100 ))
    local bar=""
    for ((i=0; i<filled; i++));       do bar+="█"; done
    for ((i=filled; i<bar_len; i++)); do bar+="░"; done

    printf "  Device  : %s\n"           "${device:-(unknown)}"
    printf "  Level   : [%s] %s%%\n"    "$bar" "${pct:-?}"
    printf "  Raw     : %s / %s\n"      "${cur:-?}" "${max:-?}"
    echo
}

info_all() {
    info_bat
    info_audio
    info_bri
    info_net
    info_bt
}


main_menu() {
    while true; do
        show_status

        local choice
        choice=$(whiptail --title "✦ sysctl ✦" \
            --menu "What do you want to manage?" 18 55 6 \
            "1" "🔊  Audio" \
            "2" "💡  Brightness" \
            "3" "🌐  Networking" \
            "4" "🔵  Bluetooth" \
            "5" "⌨️   Hardware key daemon" \
            "q" "Quit" \
            3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
            1) menu_audio      ;;
            2) menu_brightness ;;
            3) menu_network    ;;
            4) menu_bluetooth  ;;
            5) menu_keydaemon  ;;
            q) exit 0          ;;
        esac
    done
}

# ─── entrypoint ───────────────────────────────────────────────────────────────
case "${1:-}" in
    --firstrun) first_run      ;;
    --keys)     run_key_daemon ;;
    bat)        info_bat       ;;
    audio)      info_audio     ;;
    net)        info_net       ;;
    bt)         info_bt        ;;
    bri)        info_bri       ;;
    all)        info_all       ;;
    "")         main_menu      ;;
    *)
        echo "usage: $0 [--firstrun | --keys | bat | audio | net | bt | bri | all]"
        exit 1
        ;;
esac
