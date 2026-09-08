#!/usr/bin/env bash
#
# youtube_upload.sh — run youtube_upload.py inside an ephemeral nix env that
# provides Python + the Google API client libraries. Nothing is installed
# system-wide (this machine is declarative/ephemeral only).
#
# All arguments are passed straight through to youtube_upload.py, e.g.:
#   ./youtube_upload.sh --dry-run
#   ./youtube_upload.sh --authorize
#   ./youtube_upload.sh --reauthorize
#   ./youtube_upload.sh --upload-now videos/output/example.mp4
#   ./youtube_upload.sh --status
#   ./youtube_upload.sh                 # live: at most one upload
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# python3.withPackages builds one interpreter that can actually import the
# libs. Listing the packages as separate `nix shell` installables only puts
# their binaries on PATH — the interpreter can't import them, which fails with
# "No module named 'google'".
# Pin the exact nixpkgs revision used by the host configuration. A registry
# update can no longer silently change the uploader's Python dependencies.
NIXPKGS_REV='8f0500b9660505dc3cb647775fe9a978a74b5283'
PY_EXPR="let pkgs = import (builtins.getFlake \"github:NixOS/nixpkgs/$NIXPKGS_REV\") {}; in pkgs.python3.withPackages (ps: with ps; [ google-api-python-client google-auth-oauthlib google-auth-httplib2 ])"

# Read-only/local commands intentionally avoid Nix and all network-capable API
# dependencies. This keeps diagnostics available even if the daemon is down.
case "${1:-}" in
    --dry-run|--status|--cadence|-h|--help)
        exec python3 "$HERE/youtube_upload.py" "$@"
        ;;
esac

# A leaked LD_LIBRARY_PATH (host libs built against a newer glibc) breaks
# nix-provided binaries with GLIBC_ABI_DT_X86_64_PLT errors — strip it.
if command -v python3 >/dev/null 2>&1 && \
   python3 -c "import google.auth, googleapiclient, google_auth_oauthlib" >/dev/null 2>&1; then
    exec python3 "$HERE/youtube_upload.py" "$@"
elif command -v nix >/dev/null 2>&1; then
    exec env -u LD_LIBRARY_PATH nix shell --impure --expr "$PY_EXPR" \
        --command python3 "$HERE/youtube_upload.py" "$@"
else
    echo "ERROR: need python3 with google-api-python-client + " >&2
    echo "google-auth-oauthlib, and nix is unavailable to provide them." >&2
    exit 1
fi
