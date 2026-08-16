# scheduling.md

`install_timer.sh` sets up user systemd timers that upload privately at 18:00
São Paulo, publish at 18:00 the next day, and verify publication at 18:45. The
evening slot is deliberate: the machine is usually off in the morning, so a
morning timer only ever ran late. The persistent cadence decides
whether posting is daily, weekly on Sunday, or monthly on the first day.

## Commands

```bash
./install_timer.sh                  # install and start the timer
loginctl enable-linger "$USER"      # keep it running while logged out
./install_timer.sh --remove         # uninstall

systemctl --user list-timers 'navylily-youtube*'      # both timers
journalctl --user -u navylily-youtube.service -n 50   # logs of past runs
systemctl --user start navylily-youtube.service       # run it right now
```

For a remote failure alert, place `YT_ALERT_WEBHOOK_URL=...` in
`~/.config/navylily-youtube.env` and rerun the installer. Local health is always
available with `./youtube_upload.sh --status`.

## What it installs

The installer creates upload, verification, and failure-alert units in
`~/.config/systemd/user/`. `Persistent=true` catches missed timer slots; the
uploader still refuses when less than two hours remain before publication.

## Changing it

Edit `install_timer.sh` and run it again:

- Different day or time: change the `OnCalendar` lines (e.g. `Wed *-*-* 18:00:00 America/Sao_Paulo`), and keep the verify timer after publication plus `YT_PUBLICATION_GRACE_MINUTES`.
- Longer or shorter private window: set `YT_PUBLISH_DELAY_DAYS` (1 = public the next day, 0 = same day) in `~/.config/navylily-youtube.env`.
- Switch cadence anytime: `./youtube_upload.sh --cadence daily`, `--cadence weekly`, or `--cadence monthly`. Weekly posts on Sundays; monthly posts on the first day.
- Don't catch up missed runs: `Persistent=false`.

## Prefer declarative NixOS?

Skip the installer and put this in the config instead:

```nix
systemd.user.services.navylily-youtube = {
  description = "Navylily upload one video to YouTube (private)";
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
