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

# A Fly Sprite has no systemd; the runtime supervises services itself and
# routes the sprite's public HTTPS URL to one service's port.
ON_SPRITE=""
if [ -S /.sprite/api.sock ] && command -v sprite-env >/dev/null; then ON_SPRITE=1; fi

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

# qrencode is best-effort: it draws the pairing QR at the end. Never a reason
# to fail the install — without it the card degrades to URL + token as text.
if ! command -v qrencode >/dev/null; then
  if command -v apt-get >/dev/null; then $SUDO apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null; then $SUDO dnf install -y -q qrencode >/dev/null 2>&1 || true
  elif command -v apk >/dev/null; then $SUDO apk add -q libqrencode-tools >/dev/null 2>&1 || $SUDO apk add -q libqrencode >/dev/null 2>&1 || true
  fi
fi

# --- binary ---
# Self-update atomically renames a sibling file over the executable. The
# directory must therefore belong to the service user, even when that user
# has sudo for installing the systemd unit. /usr/local/bin broke updates on
# existing non-root services with EACCES creating dispatchd.next.
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
BIN="$BIN_DIR/dispatchd"
if [ -n "${DISPATCH_BINARY:-}" ]; then
  # Dev path: install a binary built on this machine (scripts/build-dispatchd.sh)
  # instead of the latest release. Everything after this line is identical.
  [ -f "$DISPATCH_BINARY" ] || fail "DISPATCH_BINARY=$DISPATCH_BINARY does not exist"
  say "installing local binary $DISPATCH_BINARY"
  TMP="$(mktemp)"; cp "$DISPATCH_BINARY" "$TMP"
else
  URL="https://github.com/$REPO/releases/latest/download/dispatchd-linux-$ARCH"
  say "downloading dispatchd-linux-$ARCH from $REPO"
  TMP="$(mktemp)"
  curl -fSL --progress-bar "$URL" -o "$TMP"
  curl -fsSL "https://github.com/$REPO/releases/latest/download/checksums.txt" -o "$TMP.sums"
  WANT="$(grep "dispatchd-linux-$ARCH\$" "$TMP.sums" | awk '{print $1}')"
  GOT="$(sha256sum "$TMP" | awk '{print $1}')"
  [ -n "$WANT" ] && [ "$WANT" = "$GOT" ] || fail "checksum mismatch — refusing to install"
  rm -f "$TMP.sums"
fi
chmod 755 "$TMP"
mv "$TMP" "$BIN"
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
  if [ -n "$ON_SPRITE" ]; then sprite-env services stop dispatchd >/dev/null 2>&1 || true; fi
  sleep 1
fi

# --- supervision: systemd unit when we can, tmux loop when we cannot ---
RUN_USER="$(id -un)"
if [ -n "$ON_SPRITE" ]; then
  say "sprite runtime detected — registering dispatchd as a sprite-env service"
  sprite-env services delete dispatchd >/dev/null 2>&1 || true
  # The runtime restarts a service that CRASHES but not one that exits
  # cleanly — and self-update exits cleanly after swapping the binary
  # (observed 2026-10-04: service "running" with a dead pid, :4000 closed).
  # So the service is a loop around the binary, like the tmux fallback.
  LOOP="$BIN_DIR/dispatchd-loop.sh"
  cat > "$LOOP" <<LOOPEOF
#!/usr/bin/env bash
# Written by install.sh: keeps dispatchd up across clean exits (self-update).
while true; do "$BIN"; sleep 2; done
LOOPEOF
  chmod 755 "$LOOP"
  # --env is comma-separated: PATH may hold colons but never commas.
  sprite-env services create dispatchd \
    --cmd /usr/bin/env --args "bash,$LOOP" --dir "$HOME" \
    --env "HOME=$HOME,DISPATCH_PORT=$PORT,DISPATCH_WORKSPACE=$DISPATCH_WORKSPACE,PATH=$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:/.sprite/bin:/usr/local/bin:/usr/bin:/bin" \
    --http-port "$PORT" --no-stream >/dev/null
elif command -v systemctl >/dev/null && { [ "$(id -u)" = 0 ] || [ -n "$SUDO" ]; }; then
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
# Agent sessions run in tmux under this service's cgroup. The default
# control-group kill on stop/restart took every running agent down with the
# daemon — a self-update at 20:00 killed a Codex implementer mid-turn. Kill
# only the daemon; the tmux server and its sessions survive, and the next
# dispatchd re-reads them from the same tmux socket.
KillMode=process

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
SPRITE_URL=""
[ -n "$ON_SPRITE" ] && SPRITE_URL="$(sprite-env info 2>/dev/null | jq -r '.sprite_url // empty')"
# Pairing relay: the box dialled out at boot; when it is connected, this URL
# works from any network — no Tailscale, no open port.
RELAY_URL="$(printf '%s' "$HEALTH" | jq -r '.relay.publicUrl // empty' 2>/dev/null || true)"
RELAY_UP="$(printf '%s' "$HEALTH" | jq -r '.relay.connected // false' 2>/dev/null || echo false)"
[ "$RELAY_UP" = "true" ] || RELAY_URL=""

printf '\n'
say "dispatchd $VERSION is running ✓"
printf '\n  \033[1mPair this box in the Dispatch app\033[0m  (Settings → Boxes → Add box)\n\n'
[ -n "$SPRITE_URL" ] && printf '    Server:  %s   (sprite — public HTTPS, preferred)\n' "$SPRITE_URL"
[ -n "$RELAY_URL" ]  && printf '    Server:  %s   (relay — works from anywhere)\n' "$RELAY_URL"
[ -n "$TSHOST" ] && printf '    Server:  http://%s:%s   (tailnet — preferred)\n' "$TSHOST" "$PORT"
# On a sprite only the HTTPS proxy is reachable: the public and LAN lines would
# be wrong advice ("open port 4000") for an address nothing can route to.
if [ -z "$ON_SPRITE" ]; then
  [ -n "$PUB" ]    && printf '    Server:  http://%s:%s   (public — open port %s in the firewall)\n' "$PUB" "$PORT" "$PORT"
  [ -n "$IPS" ]    && printf '    Server:  http://%s:%s   (LAN)\n' "$(echo "$IPS" | awk '{print $1}')" "$PORT"
fi
printf '    Token:   %s\n\n' "$TOKEN"

# --- QR pairing: the app already handles dispatch://pair?server=…&token=… ---
# Prefer the sprite's HTTPS URL, then the tailnet hostname, then LAN. Never the
# public IP: scanning must not be the thing that nudges someone into exposing
# plain :4000 to the internet.
if [ -n "$SPRITE_URL" ]; then PAIR_SERVER="$SPRITE_URL"
elif [ -n "$RELAY_URL" ]; then PAIR_SERVER="$RELAY_URL"
elif [ -n "$TSHOST" ]; then PAIR_SERVER="http://$TSHOST:$PORT"
elif [ -n "${IPS:-}" ]; then PAIR_SERVER="http://$(echo "$IPS" | awk '{print $1}'):$PORT"
else PAIR_SERVER=""; fi
if command -v qrencode >/dev/null && [ -n "$PAIR_SERVER" ]; then
  # Percent-encode the server URL: it rides inside a query param, and the
  # app's Linking.parse decodes params — ':' and '/' must not read as URL
  # structure. The token is hex, safe as-is.
  ENC_SERVER="$(printf '%s' "$PAIR_SERVER" | sed -e 's,%,%25,g' -e 's,:,%3A,g' -e 's,/,%2F,g')"
  printf '  \033[1mOr scan with the phone camera\033[0m — opens the Dispatch app and pairs in one tap:\n\n'
  qrencode -t ANSIUTF8 -m 2 "dispatch://pair?server=$ENC_SERVER&token=$TOKEN" | sed 's/^/    /'
  printf '\n'
fi

say "update later from the app, or: curl -X POST -H \"Authorization: Bearer \$(cat ~/.dispatch/token)\" http://127.0.0.1:$PORT/update"
