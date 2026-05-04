#!/usr/bin/env bash
# workspace.sh — tmux-backed bash workspaces
#
# add to ~/.bashrc to enable:
#   source /path/to/workspace.sh
#
# or run directly:
#   bash workspace.sh
#
# switching: Ctrl+W then 1-9, 0 (=10), a-f (=11-16)
# the key daemon (sysctl.sh --keys) handles switching from any workspace

set -euo pipefail

TMUX_SESSION="workspaces"
MAX_WORKSPACES=16
SPARE=1        # always keep this many empty workspaces pre-created
WS_LOG="/tmp/workspace.log"

# ─── helpers ──────────────────────────────────────────────────────────────────
_ws_log() { echo "[$(date +%H:%M:%S)] $*" >> "$WS_LOG"; }

# map workspace number (1-16) to tmux window index (same number)
_ws_index() { echo "$1"; }

# map key character to workspace number
# 1-9 → 1-9, 0 → 10, a → 11, b → 12 ... f → 16
ws_key_to_num() {
    local key="$1"
    case "$key" in
        [1-9]) echo "$key" ;;
        0)     echo "10"   ;;
        a)     echo "11"   ;;
        b)     echo "12"   ;;
        c)     echo "13"   ;;
        d)     echo "14"   ;;
        e)     echo "15"   ;;
        f)     echo "16"   ;;
        *)     echo ""     ;;
    esac
}

# ─── tmux session management ──────────────────────────────────────────────────

# check if our session exists
_session_exists() {
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null
}

# list all window indices in session
_ws_list() {
    tmux list-windows -t "$TMUX_SESSION" -F "#{window_index}" 2>/dev/null || true
}

# count existing windows
_ws_count() {
    _ws_list | wc -l
}

# get current window index
_ws_current() {
    tmux display-message -t "$TMUX_SESSION" -p "#{window_index}" 2>/dev/null || echo "1"
}

# create a new workspace at the next available index, return its index
_ws_create() {
    local total
    total=$(_ws_count)
    if [[ $total -ge $MAX_WORKSPACES ]]; then
        _ws_log "max workspaces ($MAX_WORKSPACES) reached"
        return 1
    fi

    # find lowest unused index 1-16
    local idx
    local existing
    existing=$(_ws_list)
    for idx in $(seq 1 $MAX_WORKSPACES); do
        if ! echo "$existing" | grep -qx "$idx"; then
            break
        fi
    done

    tmux new-window -t "${TMUX_SESSION}:${idx}" -n "ws${idx}" \; \
        send-keys -t "${TMUX_SESSION}:${idx}" "" "" 2>/dev/null || true
    _ws_log "created workspace $idx"
    echo "$idx"
}

# ensure at least SPARE empty (idle) workspaces exist
_ws_ensure_spare() {
    local existing total
    total=$(_ws_count)
    [[ $total -ge $MAX_WORKSPACES ]] && return

    # count windows with no running process other than bash
    local idle=0
    while IFS= read -r idx; do
        local pane_pid pane_cmd
        pane_pid=$(tmux display-message -t "${TMUX_SESSION}:${idx}" -p "#{pane_pid}" 2>/dev/null || true)
        if [[ -n "$pane_pid" ]]; then
            # children of the pane shell — if none, it's idle
            local children
            children=$(pgrep -P "$pane_pid" 2>/dev/null | wc -l)
            [[ $children -eq 0 ]] && (( idle++ ))
        fi
    done < <(_ws_list)

    local needed=$(( SPARE - idle ))
    for (( i=0; i<needed; i++ )); do
        _ws_create >/dev/null 2>&1 || break
    done
}

# switch to workspace number $1, creating it if needed
ws_switch() {
    local num="$1"
    [[ -z "$num" || $num -lt 1 || $num -gt $MAX_WORKSPACES ]] && return 1

    if ! _session_exists; then
        _ws_log "session not running, cannot switch"
        return 1
    fi

    local existing
    existing=$(_ws_list)
    if ! echo "$existing" | grep -qx "$num"; then
        # create at exactly this index
        local total
        total=$(_ws_count)
        [[ $total -ge $MAX_WORKSPACES ]] && { _ws_log "max workspaces reached"; return 1; }
        tmux new-window -t "${TMUX_SESSION}:${num}" -n "ws${num}" 2>/dev/null || return 1
        _ws_log "created workspace $num on demand"
    fi

    tmux select-window -t "${TMUX_SESSION}:${num}" 2>/dev/null
    _ws_log "switched to workspace $num"
    _ws_ensure_spare &
}

# ─── status line override ──────────────────────────────────────────────────────
# sets tmux window-status to show ws number cleanly, no other tmux chrome
_ws_configure_tmux() {
    # minimal tmux config — no status bar except our own line
    tmux set-option  -t "$TMUX_SESSION" status on
    tmux set-option  -t "$TMUX_SESSION" status-position bottom
    tmux set-option  -t "$TMUX_SESSION" status-style "bg=black,fg=colour240"
    tmux set-option  -t "$TMUX_SESSION" status-left ""
    tmux set-option  -t "$TMUX_SESSION" status-right ""
    tmux set-option  -t "$TMUX_SESSION" status-justify centre
    tmux set-option  -t "$TMUX_SESSION" window-status-format \
        "#[fg=colour240] #{window_index} "
    tmux set-option  -t "$TMUX_SESSION" window-status-current-format \
        "#[fg=colour255,bold,bg=colour236] #{window_index} "
    tmux set-option  -t "$TMUX_SESSION" window-status-separator ""
    # disable all tmux key bindings so Ctrl+W etc pass through to our daemon
    tmux set-option  -t "$TMUX_SESSION" prefix None
    tmux set-option  -t "$TMUX_SESSION" prefix2 None
    tmux unbind-key  -a -T prefix 2>/dev/null || true
    # allow the terminal to set titles
    tmux set-option  -t "$TMUX_SESSION" set-titles off
    # no bells
    tmux set-option  -t "$TMUX_SESSION" bell-action none
    tmux set-option  -t "$TMUX_SESSION" visual-bell off
}

# ─── entry point ──────────────────────────────────────────────────────────────
_ws_start() {
    # if already inside our session, do nothing (idempotent source)
    if [[ -n "${TMUX:-}" ]]; then
        local current_session
        current_session=$(tmux display-message -p "#S" 2>/dev/null || true)
        if [[ "$current_session" == "$TMUX_SESSION" ]]; then
            # already inside — just make sure spare exists
            _ws_ensure_spare &
            return 0
        fi
    fi

    if _session_exists; then
        # session exists, reattach
        _ws_log "reattaching to existing session"
        exec tmux attach-session -t "$TMUX_SESSION"
    else
        # fresh start — create session with window 1
        _ws_log "creating new session"
        tmux new-session -d -s "$TMUX_SESSION" -n "ws1" -x "$(tput cols)" -y "$(tput lines)"
        _ws_configure_tmux
        # pre-create the spare
        _ws_ensure_spare
        exec tmux attach-session -t "$TMUX_SESSION"
    fi
}

_ws_start
