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
    mangohud \
    gamescope \
    sddm \
    accountsservice \
    mesa-utils


# sudo ln -s "$(command -v qdbus6)" /usr/local/bin/qdbus

# ----------------------------------------------------------------------------
# 2. gamescope-session launcher
# ----------------------------------------------------------------------------
echo "==> Writing /usr/bin/gamescope-session"
sudo tee /usr/bin/gamescope-session >/dev/null <<'EOF'
#!/bin/bash
# Launches Steam Big Picture inside gamescope as a full session.
# -e   enable Steam integration (lets Steam control gamescope, e.g. resolution)
# -f   start fullscreen
# -W/-H target resolution — REQUIRED. Without these, gamescope falls back
#      to its built-in default target, which is the actual Steam Deck
#      panel spec (1280x800, 7"). That's the "reads as a 7 inch screen"
#      bug — it's not a display-detection problem, gamescope is just
#      doing exactly what it's told when it's told nothing at all.
#      Adjust these two numbers to your actual monitor's resolution.
#
# Steam flags:
# -gamepadui   the newer Deck-style Big Picture interface
#
# Deliberately NOT using -steamos3 / -steampal / -pal-restart-in-desktop:
# those tell Steam it's running on an actual SteamOS system install and
# make it expect real SteamOS update infrastructure (steamos-atomupd
# etc.) that doesn't exist here — it gets stuck endlessly failing to
# "update" and blocks you from leaving that screen.
exec gamescope -e --mangoapp -f -w 1920 -h 1080 -W 1920 -H 1080 -- steam -gamepadui -steamos3

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
Exec=/usr/bin/gamescope-session
# Exec=/usr/bin/systemd-run --user --scope --unit=gamescope-session --collect /usr/bin/gamescope-session
Type=Application
DesktopNames=gamescope
EOF

echo "==> Writing /usr/bin/return-to-gamemode"
sudo tee /usr/bin/return-to-gamemode >/dev/null <<'EOF'
#!/bin/bash
steamos-session-select gamescope
EOF
sudo chmod 755 /usr/bin/return-to-gamemode

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
SUDOERS_LINE_3="$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/return-to-gamemode"

{
    echo "$SUDOERS_LINE_1"
    echo "$SUDOERS_LINE_2"
    echo "$SUDOERS_LINE_3"

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
    plasma|desktop)
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

# Switching modes should always be seamless — no login prompt in either
# direction — regardless of whatever the permanent boot-to-gamemode
# preference was set to at install time. That install-time choice only
# decides what a cold boot does; every manual switch after that keeps
# autologin in sync with whichever session you're actively choosing
# right now.
if [[ "$SESSION_FILE" == "gamescope" ]]; then
    sudo /usr/bin/steamos-set-autologin enable "$USER" gamescope
else
    sudo /usr/bin/steamos-set-autologin disable
fi

# End the current session cleanly by asking whichever compositor is
# actually running right now to exit on its own — do NOT force-kill the
# whole logind session (that can hang the GPU/display handoff and
# freeze the machine). SDDM reclaims control as soon as the compositor
# process exits, and autologin (if enabled) kicks in from there.
#
# Detect the current session type using multiple methods so we don't
# rely solely on environment variables that may be unset when Steam
# spawns this script.
CURRENT=""

# Method 1: XDG_CURRENT_DESKTOP from the session environment.
if [[ -z "$CURRENT" ]]; then
    case "$(echo "${XDG_CURRENT_DESKTOP:-}" | tr '[:upper:]' '[:lower:]')" in
        *kde*|*plasma*) CURRENT="plasma" ;;
        *gamescope*)    CURRENT="gamescope" ;;
    esac
fi

# Method 2: detect by running processes (handles cases where
# XDG_CURRENT_DESKTOP is unset, e.g. when called from Steam).
if [[ -z "$CURRENT" ]]; then
    if pgrep -u "$USER" gamescope >/dev/null 2>&1; then
        CURRENT="gamescope"
    elif pgrep -u "$USER" plasmashell >/dev/null 2>&1 || \
         pgrep -u "$USER" kwin_wayland >/dev/null 2>&1 || \
         pgrep -u "$USER" kwin_x11 >/dev/null 2>&1; then
        CURRENT="plasma"
    fi
fi

case "$CURRENT" in
    plasma)
        # Try Plasma 6 logout first, then Plasma 5, then fall back to
        # loginctl.  The nuclear option (terminate-user) is last so we
        # always give the desktop a chance to shut down gracefully.
        qdbus org.kde.Shutdown /Shutdown logout >/dev/null 2>&1 || \
            qdbus org.kde.ksmserver /KSMServer logout 0 3 3 >/dev/null 2>&1 || \
            loginctl terminate-session "${XDG_SESSION_ID:-}" >/dev/null 2>&1 || \
            loginctl terminate-user "$USER" >/dev/null 2>&1 || true
        ;;
    gamescope)
        # Ask Steam itself to quit first so it can unwind its sandboxes
        # (pressure-vessel, bwrap) before we tear down the scope.
        pkill -TERM -u "$USER" steam >/dev/null 2>&1 || true
        for _ in $(seq 1 30); do
            pgrep -u "$USER" gamescope >/dev/null 2>&1 || break
            sleep 1
        done
        if pgrep -u "$USER" gamescope >/dev/null 2>&1; then
            echo "Steam did not exit cleanly after 30s, forcing scope stop..." >&2
            systemctl --user stop gamescope-session.scope >/dev/null 2>&1 || \
                pkill -KILL -u "$USER" gamescope >/dev/null 2>&1 || true
        fi
        sleep 1
        loginctl terminate-user "$USER" >/dev/null 2>&1 || true
        ;;
    *)
        # Last resort: could not determine the session type, but still
        # try to end it so the user isn't stuck.
        echo "Warning: could not detect current session type." \
             "Trying all available shutdown methods..." >&2
        qdbus org.kde.Shutdown /Shutdown logout >/dev/null 2>&1 || true
        qdbus org.kde.ksmserver /KSMServer logout 0 3 3 >/dev/null 2>&1 || true
        pkill -TERM -u "$USER" steam >/dev/null 2>&1 || true
        sleep 3
        loginctl terminate-user "$USER" >/dev/null 2>&1 || true
        ;;
esac
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
Exec=/usr/bin/return-to-gamemode
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
    BOOT_NOTE="This machine will boot directly into Game Mode. Switching to Desktop Mode (from Steam's menu or the process this script sets up) is seamless, but note: since that switch turns autologin off, a reboot taken WHILE you're in Desktop Mode will land at a normal login screen rather than Game Mode, until you switch back to Game Mode at least once."
else
    echo "==> Leaving normal SDDM login screen in place (no autologin)"
    rm -f "$HOME/.config/steamos-autologin-enabled"
    sudo /usr/bin/steamos-set-autologin disable
    BOOT_NOTE="This machine will boot to the normal SDDM login screen. Once you log in and switch to Game Mode manually (via the desktop icon or Steam), switching is seamless in both directions from then on for that boot."
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
