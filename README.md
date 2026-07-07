# KioskRaspberry-Chromium

Turn a Raspberry Pi into a dedicated Chromium kiosk display. One interactive script sets up everything needed to show a website fullscreen, 24/7, unattended — digital signage, dashboards, visitor displays, menu boards, whatever you need on a screen.

Built for **Raspberry Pi OS** (Lite recommended). Free and open source under the MIT license — anyone is welcome to use it, modify it, or fork it.

## Install

Run this on your Pi as a regular user (not root — the script uses sudo where needed):

```
bash <(curl -s https://raw.githubusercontent.com/IRennie74/KioskRaspberry-Chromium/main/kiosk_setup.sh)
```

The script walks you through each option with simple yes/no prompts. Every step is optional, and it's safe to re-run — it detects existing configuration and won't duplicate anything.

## What it sets up

- **Chromium in kiosk mode** on Wayland/labwc, auto-starting on boot via greetd (no desktop environment needed)
- **Crash & freeze protection** — if Chromium crashes it restarts automatically, and a watchdog detects freezes and recovers
- **Automatic page refresh** on a schedule you choose (default: every 3 hours)
- **Nightly reboot** at a time you choose (default: 2:00 AM) to keep things fresh
- **Network wait** before launching, so the page loads properly on boot
- Hidden mouse cursor, custom boot splash screen, screen resolution/rotation, HDMI audio, and optional TV remote control via HDMI-CEC

Hardware video acceleration works out of the box with Raspberry Pi OS's Chromium build — for best video playback, serve H.264 MP4 at 1080p or below.

## Requirements

- Raspberry Pi running Raspberry Pi OS (Lite works best; Pi 4 or newer recommended)
- A user account with sudo privileges
- Internet connection during setup
- Run the install command from a normal terminal (bash) session

## After setup

Reboot and the Pi boots straight into your website fullscreen. To change the URL or tweak behavior later, edit `~/.config/labwc/autostart`.

## Credits

Based on [TOLDOTECHNIK/Raspberry-Pi-Kiosk-Display-System](https://github.com/TOLDOTECHNIK/Raspberry-Pi-Kiosk-Display-System), rebuilt and extended.

## License

MIT — see [LICENSE](LICENSE).
