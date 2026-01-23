#!/bin/bash

set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (or with sudo)."
    exit 1
fi

echo "Installing required packages..."
apt update
apt install -y git jq cron  # Added 'cron' explicitly just in case

echo "Cleaning up any old user crontab entry (prevents duplicates)..."
(crontab -l 2>/dev/null | grep -v "/opt/scripts/system-updates/system-updates.sh") | crontab - || true

# Ensure cron is running (helps in minimal LXCs)
systemctl enable --now cron 2>/dev/null || /etc/init.d/cron start || true

echo "Adding job directly to /etc/crontab (most reliable in Proxmox LXC)..."

CRON_COMMENT="# System Updates Discord Notification (added $(date '+%Y-%m-%d %H:%M'))"
CRON_LINE="0 */6 * * * root /bin/bash /opt/scripts/system-updates/system-updates.sh"

# Check if already present (exact match on script path)
if grep -qF "/opt/scripts/system-updates/system-updates.sh" /etc/crontab; then
    echo "Job already exists in /etc/crontab — no changes needed."
else
    # Append safely with blank line separation
    {
        echo ""
        echo "$CRON_COMMENT"
        echo "$CRON_LINE"
    } >> /etc/crontab
    echo "Job added to /etc/crontab."
fi

# Reload cron to apply changes immediately
systemctl restart cron 2>/dev/null || /etc/init.d/cron restart || service cron restart || true

# Quick verification (helpful during setup)
echo ""
echo "Last 10 lines of /etc/crontab (should show your new entry):"
tail -n 10 /etc/crontab

echo ""
echo "Cron service status:"
systemctl status cron --no-pager || service cron status || true

# ────────────────────────────────────────────────────────────────
echo "Checking for Docker and setting up dockcheck (Docker image update notifier)..."

if command -v docker >/dev/null 2>&1; then
    echo "Docker is installed → proceeding with dockcheck setup."

    DOCKCHECK_DIR="/opt/dockcheck"

    # Clone or update dockcheck repo
    if [ -d "$DOCKCHECK_DIR" ]; then
        echo "dockcheck already exists, updating..."
        cd "$DOCKCHECK_DIR"
        git pull || echo "git pull failed — continuing anyway."
        cd - >/dev/null
    else
        echo "Cloning dockcheck..."
        git clone https://github.com/mag37/dockcheck.git "$DOCKCHECK_DIR"
    fi

    # Ensure we're in the dir
    cd "$DOCKCHECK_DIR" || { echo "Failed to cd into $DOCKCHECK_DIR — skipping dockcheck."; continue; }

    # Copy default.config → dockcheck.config (only if missing, to avoid overwriting custom edits)
    if [ ! -f "dockcheck.config" ]; then
        if [ -f "default.config" ]; then
            cp default.config dockcheck.config
            echo "Created dockcheck.config from default.config"
        else
            echo "Warning: default.config not found in repo — skipping config setup."
            continue
        fi
    else
        echo "dockcheck.config already exists — preserving it and only updating notification settings."
    fi

    # Load the existing webhook from system-updates (we already prompted for it earlier)
    if [ -f "/opt/scripts/system-updates/.webhook" ]; then
        DISCORD_WEBHOOK=$(</opt/scripts/system-updates/.webhook)
    else
        echo "Warning: No .webhook file found — cannot set Discord URL. Skipping dockcheck config update."
        continue
    fi

    # Update the two key lines in dockcheck.config (using sed for in-place replacement)
        
    # Update NOTIFY_CHANNELS: remove leading # (if present), ignore leading spaces, set to "discord"
    sed -i 's/^[[:space:]]*#*[[:space:]]*NOTIFY_CHANNELS=.*/NOTIFY_CHANNELS="discord"/' dockcheck.config

    # Update DISCORD_WEBHOOK_URL: same idea, set full value with quotes (using | as delimiter to avoid / escaping issues)
    sed -i "s|^[[:space:]]*#*[[:space:]]*DISCORD_WEBHOOK_URL=.*|DISCORD_WEBHOOK_URL=\"$DISCORD_WEBHOOK\"|" dockcheck.config

    echo "Updated dockcheck.config with Discord notification settings."

    # Add to system-wide crontab (idempotent)
    echo "Adding dockcheck cron job to /etc/crontab..."
    DOCKCHECK_CRON_COMMENT="# Docker Image Update Check (dockcheck) - checks only, notifies via Discord (added $(date '+%Y-%m-%d %H:%M'))"
    DOCKCHECK_CRON_LINE="0 */6 * * * root /bin/bash /opt/dockcheck/dockcheck.sh -i -n"

    if grep -qF "/opt/dockcheck/dockcheck.sh -i -n" /etc/crontab; then
        echo "dockcheck cron job already exists — skipping."
    else
        {
            echo ""
            echo "$DOCKCHECK_CRON_COMMENT"
            echo "$DOCKCHECK_CRON_LINE"
        } >> /etc/crontab
        echo "dockcheck cron job added."
    fi

    # Reload cron
    systemctl restart cron 2>/dev/null || /etc/init.d/cron restart || service cron restart || true

    # Quick verification
    echo ""
    echo "Last 10 lines of /etc/crontab (should show dockcheck entry if added):"
    tail -n 10 /etc/crontab

else
    echo "Docker not found — skipping dockcheck setup."
fi

echo "Cloning/updating discord.sh..."
mkdir -p /opt
cd /opt
if [ -d "discord.sh" ]; then
    echo "discord.sh already exists, updating..."
    cd discord.sh
    git pull
else
    git clone https://github.com/fieu/discord.sh.git
fi

echo "Setting up directory and script..."
mkdir -p /opt/scripts/system-updates
cd /opt/scripts/system-updates

cat > system-updates.sh << 'EOF'
#!/bin/bash

apt update >/dev/null 2>&1

output=$(apt list --upgradable 2>&1)
lth=${#output}

if [ "$lth" -gt 10 ]; then

    apt list --upgradable > /opt/scripts/system-updates/upgrade.list

    /opt/discord.sh/discord.sh \
    --avatar "$(</opt/scripts/system-updates/.avatar)" \
    --username "$(</opt/scripts/system-updates/.username)" \
    --webhook-url "$(</opt/scripts/system-updates/.webhook)" \
    --color "16705372" \
    --title "list --upgradable" \
    --author "APT" \
    --description "$(cat /opt/scripts/system-updates/upgrade.list | jq -Rs . | cut -c 2- | rev | cut -c 2- | rev)" \
    --text "System Updates Available. <@434395305299935255>"

fi

exit 0
EOF

chmod +x system-updates.sh

# Suppress the apt script warning globally
echo 'Apt::Cmd::Disable-Script-Warning "true";' > /etc/apt/apt.conf.d/90disable-script-warning

echo "Configuring credentials..."

prompt_with_default() {
    local file="$1"
    local prompt="$2"
    local default=""

    if [[ -f "$file" ]]; then
        default=$(cat "$file")
        read -p "$prompt [default: $default]: " input
        echo "${input:-$default}"
    else
        read -p "$prompt: " input
        echo "$input"
    fi
}

NAME=$(prompt_with_default ".username" "Enter the Name (bot username, e.g., container hostname)")
echo "$NAME" > .username
chmod 600 .username

WEBHOOK=$(prompt_with_default ".webhook" "Enter the Discord Webhook URL")
echo "$WEBHOOK" > .webhook
chmod 600 .webhook

if [[ -f ".avatar" ]]; then
    current_avatar=$(cat .avatar)
    read -p "Enter Avatar URL [default: $current_avatar]: " AVATAR
    AVATAR=${AVATAR:-$current_avatar}
else
    read -p "Enter Avatar URL [default: https://extensions.gnome.org/extension-data/icons/icon_1139.png]: " AVATAR
    AVATAR=${AVATAR:-https://extensions.gnome.org/extension-data/icons/icon_1139.png}
fi
echo "$AVATAR" > .avatar
chmod 600 .avatar

echo ""
echo "Setup complete! Everything is ready."
echo "The apt warning is now suppressed globally."
echo "Your default avatar is the system-update packages icon."

echo ""
read -p "Test it right now and see the notification in Discord? [Y/n] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    echo "Running the test now..."
    echo "Running APT commands (this may take a moment)..."
    echo "──────────────────────────────"
    /bin/bash /opt/scripts/system-updates/system-updates.sh
    echo "──────────────────────────────"
    echo "Done! Check your Discord channel."
else
    echo "Test skipped. You can always run it later:"
    echo "  /opt/scripts/system-updates/system-updates.sh"
fi

echo ""
echo "All set — clean, quiet, and beautiful notifications await!"
