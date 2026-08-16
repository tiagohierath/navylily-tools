#!/usr/bin/env bash
#
# install_timer.sh, install a *user* systemd timer that runs the uploader at
# 09:00 São Paulo, every day. Videos remain private until 18:00.
# setting chooses daily, Sunday-only, or first-of-month posting.
# It posts one private video if any are waiting. Designed to be fully hands-off.
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
ALERT_SERVICE="$UNIT_DIR/navylily-youtube-alert.service"
VERIFY_SERVICE="$UNIT_DIR/navylily-youtube-verify.service"
VERIFY_TIMER="$UNIT_DIR/navylily-youtube-verify.timer"

if [[ "${1:-}" == "--remove" ]]; then
    systemctl --user disable --now navylily-youtube.timer \
        navylily-youtube-verify.timer 2>/dev/null || true
    rm -f "$SERVICE" "$TIMER" "$ALERT_SERVICE" "$VERIFY_SERVICE" "$VERIFY_TIMER"
    systemctl --user daemon-reload || true
    echo "Removed navylily-youtube timer (lingering left untouched)."
    exit 0
fi

mkdir -p "$UNIT_DIR"

# Pin an explicit PATH so the wrapper always finds `nix` regardless of the
# session environment, and give the upload plenty of time on a slow link.
cat > "$SERVICE" <<EOF
[Unit]
Description=Navylily, upload one video to YouTube (private)
# Best-effort wait for the network; the uploader also retries internally.
After=network-online.target
Wants=network-online.target
OnFailure=navylily-youtube-alert.service
# A couple of retries, then stop until the next day's timer fire. Without this
# cap, Restart=on-failure would retry every 5 minutes forever on a persistent
# failure (revoked token, exhausted quota).
StartLimitIntervalSec=6h
StartLimitBurst=3

[Service]
Type=oneshot
Environment=PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin:/usr/bin:/bin
EnvironmentFile=-%h/.config/navylily-youtube.env
ExecStart=$HERE/youtube_upload.sh
TimeoutStartSec=2h
# Retry after a short wait if the run failed (e.g. network not up yet). The
# daily cap + content-hash state still prevent any double-post.
Restart=on-failure
RestartPreventExitStatus=3 4
RestartSec=5min
EOF

cat > "$ALERT_SERVICE" <<EOF
[Unit]
Description=Alert for failed Navylily YouTube upload

[Service]
Type=oneshot
EnvironmentFile=-%h/.config/navylily-youtube.env
ExecStart=$HERE/youtube_alert.sh
EOF

# Use the named zone so future Brazilian timezone-law changes remain correct.
cat > "$TIMER" <<EOF
[Unit]
Description=Navylily YouTube private upload, 09:00 São Paulo

[Timer]
# The uploader enforces its selected daily/weekly/monthly cadence itself.
OnCalendar=*-*-* 09:00:00 America/Sao_Paulo
# Run after a missed slot only if today's safe pre-publication window remains.
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > "$VERIFY_SERVICE" <<EOF
[Unit]
Description=Verify scheduled Navylily YouTube publications
After=network-online.target
Wants=network-online.target
OnFailure=navylily-youtube-alert.service

[Service]
Type=oneshot
Environment=PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin:/usr/bin:/bin
EnvironmentFile=-%h/.config/navylily-youtube.env
ExecStart=$HERE/youtube_upload.sh --verify-publications
TimeoutStartSec=10min
EOF

cat > "$VERIFY_TIMER" <<EOF
[Unit]
Description=Verify Navylily YouTube publication at 18:15 São Paulo

[Timer]
OnCalendar=*-*-* 18:15:00 America/Sao_Paulo
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now navylily-youtube.timer \
    navylily-youtube-verify.timer

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
systemctl --user list-timers navylily-youtube.timer \
    navylily-youtube-verify.timer --no-pager || true
