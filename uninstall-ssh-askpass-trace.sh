#!/usr/bin/env bash
# Undo the ssh-askpass-trace setup: go back to GNOME's gcr-ssh-agent.
# Log out and back in afterwards so the session picks up SSH_AUTH_SOCK again.
set -u

ssh_config="$HOME/.ssh/config"
env_conf="$HOME/.config/environment.d/ssh-agent.conf"
askpass="$HOME/.local/bin/ssh-askpass-trace"
block=$'\nHost *\n    AddKeysToAgent yes'

echo "Re-enabling gcr-ssh-agent..."
systemctl --user unmask gcr-ssh-agent.socket gcr-ssh-agent.service
systemctl --user start gcr-ssh-agent.socket

echo "Disabling OpenSSH ssh-agent.socket..."
systemctl --user disable --now ssh-agent.socket ssh-agent.service 2>/dev/null

if [[ -f $env_conf ]]; then
    rm -v "$env_conf"
fi

# Remove only the block the install appended, so later edits to the config survive.
if [[ -f $ssh_config ]]; then
    content=$(<"$ssh_config")
    if [[ $content == *"$block" ]]; then
        printf '%s\n' "${content%"$block"}" > "$ssh_config"
        echo "Removed 'Host * / AddKeysToAgent yes' block from $ssh_config"
        rm -f "$ssh_config.bak"
    else
        echo "WARNING: AddKeysToAgent block not found at end of $ssh_config; edit it by hand." >&2
        [[ -f $ssh_config.bak ]] && echo "         Original copy: $ssh_config.bak" >&2
    fi
fi

if [[ -f $askpass ]]; then
    rm -v "$askpass"
fi

echo "Done. Log out and back in to finish."
