#!/usr/bin/env bash
#
# install_timer.sh — install a *user* systemd timer that runs the uploader
# once a day at 18:00 America/Sao_Paulo. The script's own guards make it safe
# even if the timer misfires or overlaps, so the timer only has to be roughly
# right.
#
# This writes to ~/.config/systemd/user — it does not touch the system config,
# so it stays within the declarative/ephemeral rule for the machine itself
# (you can also fold the equivalent systemd.user.* into your NixOS config if
# you prefer it fully declarative; see README).
#
# Usage:  ./install_timer.sh           # install + enable
#         ./install_timer.sh --remove  # disable + remove
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
    echo "Removed navylily-youtube timer."
    exit 0
fi

mkdir -p "$UNIT_DIR"

cat > "$SERVICE" <<EOF
[Unit]
Description=Navylily — upload one video to YouTube (private)

[Service]
Type=oneshot
ExecStart=$HERE/youtube_upload.sh
EOF

# OnCalendar honours the timezone you name explicitly.
cat > "$TIMER" <<EOF
[Unit]
Description=Navylily YouTube upload — daily 18:00 America/Sao_Paulo

[Timer]
OnCalendar=*-*-* 18:00:00 America/Sao_Paulo
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now navylily-youtube.timer
echo "Installed. Next run:"
systemctl --user list-timers navylily-youtube.timer --no-pager || true
echo
echo "NOTE: for the timer to run when you're logged out, enable lingering:"
echo "  loginctl enable-linger $USER"
