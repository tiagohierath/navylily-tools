# scheduling.md

`install_timer.sh` sets up a user systemd timer that runs the uploader every day at 18:00 São Paulo time. The uploader's own guards make this safe even if the timer misfires or runs twice.

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

Two files in `~/.config/systemd/user/` (nothing system-wide): a service that runs `youtube_upload.sh`, and a timer with `OnCalendar=*-*-* 18:00:00 America/Sao_Paulo` and `Persistent=true` (a run missed while the machine was off happens at next boot).

## Changing it

Edit `install_timer.sh` and run it again:

- Different time: change the `OnCalendar` line.
- Weekly instead of daily: `OnCalendar=Mon *-*-* 18:00:00 America/Sao_Paulo`, and add `Environment=YT_MIN_HOURS_BETWEEN=168` to the service block as a second guard.
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
