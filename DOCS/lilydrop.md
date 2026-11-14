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
