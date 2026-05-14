#!/usr/bin/env bash
# =============================================================================
# setup-novnc.sh — Install and launch noVNC desktop on a GitHub Codespace
#
# Stack:
#   Xvfb  (virtual display)  → display :1
#   XFCE4 (lightweight DE)
#   x11vnc                   → VNC on 127.0.0.1:5901
#   noVNC + websockify        → browser UI on 0.0.0.0:6080
#
# Usage:
#   bash setup-novnc.sh [--password <vnc-password>] [--no-desktop]
#   Then open the forwarded port 6080 in your Codespace browser.
# =============================================================================
set -euo pipefail

# ---------- defaults ---------------------------------------------------------
VNC_DISPLAY=":1"
VNC_PORT=5901
NOVNC_PORT=6080
VNC_RESOLUTION="1920x1080"
VNC_DEPTH=24
VNC_PASSWORD=""
INSTALL_DESKTOP=true

# ---------- argument parsing --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --password)   VNC_PASSWORD="$2";    shift 2 ;;
    --no-desktop) INSTALL_DESKTOP=false; shift   ;;
    --port)       NOVNC_PORT="$2";      shift 2  ;;
    --resolution) VNC_RESOLUTION="$2";  shift 2  ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------- helpers -----------------------------------------------------------
log()  { echo -e "\033[1;34m[novnc]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m  $*"; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }

# ---------- checks ------------------------------------------------------------
[[ $(id -u) -eq 0 ]] || die "Run as root (sudo bash $0)"

log "Updating package list …"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# ---------- core dependencies -------------------------------------------------
log "Installing Xvfb, x11vnc, and noVNC dependencies …"
apt-get install -y --no-install-recommends \
  xvfb \
  x11vnc \
  novnc \
  websockify \
  xterm \
  dbus-x11 \
  x11-utils \
  2>/dev/null || true

# ---------- desktop environment -----------------------------------------------
if $INSTALL_DESKTOP; then
  log "Installing XFCE4 desktop (lightweight) …"
  apt-get install -y --no-install-recommends \
    xfce4 \
    xfce4-terminal \
    xfce4-taskmanager \
    xfce4-screenshooter \
    mousepad \
    thunar \
    2>/dev/null || true
fi

# ---------- Google Chrome -----------------------------------------------------
log "Installing Google Chrome …"
apt-get install -y --no-install-recommends wget gnupg ca-certificates 2>/dev/null || true
wget -qO /tmp/google-chrome.deb \
  "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
apt-get install -y --no-install-recommends /tmp/google-chrome.deb 2>/dev/null || \
  apt-get install -f -y 2>/dev/null || true
rm -f /tmp/google-chrome.deb
# Wrapper: auto-add --no-sandbox so Chrome works as root
cat > /usr/local/bin/google-chrome <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/google-chrome-stable --no-sandbox --disable-setuid-sandbox "$@"
EOF
chmod +x /usr/local/bin/google-chrome
log "Google Chrome installed."

# ---------- VS Code -----------------------------------------------------------
log "Installing Visual Studio Code …"
wget -qO /tmp/vscode.deb \
  "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64"
apt-get install -y --no-install-recommends /tmp/vscode.deb 2>/dev/null || \
  apt-get install -f -y 2>/dev/null || true
rm -f /tmp/vscode.deb
# Wrapper: auto-add --no-sandbox so VS Code works as root
cat > /usr/local/bin/code <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/code --no-sandbox --user-data-dir /root/.vscode-root "$@"
EOF
chmod +x /usr/local/bin/code
log "VS Code installed."

# ---------- optional: websockify via pip if system package is missing ---------
if ! command -v websockify &>/dev/null; then
  warn "websockify not found in PATH – installing via pip3 …"
  apt-get install -y --no-install-recommends python3-pip 2>/dev/null || true
  pip3 install --quiet websockify
fi

# ---------- noVNC path detection ----------------------------------------------
NOVNC_PATH=""
for candidate in \
  /usr/share/novnc \
  /usr/local/share/novnc \
  /opt/novnc; do
  [[ -f "$candidate/vnc.html" || -f "$candidate/vnc_lite.html" ]] && { NOVNC_PATH="$candidate"; break; }
done

if [[ -z "$NOVNC_PATH" ]]; then
  log "noVNC web files not found via apt – cloning from GitHub …"
  git clone --depth 1 https://github.com/novnc/noVNC.git /opt/novnc 2>/dev/null
  NOVNC_PATH="/opt/novnc"
fi
log "noVNC path: $NOVNC_PATH"

# ---------- VNC password ------------------------------------------------------
VNC_PASSWD_FILE="/tmp/vnc-passwd"
if [[ -n "$VNC_PASSWORD" ]]; then
  log "Setting VNC password …"
  # x11vnc uses a plaintext or obfuscated passwd file
  x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASSWD_FILE"
fi

# ---------- kill any leftover processes ---------------------------------------
log "Stopping any previous Xvfb / x11vnc / websockify processes …"
pkill -f "Xvfb $VNC_DISPLAY"   2>/dev/null || true
pkill -f "x11vnc.*:${VNC_PORT#:}" 2>/dev/null || true
pkill -f "websockify.*$NOVNC_PORT" 2>/dev/null || true
sleep 1

# ---------- start Xvfb -------------------------------------------------------
log "Starting Xvfb on display $VNC_DISPLAY (${VNC_RESOLUTION}) …"
Xvfb $VNC_DISPLAY \
  -screen 0 "${VNC_RESOLUTION}x${VNC_DEPTH}" \
  -ac \
  +extension GLX \
  +render \
  -noreset \
  &>/tmp/xvfb.log &
XVFB_PID=$!
sleep 2

# Verify Xvfb started
kill -0 $XVFB_PID 2>/dev/null || die "Xvfb failed to start. Check /tmp/xvfb.log"
log "Xvfb started (PID $XVFB_PID)"

# ---------- start desktop environment ----------------------------------------
export DISPLAY=$VNC_DISPLAY
if $INSTALL_DESKTOP; then
  log "Starting XFCE4 session …"
  dbus-launch --exit-with-session startxfce4 &>/tmp/xfce4.log &
  sleep 3
else
  log "Starting bare xterm (--no-desktop mode) …"
  xterm &>/tmp/xterm.log &
fi

# ---------- start x11vnc ------------------------------------------------------
log "Starting x11vnc on 127.0.0.1:${VNC_PORT} …"
X11VNC_ARGS=(
  -display $VNC_DISPLAY
  -rfbport $VNC_PORT
  -localhost
  -noxdamage
  -forever
  -shared
  -bg
  -o /tmp/x11vnc.log
)

if [[ -n "$VNC_PASSWORD" && -f "$VNC_PASSWD_FILE" ]]; then
  X11VNC_ARGS+=(-rfbauth "$VNC_PASSWD_FILE")
else
  X11VNC_ARGS+=(-nopw)
fi

x11vnc "${X11VNC_ARGS[@]}"
sleep 2

# Verify x11vnc is listening
if ! ss -tlnp 2>/dev/null | grep -q ":${VNC_PORT}" && \
   ! netstat -tlnp 2>/dev/null | grep -q ":${VNC_PORT}"; then
  warn "x11vnc port ${VNC_PORT} not detected – check /tmp/x11vnc.log"
fi
log "x11vnc started"

# ---------- start noVNC / websockify ------------------------------------------
NOVNC_INDEX=""
for candidate in "$NOVNC_PATH/vnc.html" "$NOVNC_PATH/vnc_lite.html"; do
  [[ -f "$candidate" ]] && { NOVNC_INDEX=$(basename "$candidate"); break; }
done

log "Starting noVNC (websockify) on 0.0.0.0:${NOVNC_PORT} …"
websockify \
  --web "$NOVNC_PATH" \
  --log-file /tmp/websockify.log \
  "$NOVNC_PORT" \
  "127.0.0.1:${VNC_PORT}" \
  &
WEBSOCKIFY_PID=$!
sleep 2

kill -0 $WEBSOCKIFY_PID 2>/dev/null || die "websockify failed to start. Check /tmp/websockify.log"
log "websockify started (PID $WEBSOCKIFY_PID)"

# ---------- write a stop helper -----------------------------------------------
cat > /tmp/stop-novnc.sh <<'STOP'
#!/usr/bin/env bash
pkill -f 'Xvfb :1'       2>/dev/null; echo "Xvfb stopped"
pkill -f 'x11vnc'         2>/dev/null; echo "x11vnc stopped"
pkill -f 'websockify'     2>/dev/null; echo "websockify stopped"
pkill -f 'startxfce4'     2>/dev/null; echo "XFCE stopped"
STOP
chmod +x /tmp/stop-novnc.sh

# ---------- summary -----------------------------------------------------------
log "======================================================"
log "  noVNC is running!"
log ""
log "  Browser URL (Codespace port forward):"
log "    http://localhost:${NOVNC_PORT}/${NOVNC_INDEX}"
log ""
log "  In VS Code / Codespace:"
log "    Open the PORTS tab and forward port ${NOVNC_PORT}"
log "    Then click the globe icon to open in browser."
log ""
if [[ -n "$VNC_PASSWORD" ]]; then
  log "  VNC password is set (as provided)."
else
  warn "  No VNC password set (open to anyone who can reach port ${NOVNC_PORT})."
fi
log ""
log "  Installed apps (launch from XFCE desktop or terminal):"
log "    Google Chrome → google-chrome-stable --no-sandbox"
log "    VS Code       → code --no-sandbox"
log ""
log "  Logs:"
log "    Xvfb    → /tmp/xvfb.log"
log "    XFCE    → /tmp/xfce4.log"
log "    x11vnc  → /tmp/x11vnc.log"
log "    noVNC   → /tmp/websockify.log"
log ""
log "  To stop everything:  bash /tmp/stop-novnc.sh"
log "======================================================"
