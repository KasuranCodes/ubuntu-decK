# ubuntu-decK

`ubuntu-decK` is an experimental project for adding a SteamOS-style gaming session to an existing Kubuntu installation. It is the active implementation project associated with the broader [mOSs](https://github.com/KasuranCodes/mOSs) Linux distribution concept.

> **Warning:** This installer makes system-wide changes, including installing packages and configuring login sessions, helper commands, SDDM, and sudoers rules. Treat it as experimental and use it only on a system you can recover or reinstall. Review the script before running it. The project does not currently document a complete uninstall or rollback procedure.

## What the setup provides

The current `ubuntu-decK/setup-steamos-mode.sh` script is designed to add:

- A KDE Plasma desktop session and a separate Steam Game Mode session.
- Steam's gamepad UI launched fullscreen using Gamescope.
- A Game Mode option in SDDM and a desktop shortcut for switching modes.
- A `steamos-session-select` helper to switch between Game Mode and the desktop.
- An optional boot directly into Game Mode.

The script installs Steam, MangoHud, Gamescope, SDDM, AccountsService, and Mesa utilities through APT. Its Gamescope command currently uses a 1920 × 1080 target; adjust that for your display as needed.

## Installation

Use a compatible Kubuntu installation. Download or clone this repository, inspect the installer and its system changes, then run it as your normal user (not as root):

```bash
chmod +x ubuntu-decK/setup-steamos-mode.sh
./ubuntu-decK/setup-steamos-mode.sh
```

The script uses `sudo` for system-level operations and prompts about booting directly into Game Mode. You can set that choice without the prompt using either flag:

```bash
./ubuntu-decK/setup-steamos-mode.sh --boot-to-gamemode
./ubuntu-decK/setup-steamos-mode.sh --no-boot-to-gamemode
```

Steam and Gamescope behavior can depend on the Ubuntu/Kubuntu release, graphics drivers, display hardware, and Steam package availability. The script is not an ISO installer or a custom-kernel project.

## Project status

This is an experimental system-integration prototype. The broader mOSs project has goals for an installable image and desktop/mobile variants, but this repository currently provides a setup for an existing Kubuntu system; it does not represent a released mOSs ISO or a working mobile variant.

## Related projects

- [mOSs distribution project](https://github.com/KasuranCodes/mOSs)
- [Portfolio project details](https://kasurancodes.github.io/moss.html)
- [Max McGill's portfolio](https://kasurancodes.github.io/)
