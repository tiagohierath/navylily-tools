#!/usr/bin/env bash
#
# install_timer.sh — install a *user* systemd timer that runs the uploader
# once a day at 18:00 America/Sao_Paulo, posting one private video if any are
# waiting. Designed to be fully hands-off: install once and forget.
#
# The uploader's own guards make it safe even if the timer misfires or overlaps,
# so the timer only has to be roughly right. This writes to ~/.config/systemd/
# user and enables lingering so it keeps running while you're logged out (you
# can instead fold the equivalent systemd.user.* + users.users.<you>.linger into
# your NixOS config if you want it fully declarative; see README).
#
# Usage:  ./install_timer.sh           # install + enable + linger
#         ./install_timer.sh --remove  # disable + remove (leaves linger alone)
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="$UNIT_DIR/navylily-youtube.service"
TIMER="$UNIT_DIR/navylily-youtube.timer"

if [[ "${1:-}" == "--remove" ]]; then
    systemctl --user disable --now navylily-youtube.timer 2>/dev/null || true
    rm -f "$SERVICE" "$TIMER"
    systemctl --user daemon-reload || true
    echo "Removed navylily-youtube timer (lingering left untouched)."
    exit 0
fi

mkdir -p "$UNIT_DIR"

# Pin an explicit PATH so the wrapper always finds `nix` regardless of the
# session environment, and give the upload plenty of time on a slow link.
cat > "$SERVICE" <<EOF
[Unit]
Description=Navylily — upload one video to YouTube (private)
# Best-effort wait for the network; the uploader also retries internally.
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin:/usr/bin:/bin
ExecStart=$HERE/youtube_upload.sh
TimeoutStartSec=30min
# One clean retry a few minutes later if the whole run failed (e.g. no network
# yet). The daily cap + Persistent still prevent any double-post.
Restart=on-failure
RestartSec=5min
EOF

# OnCalendar honours the timezone you name explicitly (systemd >= 252).
cat > "$TIMER" <<EOF
[Unit]
Description=Navylily YouTube upload — daily 18:00 America/Sao_Paulo

[Timer]
OnCalendar=*-*-* 18:00:00 America/Sao_Paulo
# Run as soon as possible after a missed slot (laptop was asleep/off at 18:00).
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now navylily-youtube.timer

# Enable lingering so the timer fires even when you're not logged in. This is
# the one step that needs privilege; try it and report honestly if it needs a
# manual run.
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == "yes" ]]; then
    echo "Lingering already enabled."
elif loginctl enable-linger "$USER" 2>/dev/null; then
    echo "Lingering enabled (runs while logged out)."
else
    echo "!! Could not enable lingering automatically. Run this once:"
    echo "     sudo loginctl enable-linger $USER"
fi

echo
echo "Installed. Next run:"
systemctl --user list-timers navylily-youtube.timer --no-pager || true
