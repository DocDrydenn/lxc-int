#!/bin/bash

set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (or with sudo)."
    exit 1
fi

echo "Installing required packages..."
apt update
apt install -y git jq

echo "Adding/updating root user crontab job..."

# Ensure cron is fully ready
if ! command -v crontab >/dev/null 2>&1; then
    echo "crontab command not found — installing cron..."
    apt install -y cron
fi

# Start/enable cron (systemd preferred, fallback for sysvinit/old)
if systemctl is-system-running >/dev/null 2>&1; then
    systemctl enable cron --now || true
    systemctl restart cron || true
else
    /etc/init.d/cron start || true
fi

# Wait a moment for daemon to settle (helps in containers)
sleep 2

# Now add the job (idempotent: remove old one first)
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
if echo "$CURRENT_CRON" | grep -q "/opt/scripts/system-updates/system-updates.sh"; then
    echo "Cron job already exists — skipping add."
else
    (
        echo "$CURRENT_CRON"
        echo ""
        echo "# System Updates Discord Notification"
        echo "0 */6 * * * /bin/bash /opt/scripts/system-updates/system-updates.sh"
    ) | crontab -
    echo "Cron job added."
fi

# Quick verification
echo "Current root crontab:"
crontab -l || echo "(crontab -l shows nothing — check if cron is running!)"

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

echo "Adding/updating cron job..."
(crontab -l 2>/dev/null | grep -v "/opt/scripts/system-updates/system-updates.sh"; echo "# System Updates Discord Notification"
echo "0 */6 * * * /bin/bash /opt/scripts/system-updates/system-updates.sh") | crontab -

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
