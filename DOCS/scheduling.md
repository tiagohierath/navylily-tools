# scheduling.md — post one video/day at 18:00 São Paulo

`install_timer.sh` installs a **user** systemd timer that runs
`youtube_upload.sh` daily at 18:00 `America/Sao_Paulo`. The uploader's own three
guards make this safe even if the timer misfires, overlaps, or fires 20 times —
the timer only has to be roughly right.

## Commands

```bash
./install_timer.sh                  # install + enable + start the timer
loginctl enable-linger "$USER"      # let it run while you're logged out
./install_timer.sh --remove         # disable + delete the timer

# inspect / debug
systemctl --user list-timers navylily-youtube.timer   # next scheduled run
systemctl --user status navylily-youtube.service       # last run result
journalctl --user -u navylily-youtube.service -n 50    # run logs
systemctl --user start navylily-youtube.service        # trigger a run now (manually)
```

## What it writes

Two unit files under `~/.config/systemd/user/` (nothing system-wide):

- `navylily-youtube.service` — oneshot, `ExecStart=<repo>/youtube_upload.sh`
- `navylily-youtube.timer` — `OnCalendar=*-*-* 18:00:00 America/Sao_Paulo`,
  `Persistent=true` (catches up a missed run if the machine was off)

## Knobs you can edit

Edit these in `install_timer.sh`, then re-run `./install_timer.sh` to apply:

| What | Where | Note |
|------|-------|------|
| Time of day | `OnCalendar=*-*-* 18:00:00 America/Sao_Paulo` | e.g. `09:30:00`. The named TZ handles DST. |
| Once a week instead of daily | `OnCalendar=Mon *-*-* 18:00:00 America/Sao_Paulo` | and/or set `YT_MIN_HOURS_BETWEEN=168` (see below). |
| Catch up missed runs | `Persistent=true` | set `false` to skip a run the machine slept through. |
| What runs | `ExecStart=...youtube_upload.sh` | pass flags or env here. |

To pass env to the timed run (e.g. weekly cap), add to the `[Service]` block:

```ini
Environment=YT_MIN_HOURS_BETWEEN=168
```

(The `install_timer.sh` heredoc that writes the `.service` is the place to add
that line.)

## Prefer fully-declarative NixOS?

Skip `install_timer.sh` and fold this into your NixOS config instead:

```nix
systemd.user.services.navylily-youtube = {
  description = "Navylily — upload one video to YouTube (private)";
  serviceConfig.ExecStart = "/home/tiago/projects/navylily-tools/youtube_upload.sh";
};
systemd.user.timers.navylily-youtube = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*-*-* 18:00:00 America/Sao_Paulo";
    Persistent = true;
  };
};
```

## Sanity check it's working

```bash
systemctl --user list-timers navylily-youtube.timer   # shows NEXT and LEFT
./youtube_upload.sh --status                            # confirms guards see the state
```
