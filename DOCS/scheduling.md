# scheduling.md

`install_timer.sh` sets up a user systemd timer that runs the uploader daily at 18:00 São Paulo time. The uploader's persistent cadence setting decides whether it posts daily, weekly on Sunday, or monthly on the first day. The guards make this safe even if the timer misfires or runs twice.

## Commands

```bash
./install_timer.sh                  # install and start the timer
loginctl enable-linger "$USER"      # keep it running while logged out
./install_timer.sh --remove         # uninstall

systemctl --user list-timers navylily-youtube.timer   # when it runs next
journalctl --user -u navylily-youtube.service -n 50   # logs of past runs
systemctl --user start navylily-youtube.service       # run it right now
```

## What it installs

Two files in `~/.config/systemd/user/` (nothing system-wide): a service that runs `youtube_upload.sh`, and a daily 18:00 São Paulo timer. `Persistent=true` means a run missed while the machine was off happens at next boot.

## Changing it

Edit `install_timer.sh` and run it again:

- Different day or time: change the `OnCalendar` lines (e.g. `Wed *-*-* 09:00:00 America/Sao_Paulo`).
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
    OnCalendar = "*-*-* 21:00:00 UTC"; # 18:00 São Paulo
    Persistent = true;
  };
};
```
