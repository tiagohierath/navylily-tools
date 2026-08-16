#!/usr/bin/env bash
# Persistent local alert plus optional desktop notification/webhook.
set -u

STATE_DIR="${YT_STATE_DIR:-$HOME/.local/state/navylily-youtube}"
HEALTH="$STATE_DIR/health.json"
MESSAGE="Navylily YouTube uploader failed. Run: ./youtube_upload.sh --status"

if [[ -r "$HEALTH" ]] && command -v python3 >/dev/null 2>&1; then
    detail="$(python3 - "$HEALTH" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("message", ""))
except Exception:
    pass
PY
)"
    [[ -n "$detail" ]] && MESSAGE="Navylily YouTube: $detail"
fi

if command -v systemd-cat >/dev/null 2>&1; then
    printf '%s\n' "$MESSAGE" | systemd-cat -t navylily-youtube -p alert || true
fi
if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical "YouTube upload needs attention" "$MESSAGE" || true
fi

# Optional business alert. Put YT_ALERT_WEBHOOK_URL=... in
# ~/.config/navylily-youtube.env to receive the same message remotely.
if [[ -n "${YT_ALERT_WEBHOOK_URL:-}" ]] && command -v curl >/dev/null 2>&1; then
    payload="$(python3 - "$MESSAGE" <<'PY'
import json, sys
print(json.dumps({"text": sys.argv[1]}))
PY
)"
    curl --fail --silent --show-error --max-time 20 \
        -H 'Content-Type: application/json' -d "$payload" \
        "$YT_ALERT_WEBHOOK_URL" || true
fi

printf '%s\n' "$MESSAGE" >&2
