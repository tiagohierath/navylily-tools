# lilydrop

Lilydrop publishes numbered project deliveries as short-lived download links.
The delivery stays in the project history. Each share link expires separately.

## Publish a delivery

Run this from the project root. The source must be inside the approved root.

```sh
cd /home/tiago/projects/alvorada2026
./lilydrop.py publish to-deliver-1 \
  --project alvorada \
  --project-name Alvorada \
  --delivery 1 \
  --allow-root .
```

Lilydrop prints the exact source path, file count, size, delivery number, and
expiry time. It then requires this exact phrase before it creates a package:

```text
PUBLISH ALVORADA DELIVERABLES 01
```

The resulting URL is short and includes the project and delivery number:

```text
https://files.navylily.tv/alvorada/1/AbCdEf1234567890
```

The secret portion is required. Do not remove it to make the URL shorter.
Without it, anyone could guess a project and delivery number.

An agent or reviewed non-interactive script can add `--yes`. The approved-root
check still runs, and the command prints the same review information before it
publishes. `--allow-root` must be one ordinary project directory directly under
`/home/tiago/projects`. Lilydrop refuses `/`, your home directory,
`/home/tiago/projects`, `_system`, and the protected Navylily or daily-x roots.

## Resend the same delivery

Create another expiring share without repackaging the delivery:

```sh
./lilydrop.py reshare alvorada 1 --days 7
```

If the files change, publish a new delivery number instead:

```sh
./lilydrop.py publish to-deliver-2 \
  --project alvorada \
  --project-name Alvorada \
  --delivery 2 \
  --allow-root .
```

## Revoke a link

```sh
./lilydrop.py revoke AbCdEf1234567890
```

Revoked and expired links return a clear `410` page. A revoked link cannot be
re-enabled.

## Link preview

Publishing automatically creates a link preview for Discord and other chat
clients. Lilydrop uses the first PDF in sorted path order and renders its first
page. If there is no PDF, it uses the first JPEG, PNG or WebP image. The JPEG
preview has a maximum dimension of 1200 pixels. The title and description
include the project, delivery, file count, size and expiry.

PDF rendering uses Poppler (`pdftoppm`); images use ImageMagick (`magick`).
If the tool is missing and Nix is available, Lilydrop runs it through `nix shell`.
Rendering failures produce a warning; the delivery remains available with a
text preview. To retry or choose a specific cover for an existing delivery:

```sh
cd /home/tiago/projects/vexian2026
../navylily-tools/lilydrop.py preview vexian 1 \
  To-deliver-1/PanopticOS-Groundwork.pdf --allow-root .
```

The page advertises the image at the existing share URL plus `/preview.jpg`.
It requires the same token and expires or revokes with the share. No new share
or expiry is created. Chat services may retain a cached preview after expiry.
After adding a preview, repost the link; an existing message may stay cached.
Use a new query string (for example `?preview=2`) when testing a refreshed
preview. This keeps the token and expiry unchanged. Discord still controls
whether an embed is displayed; preview metadata cannot override user or
channel embed settings.

The default ledger is `.state/lilydrop/shares.json` in this repository.
If `LILYDROP_STATE` is set, both publisher and server must use the same value.
Never substitute temporary state when publishing a production link.

## Safety and storage

Lilydrop does not need `sudo` and should not run as root. Sudo grants process
privileges, but it does not confirm that the selected folder is safe to share.
The publish command uses two checks instead:

1. The source must be inside the exact `--allow-root` directory.
2. The approved root must be an ordinary project directory under the workspace.
3. An interactive operator must confirm the project, delivery number, source
   contents, size, and expiry. An agent may use the explicit `--yes` flag, but
   it cannot bypass the root policy.

Lilydrop rejects a source that is the approved root itself and rejects source
trees containing symlinks. It copies a file or creates an archive under the
private Lilydrop state directory before saving the delivery record. The
original project files are never deleted or modified.

Downloads stream in chunks and support HTTP range requests. The server sends
private no-cache headers, suppresses URL logs, and does not terminate TLS.
Run it behind the existing HTTPS reverse proxy on port `8787`:

```sh
./lilydrop.py serve
```

The service file is in `../navylily-private/auth/deploy/lilydrop.service`.
