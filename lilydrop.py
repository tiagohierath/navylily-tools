#!/run/current-system/sw/bin/python3
"""Publish short-lived, project-labelled delivery links."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlparse


CHUNK = 1024 * 1024
PROJECT_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


def state_path() -> Path:
    # The service uses the project-local ledger. Keep the CLI default aligned
    # with it so a published share is immediately visible to the live server.
    default = Path(__file__).resolve().parent / ".state/lilydrop/shares.json"
    return Path(os.environ.get("LILYDROP_STATE", str(default)))


def empty_state() -> dict:
    return {"version": 2, "deliveries": {}, "shares": {}}


def load_state() -> dict:
    path = state_path()
    if not path.exists():
        return empty_state()
    raw = json.loads(path.read_text())
    if not isinstance(raw, dict):
        raise ValueError(f"state file must contain an object: {path}")
    if raw.get("version") == 2:
        raw.setdefault("deliveries", {})
        raw.setdefault("shares", {})
        return raw

    # The first Lilydrop version stored token -> {file, expires}. Keep those
    # links alive and migrate them when the next write happens.
    migrated = empty_state()
    for token, record in raw.items():
        if not isinstance(record, dict) or "file" not in record:
            continue
        source = Path(record["file"])
        migrated["shares"][token] = {
            "legacy_file": str(source),
            "legacy_name": source.name,
            "created_at": None,
            "expires_at": record.get("expires", 0),
            "revoked_at": None,
            "slug": record.get("slug"),
        }
    return migrated


def save_state(state: dict) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)
    path.chmod(0o600)


def validate_project(project: str) -> str:
    project = project.lower()
    if not PROJECT_RE.fullmatch(project):
        raise ValueError("project must contain lowercase letters, numbers, hyphens, or underscores")
    return project


def project_label(project: str) -> str:
    return project.replace("_", " ").replace("-", " ").title()


def delivery_key(project: str, number: int) -> str:
    return f"{project}:{number}"


def delivery_label(delivery: dict) -> str:
    return delivery.get("label") or f"Deliverables {int(delivery['number']):02d}"


def human_size(value: int) -> str:
    size = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{value} B"


def utc_label(timestamp: float | None) -> str:
    if timestamp is None:
        return "Unknown"
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def share_status(share: dict) -> str:
    if share.get("revoked_at") is not None:
        return "revoked"
    if float(share.get("expires_at", 0)) <= time.time():
        return "expired"
    return "active"


def new_token(shares: dict) -> str:
    # 96 random bits keeps the URL short while remaining unguessable.
    while True:
        token = secrets.token_urlsafe(12)
        if token not in shares:
            return token


def issue_share(state: dict, key: str, days: int) -> str:
    if days <= 0:
        raise ValueError("days must be greater than zero")
    if key not in state["deliveries"]:
        raise ValueError(f"delivery does not exist: {key}")
    token = new_token(state["shares"])
    now = time.time()
    state["shares"][token] = {
        "delivery_id": key,
        "created_at": now,
        "expires_at": now + days * 86400,
        "revoked_at": None,
    }
    return token


def approved_source(source: Path, root: Path) -> Path:
    source = source.expanduser().resolve()
    root = root.expanduser().resolve()
    workspace_root = Path(__file__).resolve().parents[1]
    protected_roots = {
        "_system",
        "navylily-quartz",
        "navylily-private",
        "navylily-tools",
        "daily-x",
    }
    if root.parent != workspace_root or root.name in protected_roots:
        raise ValueError(
            f"approved root must be an ordinary project directory directly under {workspace_root}"
        )
    registry = workspace_root / "_system/registry.yaml"
    if not registry.is_file():
        raise ValueError(f"cannot verify project root because the registry is missing: {registry}")
    blocks = re.split(r"(?=^  - id: )", registry.read_text(), flags=re.MULTILINE)
    registered_roots = set()
    for block in blocks:
        if not re.search(r"^    canonical: true$", block, flags=re.MULTILINE):
            continue
        match = re.search(r"^    root: (.+)$", block, flags=re.MULTILINE)
        if match:
            registered_roots.add(Path(match.group(1).strip()).resolve())
    if root not in registered_roots:
        raise ValueError(f"approved root is not a canonical registered project: {root}")
    if not source.exists():
        raise ValueError(f"source does not exist: {source}")
    if source == root:
        raise ValueError("refusing to publish the approved root itself; select a delivery folder inside it")
    try:
        source.relative_to(root)
    except ValueError as error:
        raise ValueError(f"source is outside approved root {root}: {source}") from error
    if source.is_dir():
        symlinks = [path for path in source.rglob("*") if path.is_symlink()]
        if symlinks:
            raise ValueError(f"source contains symlinks; remove or review them first: {symlinks[0]}")
    return source


def source_stats(source: Path) -> tuple[int, int]:
    if source.is_file():
        return 1, source.stat().st_size
    files = [path for path in source.rglob("*") if path.is_file()]
    return len(files), sum(path.stat().st_size for path in files)


def confirm_publish(args: argparse.Namespace, source: Path, file_count: int, source_size: int) -> None:
    phrase = f"PUBLISH {args.project.upper()} DELIVERABLES {args.delivery:02d}"
    print(f"Source:     {source}")
    print(f"Approved:   {Path(args.allow_root).expanduser().resolve()}")
    print(f"Delivery:   {args.project} / Deliverables {args.delivery:02d}")
    print(f"Contents:   {file_count} files, {human_size(source_size)}")
    print(f"Expires:    {utc_label(time.time() + args.days * 86400)}")
    print(f"Type exactly: {phrase}")
    if args.yes:
        return
    if not sys.stdin.isatty():
        raise ValueError("publishing needs an interactive confirmation; use --yes only in a reviewed script")
    if input("> ").strip() != phrase:
        raise ValueError("publication cancelled")


def temporary_file(directory: Path, suffix: str) -> Path:
    handle, name = tempfile.mkstemp(prefix=".lilydrop-", suffix=suffix, dir=directory)
    os.close(handle)
    return Path(name)


def package_source(source: Path, project: str, number: int) -> tuple[Path, int, int]:
    package_dir = state_path().parent / "packages" / project / f"{number:02d}"
    package_dir.mkdir(parents=True, exist_ok=False)
    file_count, source_size = source_stats(source)
    if source.is_dir():
        package = package_dir / f"{project}-deliverables-{number:02d}.tar.gz"
        temporary = temporary_file(package_dir, ".tar.gz")
        try:
            with tarfile.open(temporary, "w:gz") as archive:
                archive.add(source, arcname=source.name, recursive=True)
            os.replace(temporary, package)
        finally:
            temporary.unlink(missing_ok=True)
    else:
        package = package_dir / source.name
        temporary = temporary_file(package_dir, source.suffix or ".bin")
        try:
            shutil.copy2(source, temporary)
            os.replace(temporary, package)
        finally:
            temporary.unlink(missing_ok=True)
    package.chmod(0o600)
    return package, file_count, source_size


def publish_command(args: argparse.Namespace) -> None:
    project = validate_project(args.project)
    if args.delivery <= 0:
        raise ValueError("delivery must be greater than zero")
    if args.days <= 0:
        raise ValueError("days must be greater than zero")
    source = approved_source(Path(args.path), Path(args.allow_root))
    state = load_state()
    key = delivery_key(project, args.delivery)
    if key in state["deliveries"]:
        raise ValueError(f"delivery already exists: {project} Deliverables {args.delivery:02d}")
    file_count, source_size = source_stats(source)
    confirm_publish(args, source, file_count, source_size)
    package, _, _ = package_source(source, project, args.delivery)
    state["deliveries"][key] = {
        "project_id": project,
        "project_name": args.project_name or project_label(project),
        "number": args.delivery,
        "label": args.label or f"Deliverables {args.delivery:02d}",
        "package_path": str(package),
        "archive_name": package.name,
        "file_count": file_count,
        "package_size": package.stat().st_size,
        "created_at": time.time(),
    }
    token = issue_share(state, key, args.days)
    save_state(state)
    try:
        create_preview(source, package.parent)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Preview unavailable: {error}. Retry with the preview command.", file=sys.stderr)
    print(f"{args.base_url.rstrip('/')}/{project}/{args.delivery}/{token}")


def preview_source(source: Path) -> Path | None:
    files = sorted(source.rglob("*")) if source.is_dir() else [source]
    for extensions in ({".pdf"}, {".jpg", ".jpeg", ".png", ".webp"}):
        for candidate in files:
            if candidate.is_file() and candidate.suffix.lower() in extensions:
                if candidate.is_symlink() or (source.is_dir() and not candidate.resolve().is_relative_to(source.resolve())):
                    raise ValueError("preview source must not follow symlinks")
                return candidate
    return None


def render_tool(binary: str, package: str) -> list[str]:
    executable = shutil.which(binary)
    if executable:
        return [executable]
    if shutil.which("nix"):
        return ["nix", "shell", f"nixpkgs#{package}", "--command", binary]
    raise ValueError(f"install {package} ({binary}) to generate previews")


def create_preview(source: Path, directory: Path) -> Path | None:
    if source.is_file() and source.name == "lilydrop-preview.jpg":
        raise ValueError("this filename is reserved for the preview; rename the source image")
    selected = preview_source(source)
    if selected is None:
        print("Preview: no PDF or supported image found")
        return None
    with tempfile.TemporaryDirectory(prefix=".preview-", dir=directory) as scratch:
        output = Path(scratch) / "cover.jpg"
        if selected.suffix.lower() == ".pdf":
            command = render_tool("pdftoppm", "poppler-utils") + [
                "-f", "1", "-singlefile", "-scale-to", "1200", "-jpeg", "-jpegopt", "quality=90",
                str(selected), str(output.with_suffix(""))]
        else:
            command = render_tool("magick", "imagemagick") + [
                str(selected) + "[0]", "-auto-orient", "-background", "white", "-alpha", "remove",
                "-alpha", "off", "-resize", "1200x1200>", "-strip", "-quality", "90", str(output)]
        subprocess.run(command, check=True, capture_output=True, timeout=180)
        if not output.is_file() or output.stat().st_size == 0:
            raise ValueError("renderer produced no cover image")
        destination = directory / "lilydrop-preview.jpg"
        output.chmod(0o600)
        os.replace(output, destination)
    print(f"Preview: {selected.name}")
    return destination


def preview_command(args: argparse.Namespace) -> None:
    source = approved_source(Path(args.path), Path(args.allow_root))
    state = load_state()
    key = delivery_key(validate_project(args.project), args.delivery)
    if key not in state["deliveries"]:
        raise ValueError(f"delivery does not exist: {key}")
    create_preview(source, Path(state["deliveries"][key]["package_path"]).parent)


def reshare_command(args: argparse.Namespace) -> None:
    project = validate_project(args.project)
    if args.delivery <= 0 or args.days <= 0:
        raise ValueError("delivery and days must be greater than zero")
    state = load_state()
    key = delivery_key(project, args.delivery)
    token = issue_share(state, key, args.days)
    save_state(state)
    print(f"{args.base_url.rstrip('/')}/{project}/{args.delivery}/{token}")


def revoke_command(args: argparse.Namespace) -> None:
    state = load_state()
    share = state["shares"].get(args.token)
    if share is None:
        raise ValueError(f"share does not exist: {args.token}")
    share["revoked_at"] = time.time()
    save_state(state)


def share_for_route(state: dict, token: str) -> dict | None:
    return state["shares"].get(token)


def page(title: str, content: str, *, description: str = "", image_url: str = "") -> bytes:
    metadata = ""
    if description:
        tags = {"og:type": "website", "og:site_name": "lilydrop", "og:title": title,
                "og:description": description, "theme-color": "#c6b990"}
        if image_url:
            tags.update({"og:image": image_url, "og:image:type": "image/jpeg",
                         "og:image:alt": f"{title} — cover image", "twitter:card": "summary_large_image"})
        metadata = "\n".join(
            f'<meta {"property" if key.startswith("og:") else "name"}="{key}" content="{html.escape(value, quote=True)}">'
            for key, value in tags.items()
        )
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>
{metadata}
<style>
body{{margin:0;background:#10100f;color:#f2f2f0;font:15px system-ui,sans-serif}}
main{{width:min(560px,calc(100% - 32px));margin:0 auto;padding:56px 0}}
.card{{padding:28px;border:1px solid #373735;border-radius:16px;background:#151514;box-shadow:0 18px 50px #0005}}
.eyebrow{{color:#aaa9a3;font-size:12px;letter-spacing:.08em;text-transform:uppercase}}
h1{{margin:8px 0 24px;font-size:28px}} h1 span{{color:#aaa9a3}}
.meta{{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin:24px 0}}
.meta div{{min-height:70px;padding:14px;border:1px solid #373735;border-radius:10px;background:#1b1b1a}}
.meta small{{display:block;margin-bottom:7px;color:#aaa9a3;font-size:11px;text-transform:uppercase}}
.meta strong{{overflow-wrap:anywhere;font-size:14px}}
.actions{{display:grid;grid-template-columns:1fr 1fr;gap:10px}}
a,button{{min-height:46px;box-sizing:border-box;border:1px solid #676762;border-radius:9px;padding:0 14px;color:#f2f2f0;background:#1b1b1a;font:inherit;display:flex;align-items:center;justify-content:center;text-decoration:none;cursor:pointer}}
a.primary{{border-color:#f2f2f0;color:#151514;background:#f2f2f0;font-weight:600}}
.command{{margin:16px 0;padding:12px 14px;overflow:auto;border:1px solid #373735;border-radius:9px;background:#0c0c0b;color:#d8d8d2;font:12px/1.5 ui-monospace,monospace}}
.note{{margin:20px 0 0;padding-top:16px;border-top:1px solid #2f2f2c;color:#aaa9a3;font-size:13px;line-height:1.55}}
@media(max-width:480px){{main{{padding:24px 0}}.card{{padding:22px 16px}}.actions{{gap:8px}}}}
</style></head><body><main>{content}</main></body></html>""".encode()


def send_html(handler: BaseHTTPRequestHandler, body: bytes, status: int) -> None:
    handler.send_response(status)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "private, no-store")
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(body)


def send_download(handler: BaseHTTPRequestHandler, file_path: Path, filename: str,
                  *, content_type: str = "application/octet-stream", inline: bool = False) -> None:
    if not file_path.is_file():
        handler.send_error(404)
        return
    size = file_path.stat().st_size
    start, end, status = 0, size - 1, 200
    header = handler.headers.get("Range", "")
    if header:
        if not header.startswith("bytes=") or "," in header:
            handler.send_error(416)
            return
        first, last = header[6:].split("-", 1)
        try:
            if first:
                start = int(first)
                end = int(last) if last else size - 1
            else:
                start = max(size - int(last), 0)
                end = size - 1
            end = min(end, size - 1)
        except ValueError:
            handler.send_error(416)
            return
        if start < 0 or start >= size or start > end:
            handler.send_error(416)
            return
        status = 206
    safe_name = filename.replace("\\", "_").replace('"', "'")
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(end - start + 1))
    handler.send_header("Accept-Ranges", "bytes")
    disposition = "inline" if inline else "attachment"
    handler.send_header("Content-Disposition", f'{disposition}; filename="{safe_name}"')
    handler.send_header("Cache-Control", "private, no-store")
    if status == 206:
        handler.send_header("Content-Range", f"bytes {start}-{end}/{size}")
    handler.end_headers()
    if handler.command == "HEAD":
        return
    with file_path.open("rb") as source:
        source.seek(start)
        remaining = end - start + 1
        while remaining:
            block = source.read(min(CHUNK, remaining))
            if not block:
                break
            handler.wfile.write(block)
            remaining -= len(block)


def serve_command(args: argparse.Namespace) -> None:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlparse(self.path).path
            parts = [unquote(part) for part in path.split("/") if part]
            state = load_state()
            if len(parts) not in (3, 4) or not parts[1].isdigit():
                # Keep old token links alive during the migration.
                if len(parts) not in (2, 3) or parts[0] != "s":
                    self.send_error(404)
                    return
                token, filename = parts[1], parts[2] if len(parts) == 3 else None
                share = state["shares"].get(token)
                delivery = None
            else:
                project, number, token = parts[:3]
                key = delivery_key(project, int(number))
                share = state["shares"].get(token)
                delivery = state["deliveries"].get(key)
                if share is None or share.get("delivery_id") != key or delivery is None:
                    self.send_error(404)
                    return
                filename = parts[3] if len(parts) == 4 else None
            if share is None:
                self.send_error(404)
                return
            status = share_status(share)
            if delivery:
                name = delivery["archive_name"]
                display_project = delivery["project_name"]
                label = delivery_label(delivery)
                file_path = Path(delivery["package_path"])
                file_count = delivery["file_count"]
                package_size = delivery["package_size"]
            else:
                name = share["legacy_name"]
                display_project = "Asset share"
                label = "Legacy delivery"
                file_path = Path(share["legacy_file"])
                file_count = "Unknown"
                package_size = file_path.stat().st_size if file_path.is_file() else 0
            if status != "active":
                message = "This delivery link has expired." if status == "expired" else "This delivery link has been revoked."
                send_html(self, page(f"{display_project} · {label}", f"<section class='card'><p class='eyebrow'>lilydrop</p><h1>{html.escape(display_project)}<br><span>{html.escape(label)}</span></h1><p>{message}</p></section>"), 410)
                return
            preview = file_path.parent / "lilydrop-preview.jpg" if delivery else None
            has_preview = preview is not None and preview.is_file()
            if filename == "preview.jpg" and has_preview:
                send_download(self, preview, "preview.jpg", content_type="image/jpeg", inline=True)
                return
            if filename is not None and filename != name:
                self.send_error(404)
                return
            if filename is not None:
                send_download(self, file_path, name)
                return
            if delivery:
                base_path = f"/{quote(delivery['project_id'], safe='')}/{delivery['number']}/{quote(token, safe='')}"
            else:
                base_path = f"/s/{quote(token, safe='')}"
            download_path = f"{base_path}/{quote(name, safe='')}"
            scheme = self.headers.get("X-Forwarded-Proto", "https").split(",")[0].strip()
            host = self.headers.get("Host", "files.navylily.tv")
            command = f"curl -fL -C - {shlex.quote(f'{scheme}://{host}{download_path}')} -o {shlex.quote(name)}"
            body = f"""<section class='card'>
<p class='eyebrow'>lilydrop · delivery</p>
<h1>{html.escape(display_project)}<br><span>{html.escape(label)}</span></h1>
<div class='meta'><div><small>Archive</small><strong>{html.escape(name)}</strong></div><div><small>Package size</small><strong>{human_size(package_size)}</strong></div><div><small>Files</small><strong>{html.escape(str(file_count))}</strong></div><div><small>Available until</small><strong>{utc_label(share.get('expires_at'))}</strong></div></div>
<p class='command'><code>{html.escape(command)}</code></p>
<div class='actions'><a class='primary' href='{html.escape(download_path, quote=True)}'>Download</a><button id='copy' type='button'>Copy for agent</button></div>
<p id='status' class='note' role='status'>This share closes automatically at the time shown above. Interrupted downloads can resume.</p>
</section><script>document.querySelector('#copy').onclick=async()=>{{await navigator.clipboard.writeText({json.dumps(command)});document.querySelector('#status').textContent='Agent command copied.'}}</script>"""
            description = f"{file_count} files · {human_size(package_size)} · Available until {utc_label(share.get('expires_at'))}."
            image_url = f"{scheme}://{host}{base_path}/preview.jpg" if has_preview else ""
            if has_preview:
                image_url += "?v=" + hashlib.sha256(preview.read_bytes()).hexdigest()[:12]
            send_html(self, page(f"{display_project} · {label}", body,
                                 description=description, image_url=image_url), 200)

        def do_HEAD(self) -> None:
            self.do_GET()

        def log_message(self, *_args: object) -> None:
            return

    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="publish expiring project deliveries")
    commands = parser.add_subparsers(dest="command", required=True)
    publish = commands.add_parser("publish", help="package and publish a new delivery")
    publish.add_argument("path")
    publish.add_argument("--project", required=True)
    publish.add_argument("--project-name")
    publish.add_argument("--delivery", type=int, required=True)
    publish.add_argument("--label")
    publish.add_argument("--allow-root", default=".", help="directory the source must be inside")
    publish.add_argument("--days", type=int, default=7)
    publish.add_argument("--yes", action="store_true", help="skip the interactive confirmation after reviewing the command")
    publish.add_argument("--base-url", default="https://files.navylily.tv")
    reshare = commands.add_parser("reshare", help="create another share for an existing delivery")
    reshare.add_argument("project")
    reshare.add_argument("delivery", type=int)
    reshare.add_argument("--days", type=int, default=7)
    reshare.add_argument("--base-url", default="https://files.navylily.tv")
    revoke = commands.add_parser("revoke", help="revoke a share token")
    revoke.add_argument("token")
    preview = commands.add_parser("preview", help="generate or refresh a delivery's automatic link preview")
    preview.add_argument("project")
    preview.add_argument("delivery", type=int)
    preview.add_argument("path", help="delivery folder, PDF or image")
    preview.add_argument("--allow-root", default=".")
    serve = commands.add_parser("serve", help="run the local HTTP server")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8787)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "publish":
            publish_command(args)
        elif args.command == "reshare":
            reshare_command(args)
        elif args.command == "revoke":
            revoke_command(args)
        elif args.command == "serve":
            serve_command(args)
        elif args.command == "preview":
            preview_command(args)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
