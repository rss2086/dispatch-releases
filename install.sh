#!/usr/bin/env bash
# Dispatch one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/rss2086/dispatch-releases/main/install.sh | bash
#
# Installs the dispatchd single binary, starts it as a service, and prints the
# pairing card (server URL + token) to add this box in the Dispatch app.
# Idempotent: re-running upgrades the binary and leaves token/state alone.
# The binary itself extracts agent hooks and wires ~/.claude/settings.json on
# boot, so this script's job is only: binary on disk, process supervised.
set -euo pipefail

REPO="${DISPATCH_RELEASES_REPO:-rss2086/dispatch-releases}"
PORT="${DISPATCH_PORT:-4000}"

say()  { printf '\033[1m[dispatch]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[dispatch]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "dispatchd runs on Linux boxes (this is $(uname -s))"
case "$(uname -m)" in
  x86_64|amd64)  ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) fail "unsupported arch: $(uname -m)" ;;
esac

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then SUDO="sudo"; fi
fi

# --- dependencies the agents need at runtime (the server itself needs none) ---
missing=""
for dep in curl tmux git jq; do command -v "$dep" >/dev/null || missing="$missing $dep"; done
if [ -n "$missing" ]; then
  say "installing dependencies:$missing"
  if command -v apt-get >/dev/null && [ -n "$SUDO$([ "$(id -u)" = 0 ] && echo root)" ]; then
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq $missing
  elif command -v dnf >/dev/null; then $SUDO dnf install -y -q $missing
  elif command -v apk >/dev/null; then $SUDO apk add -q $missing
  else fail "please install$missing and re-run"
  fi
fi

# --- binary ---
if [ -w /usr/local/bin ] || [ -n "$SUDO" ]; then BIN_DIR=/usr/local/bin; else BIN_DIR="$HOME/.local/bin"; mkdir -p "$BIN_DIR"; fi
BIN="$BIN_DIR/dispatchd"
URL="https://github.com/$REPO/releases/latest/download/dispatchd-linux-$ARCH"
say "downloading dispatchd-linux-$ARCH from $REPO"
TMP="$(mktemp)"
curl -fSL --progress-bar "$URL" -o "$TMP"
curl -fsSL "https://github.com/$REPO/releases/latest/download/checksums.txt" -o "$TMP.sums"
WANT="$(grep "dispatchd-linux-$ARCH\$" "$TMP.sums" | awk '{print $1}')"
GOT="$(sha256sum "$TMP" | awk '{print $1}')"
[ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || fail "checksum mismatch — refusing to install"
chmod 755 "$TMP"
${SUDO:+$SUDO }mv "$TMP" "$BIN"
rm -f "$TMP.sums"
say "installed $BIN ($("$BIN" --version 2>/dev/null || echo binary))"

# --- workspace root: where projects live and sessions start ---
if [ -z "${DISPATCH_WORKSPACE:-}" ]; then
  if [ -d /workspace ]; then DISPATCH_WORKSPACE=/workspace; else DISPATCH_WORKSPACE="$HOME/workspace"; mkdir -p "$DISPATCH_WORKSPACE"; fi
fi

# --- take over from a legacy source-run server holding the port ---
if curl -sf -m 3 "http://127.0.0.1:$PORT/health" | grep -q '"ok":true'; then
  say "a dispatch server already holds :$PORT — taking over"
  tmux kill-session -t dispatch-server 2>/dev/null || true
  ${SUDO:+$SUDO }systemctl stop dispatchd 2>/dev/null || true
  sleep 1
fi

# --- supervision: systemd unit when we can, tmux loop when we cannot ---
RUN_USER="$(id -un)"
if command -v systemctl >/dev/null && { [ "$(id -u)" = 0 ] || [ -n "$SUDO" ]; }; then
  say "installing systemd service (runs as $RUN_USER)"
  $SUDO tee /etc/systemd/system/dispatchd.service >/dev/null <<UNIT
[Unit]
Description=Dispatch agent control plane
After=network-online.target

[Service]
User=$RUN_USER
Environment=HOME=$HOME
Environment=DISPATCH_PORT=$PORT
Environment=DISPATCH_WORKSPACE=$DISPATCH_WORKSPACE
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin
ExecStart=$BIN
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now dispatchd
elif command -v tmux >/dev/null; then
  say "no systemd access — supervising with a tmux loop"
  tmux kill-session -t dispatchd 2>/dev/null || true
  # HOME and PATH explicitly: a tmux session inherits the tmux SERVER's
  # environment (whatever shell started it, whenever), not this installer's.
  tmux new-session -d -s dispatchd \
    "while true; do HOME='$HOME' PATH='$PATH' DISPATCH_PORT=$PORT DISPATCH_WORKSPACE='$DISPATCH_WORKSPACE' '$BIN' >> /tmp/dispatchd.log 2>&1; sleep 2; done"
else
  fail "no systemd and no tmux — install tmux and re-run"
fi

# --- wait for boot, then print the pairing card ---
for _ in $(seq 1 20); do
  sleep 0.5
  HEALTH="$(curl -sf -m 2 "http://127.0.0.1:$PORT/health" || true)"
  [ -n "$HEALTH" ] && break
done
[ -n "${HEALTH:-}" ] || fail "server did not come up — check: journalctl -u dispatchd -n 50 (or /tmp/dispatchd.log)"

TOKEN="$(cat "$HOME/.dispatch/token")"
VERSION="$(printf '%s' "$HEALTH" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -Ev '^(127\.|::|$)' | head -3 | tr '\n' ' ')"
PUB="$(curl -fsS -m 4 https://api.ipify.org 2>/dev/null || true)"
TSHOST="$(command -v tailscale >/dev/null && tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//' || true)"

printf '\n'
say "dispatchd $VERSION is running ✓"
printf '\n  \033[1mPair this box in the Dispatch app\033[0m  (Settings → Boxes → Add box)\n\n'
[ -n "$TSHOST" ] && printf '    Server:  http://%s:%s   (tailnet — preferred)\n' "$TSHOST" "$PORT"
[ -n "$PUB" ]    && printf '    Server:  http://%s:%s   (public — open port %s in the firewall)\n' "$PUB" "$PORT" "$PORT"
[ -n "$IPS" ]    && printf '    Server:  http://%s:%s   (LAN)\n' "$(echo "$IPS" | awk '{print $1}')" "$PORT"
printf '    Token:   %s\n\n' "$TOKEN"
say "update later from the app, or: curl -X POST -H \"Authorization: Bearer \$(cat ~/.dispatch/token)\" http://127.0.0.1:$PORT/update"
