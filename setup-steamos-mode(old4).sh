#!/bin/bash
#
# setup-steamos-mode.sh
#
# Turns a Kubuntu install into a dual-mode "SteamOS-like" system:
#   - Desktop Mode: your normal Plasma session
#   - Game Mode:    a gamescope + Steam Big Picture (gamepadui) session
#
# Adds:
#   - A "Game Mode" session selectable at the SDDM login screen
#   - A desktop icon on your Plasma desktop to jump into Game Mode
#   - `steamos-session-select` on PATH, so Steam's own quit/power menu
#     shows a native "Switch to Desktop" option while in Game Mode
#     (Steam checks for this binary the same way it does on the Deck)
#
# Run as your normal user. It will use sudo internally when needed.
#
# Flags:
#   --boot-to-gamemode   Boot straight into Game Mode (DeckUI) on every
#                        startup, skipping the SDDM login screen, the
#                        same way a real Steam Deck behaves. You can
#                        always use "Switch to Desktop" from within
#                        Steam to get to Plasma for that session; the
#                        next reboot goes back to Game Mode automatically.
#                        If you don't pass this, you'll be prompted.

set -euo pipefail

BOOT_TO_GAMEMODE=""
for arg in "$@"; do
    case "$arg" in
        --boot-to-gamemode) BOOT_TO_GAMEMODE="yes" ;;
        --no-boot-to-gamemode) BOOT_TO_GAMEMODE="no" ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    echo "Please run this as your normal user, not root. It will sudo when needed."
    exit 1
fi

TARGET_USER="$(whoami)"
echo "==> Installing SteamOS-like Game Mode for user: $TARGET_USER"

# ----------------------------------------------------------------------------
# 1. Packages
# ----------------------------------------------------------------------------
echo "==> Installing required packages (steam, gamescope, sddm, accountsservice)..."
sudo apt update
sudo apt install -y \
    steam \
    gamescope \
    sddm \
    accountsservice \
    mesa-utils

# ----------------------------------------------------------------------------
# 2. gamescope-session launcher
# ----------------------------------------------------------------------------
echo "==> Writing /usr/bin/gamescope-session"
sudo tee /usr/bin/gamescope-session >/dev/null <<'EOF'
#!/bin/bash
# Launches Steam Big Picture inside gamescope as a full session.
# -e   enable Steam integration (lets Steam control gamescope, e.g. resolution)
# -f   start fullscreen
# -W/-H target resolution; adjust to your display if needed
#
# Steam flags:
# -gamepadui   the newer Deck-style Big Picture interface
#
# Deliberately NOT using -steamos3 / -steampal / -pal-restart-in-desktop:
# those tell Steam it's running on an actual SteamOS system install and
# make it expect real SteamOS update infrastructure (steamos-atomupd
# etc.) that doesn't exist here — it gets stuck endlessly failing to
# "update" and blocks you from leaving that screen.
exec gamescope -e -f -W 1920 -H 1080 -- steam -gamepadui
EOF
sudo chmod +x /usr/bin/gamescope-session

# ----------------------------------------------------------------------------
# 3. SDDM session entry so "Game Mode" appears at the login screen
# ----------------------------------------------------------------------------
echo "==> Registering Game Mode as a login session"
sudo tee /usr/share/wayland-sessions/gamescope.desktop >/dev/null <<'EOF'
[Desktop Entry]
Name=SteamOS Game Mode
Comment=Boot straight into Steam Big Picture via gamescope
Exec=/usr/bin/systemd-run --user --scope --unit=gamescope-session --collect /usr/bin/gamescope-session
Type=Application
DesktopNames=gamescope
EOF

# ----------------------------------------------------------------------------
# 4. Root helper that actually flips the user's default session,
#    plus a narrow sudoers rule so it can run without a password prompt
#    (only this one script gains that privilege, nothing else).
# ----------------------------------------------------------------------------
echo "==> Writing /usr/bin/steamos-set-default-session (root helper)"
sudo tee /usr/bin/steamos-set-default-session >/dev/null <<'EOF'
#!/bin/bash
# Usage: steamos-set-default-session <username> <session-desktop-basename>
set -euo pipefail
USERNAME="$1"
SESSION="$2"
ACCOUNTS_DIR="/var/lib/AccountsService/users"
FILE="$ACCOUNTS_DIR/$USERNAME"

mkdir -p "$ACCOUNTS_DIR"
if [[ -f "$FILE" ]] && grep -q '^\[User\]' "$FILE"; then
    sed -i "/^\[User\]/,/^\[/{s/^Session=.*/Session=$SESSION/}" "$FILE"
    grep -q '^Session=' "$FILE" || sed -i "/^\[User\]/a Session=$SESSION" "$FILE"
else
    {
        echo "[User]"
        echo "Session=$SESSION"
    } >> "$FILE"
fi
EOF
sudo chmod 755 /usr/bin/steamos-set-default-session

echo "==> Writing /usr/bin/steamos-set-autologin (root helper)"
sudo tee /usr/bin/steamos-set-autologin >/dev/null <<'EOF'
#!/bin/bash
# Usage: steamos-set-autologin enable <username> <session-desktop-basename>
#        steamos-set-autologin disable
#
# NOTE: on this system, /etc/sddm.conf itself is applied AFTER the files
# in /etc/sddm.conf.d/, so a drop-in file cannot reliably override an
# [Autologin] section that already exists in the main config. We edit
# /etc/sddm.conf directly instead, keeping a one-time backup of its
# original contents so "disable" can restore exactly what was there
# before this script ever touched it.
set -euo pipefail
ACTION="$1"
MAIN_CONF="/etc/sddm.conf"
BACKUP="/etc/sddm.conf.pre-steamos"
LEGACY_DROPIN="/etc/sddm.conf.d/zz-steamos-autologin.conf"

# Take a one-time snapshot of the pristine config, if we haven't already.
if [[ ! -f "$BACKUP" ]]; then
    if [[ -f "$MAIN_CONF" ]]; then
        cp "$MAIN_CONF" "$BACKUP"
    else
        touch "$BACKUP"
    fi
fi

# No longer used, but remove it if a previous run left it behind so it
# can't cause confusion.
rm -f "$LEGACY_DROPIN"

case "$ACTION" in
    enable)
        USERNAME="$2"
        SESSION="$3"
        case "$SESSION" in
            *.desktop) SESSION_FULL="$SESSION" ;;
            *) SESSION_FULL="$SESSION.desktop" ;;
        esac

        # Safety net: never point autologin at a session file that
        # doesn't exist, or you get a black screen with no way back
        # in short of a TTY. Fall back to Plasma instead.
        if [[ ! -f "/usr/share/wayland-sessions/$SESSION_FULL" && \
              ! -f "/usr/share/xsessions/$SESSION_FULL" ]]; then
            echo "Warning: session file '$SESSION_FULL' not found;" \
                 "falling back to plasma.desktop" >&2
            SESSION_FULL="plasma.desktop"
        fi

        # Strip any existing [Autologin] / [General] sections from the
        # pristine backup, then append our own — avoids duplicate
        # sections and guarantees a clean, predictable result.
        awk '
            /^\[Autologin\]/ {skip=1; next}
            /^\[General\]/   {skip=1; next}
            /^\[/            {skip=0}
            skip != 1        {print}
        ' "$BACKUP" > "$MAIN_CONF.tmp"

        cat >> "$MAIN_CONF.tmp" <<INNER

[Autologin]
User=$USERNAME
Session=$SESSION_FULL
Relogin=true

[General]
DisplayServer=wayland
INNER
        mv "$MAIN_CONF.tmp" "$MAIN_CONF"
        ;;
    disable)
        cp "$BACKUP" "$MAIN_CONF"
        ;;
    *)
        echo "Usage: steamos-set-autologin enable <user> <session> | disable" >&2
        exit 1
        ;;
esac
EOF
sudo chmod 755 /usr/bin/steamos-set-autologin

echo "==> Adding sudoers rule for passwordless session switching"
SUDOERS_LINE_1="$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/steamos-set-default-session"
SUDOERS_LINE_2="$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/steamos-set-autologin"
{
    echo "$SUDOERS_LINE_1"
    echo "$SUDOERS_LINE_2"
} | sudo tee /etc/sudoers.d/steamos-session-select >/dev/null
sudo chmod 440 /etc/sudoers.d/steamos-session-select
sudo visudo -c -f /etc/sudoers.d/steamos-session-select

# ----------------------------------------------------------------------------
# 5. steamos-session-select — the command Steam itself looks for.
#    Sets the desired session, then ends the current one so SDDM restarts
#    into it. This is what powers both the desktop icon and the
#    "Switch to Desktop" entry Steam adds to its own quit menu.
# ----------------------------------------------------------------------------
echo "==> Writing /usr/bin/steamos-session-select"
sudo tee /usr/bin/steamos-session-select >/dev/null <<'EOF'
#!/bin/bash
# Usage: steamos-session-select plasma|gamescope
set -euo pipefail
TARGET="${1:-}"

case "$TARGET" in
    plasma)
        SESSION_FILE="plasma"
        ;;
    gamescope|game|bigpicture)
        SESSION_FILE="gamescope"
        ;;
    *)
        echo "Usage: steamos-session-select plasma|gamescope" >&2
        exit 1
        ;;
esac

sudo /usr/bin/steamos-set-default-session "$USER" "$SESSION_FILE"

# Keep autologin in sync: boot-to-gamemode only stays "on" while the
# machine is actually in Game Mode. Switching to desktop drops back to
# a normal login prompt for this session; switching back to Game Mode
# (or simply rebooting from Game Mode) re-enables it.
AUTOLOGIN_STATE_FILE="$HOME/.config/steamos-autologin-enabled"
if [[ -f "$AUTOLOGIN_STATE_FILE" ]]; then
    if [[ "$SESSION_FILE" == "gamescope" ]]; then
        sudo /usr/bin/steamos-set-autologin enable "$USER" gamescope
    else
        sudo /usr/bin/steamos-set-autologin disable
    fi
fi

# End the current session cleanly by asking whichever compositor is
# actually running right now to exit on its own — do NOT force-kill the
# whole logind session (that can hang the GPU/display handoff and
# freeze the machine). SDDM reclaims control as soon as the compositor
# process exits, and autologin (if enabled) kicks in from there.
if pgrep -u "$USER" -x plasmashell >/dev/null 2>&1; then
    # Currently in Plasma (Desktop Mode) — graceful KDE logout, no dialog.
    qdbus org.kde.ksmserver /KSMServer logout 0 3 3 >/dev/null 2>&1 || \
        loginctl terminate-session "$XDG_SESSION_ID" >/dev/null 2>&1 || true
elif pgrep -u "$USER" -x gamescope >/dev/null 2>&1; then
    # Currently in Game Mode — stop the systemd scope we launched it in
    # (mirrors how it was started, so cleanup is symmetrical). Steam
    # gets a moment to shut down gracefully as part of that.
    if systemctl --user stop gamescope-session.scope >/dev/null 2>&1; then
        :
    else
        pkill -TERM -u "$USER" -x steam >/dev/null 2>&1 || true
        for _ in $(seq 1 10); do
            pgrep -u "$USER" -x gamescope >/dev/null 2>&1 || break
            sleep 1
        done
        pkill -TERM -u "$USER" -x gamescope >/dev/null 2>&1 || true
    fi
else
    echo "Could not detect the current session type; not doing anything" \
         "forceful. Please switch sessions from within Plasma or Steam." >&2
    exit 1
fi
EOF
sudo chmod +x /usr/bin/steamos-session-select

# ----------------------------------------------------------------------------
# 6. Desktop icon: "Switch to Game Mode" on the Plasma desktop
# ----------------------------------------------------------------------------
echo "==> Adding desktop shortcut"
DESKTOP_DIR="$HOME/Desktop"
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_DIR/Switch-to-Game-Mode.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Switch to Game Mode
Comment=Leave the desktop and boot into SteamOS-style Big Picture
Exec=/usr/bin/steamos-session-select gamescope
Icon=steam
Terminal=false
Categories=Game;
EOF
chmod +x "$DESKTOP_DIR/Switch-to-Game-Mode.desktop"

# Mark it trusted so Plasma doesn't block it with a warning dialog
if command -v kioclient5 >/dev/null 2>&1 || command -v gio >/dev/null 2>&1; then
    gio set "$DESKTOP_DIR/Switch-to-Game-Mode.desktop" metadata::trusted true 2>/dev/null || true
fi

# ----------------------------------------------------------------------------
# 7. Optional: boot straight into Game Mode (DeckUI) on startup
# ----------------------------------------------------------------------------
if [[ -z "$BOOT_TO_GAMEMODE" ]]; then
    read -r -p "Boot straight into Game Mode (DeckUI) on startup, like a Steam Deck? [y/N] " REPLY
    case "$REPLY" in
        [Yy]*) BOOT_TO_GAMEMODE="yes" ;;
        *) BOOT_TO_GAMEMODE="no" ;;
    esac
fi

mkdir -p "$HOME/.config"
if [[ "$BOOT_TO_GAMEMODE" == "yes" ]]; then
    echo "==> Enabling autologin straight into Game Mode"
    touch "$HOME/.config/steamos-autologin-enabled"
    sudo /usr/bin/steamos-set-autologin enable "$TARGET_USER" gamescope
    sudo /usr/bin/steamos-set-default-session "$TARGET_USER" gamescope
    BOOT_NOTE="This machine will boot directly into Game Mode. Use 'Switch to Desktop' in Steam's power menu to reach Plasma for the current session; the next reboot returns to Game Mode automatically."
else
    echo "==> Leaving normal SDDM login screen in place (no autologin)"
    rm -f "$HOME/.config/steamos-autologin-enabled"
    sudo /usr/bin/steamos-set-autologin disable
    BOOT_NOTE="This machine will boot to the normal SDDM login screen, where you can pick 'SteamOS Game Mode' or your regular Plasma session."
fi

echo ""
echo "================================================================"
echo " Done. What you now have:"
echo ""
echo "  * A 'SteamOS Game Mode' entry on the SDDM login screen"
echo "  * A 'Switch to Game Mode' icon on your desktop"
echo "  * Inside Game Mode, Steam's own Steam-button > Power menu will"
echo "    now show 'Switch to Desktop', taking you back to Plasma"
echo "  * $BOOT_NOTE"
echo ""
echo " Next steps:"
echo "  1. Reboot."
echo "  2. If autologin is on, you'll land straight in Game Mode."
echo "     Otherwise, log into Plasma as usual (Desktop Mode) and"
echo "     double-click 'Switch to Game Mode' on the desktop to test it."
echo "  3. From inside Steam's Big Picture power menu, choose"
echo "     'Switch to Desktop' to come back."
echo ""
echo " You can change the boot behavior any time by re-running this"
echo " script with --boot-to-gamemode or --no-boot-to-gamemode."
echo "================================================================"
