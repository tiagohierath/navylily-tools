#!/usr/bin/env bash
#
# youtube_upload.sh — run youtube_upload.py inside an ephemeral nix env that
# provides Python + the Google API client libraries. Nothing is installed
# system-wide (this machine is declarative/ephemeral only).
#
# All arguments are passed straight through to youtube_upload.py, e.g.:
#   ./youtube_upload.sh --dry-run
#   ./youtube_upload.sh --authorize
#   ./youtube_upload.sh --status
#   ./youtube_upload.sh                 # live: at most one upload
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A leaked LD_LIBRARY_PATH (host libs built against a newer glibc) breaks
# nix-provided binaries with GLIBC_ABI_DT_X86_64_PLT errors — strip it.
PY_ENV=(
    nixpkgs#python3
    nixpkgs#python3Packages.google-api-python-client
    nixpkgs#python3Packages.google-auth-oauthlib
    nixpkgs#python3Packages.google-auth-httplib2
)

if command -v python3 >/dev/null 2>&1 && \
   python3 -c "import googleapiclient, google_auth_oauthlib" >/dev/null 2>&1; then
    exec python3 "$HERE/youtube_upload.py" "$@"
elif command -v nix >/dev/null 2>&1; then
    exec env -u LD_LIBRARY_PATH nix shell "${PY_ENV[@]}" \
        --command python3 "$HERE/youtube_upload.py" "$@"
else
    echo "ERROR: need python3 with google-api-python-client + " >&2
    echo "google-auth-oauthlib, and nix is unavailable to provide them." >&2
    exit 1
fi
