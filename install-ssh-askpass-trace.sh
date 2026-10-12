#!/usr/bin/env bash
# Install ssh-askpass-trace: SSH passphrase prompts that show which process
# triggered them.
#
# Replaces GNOME's gcr-ssh-agent (which prompts on its own and cannot tell who
# asked) with the plain OpenSSH ssh-agent. ssh itself then asks for the
# passphrase through SSH_ASKPASS, and the helper walks up the parent PIDs of ssh
# to show the caller (git, an IDE, a script...).
#
# Requirements: systemd user session, OpenSSH ssh-agent.socket user unit,
# python3 with PyGObject + GTK 3. Tested on GNOME; KDE Plasma is untested.
# Other desktops are refused unless --force is given.
# Undo: ~/.local/bin/ssh-askpass-trace-uninstall
set -euo pipefail

# Wrapped in main so a truncated `curl | bash` download runs nothing.
main() {

bin_dir="$HOME/.local/bin"
askpass="$bin_dir/ssh-askpass-trace"
uninstaller="$bin_dir/ssh-askpass-trace-uninstall"
env_conf="$HOME/.config/environment.d/ssh-agent.conf"
ssh_config="$HOME/.ssh/config"
agent_sock="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}/ssh-agent.socket"

force=0
for arg in "$@"; do
    case $arg in
        --force) force=1 ;;
        *) echo "Usage: install-ssh-askpass-trace.sh [--force]" >&2; exit 2 ;;
    esac
done

warnings=0
die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; warnings=$((warnings + 1)); }

# --- Preflight -------------------------------------------------------------
# environment.d only reaches apps on desktops whose session runs under systemd
# (GNOME, Plasma >= 5.25). Elsewhere (XFCE, XDE, plain X11/Wayland WMs) the
# install would succeed but nothing would use the new agent.
desktop=${XDG_CURRENT_DESKTOP:-unknown}
case ":${desktop^^}:" in
    *:GNOME:*) ;;
    *:KDE:*)
        warn "KDE Plasma is untested. Check that ksshaskpass or KWallet does not override SSH_ASKPASS." ;;
    *)
        [[ $force == 1 ]] || die "desktop '$desktop' is not supported: its session may ignore" \
            "~/.config/environment.d, so the new agent would go unused. Re-run with --force to install anyway."
        warn "desktop '$desktop' is not supported; installing anyway because of --force" ;;
esac

command -v systemctl >/dev/null || die "systemctl not found"
systemctl --user cat ssh-agent.socket >/dev/null 2>&1 \
    || die "ssh-agent.socket user unit not found (OpenSSH package does not ship it)"
python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null \
    || die "python3 with PyGObject and GTK 3 is required"

# Other places that set the agent or askpass win over environment.d in the
# shells or apps that read them. Only warn: the user decides what to remove.
for f in "$HOME"/.config/plasma-workspace/env/*.sh "$HOME"/.config/environment.d/*.conf \
         "$HOME"/.xprofile "$HOME"/.xinitrc "$HOME"/.xsession "$HOME"/.pam_environment \
         "$HOME"/.profile "$HOME"/.bash_profile "$HOME"/.bashrc \
         "$HOME"/.zshenv "$HOME"/.zprofile "$HOME"/.zshrc "$HOME"/.config/fish/config.fish; do
    [[ -f $f && $f != "$env_conf" ]] || continue
    if hits=$(grep -nE '^[^#]*(SSH_AUTH_SOCK|SSH_ASKPASS|ssh-agent)' "$f"); then
        warn "$f sets the SSH agent or askpass and may override this install:"
        sed 's/^/    /' <<<"$hits" >&2
    fi
done
if grep -qsE '^[[:space:]]*enable-ssh-support' "$HOME/.gnupg/gpg-agent.conf"; then
    warn "~/.gnupg/gpg-agent.conf has enable-ssh-support; gpg-agent may take over SSH_AUTH_SOCK"
fi

mkdir -p "$bin_dir" "$(dirname "$env_conf")" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# --- Askpass helper --------------------------------------------------------
cat > "$askpass" <<'PYEOF'
#!/usr/bin/env python3
"""SSH_ASKPASS helper that shows which process chain triggered the prompt.

ssh runs this program with the prompt text as argv[1]. When our parent is ssh,
walking up the parent PIDs shows who started ssh (git, an IDE, a script...).
When our parent is ssh-agent (e.g. "touch your key" for a key already in the
agent), the parent chain says nothing useful, so we look up the processes that
are connected to the agent socket right now and show their chains instead.
"""
import glob
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402


def proc_info(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmd = f.read().replace(b"\0", b" ").decode(errors="replace").strip()
        with open(f"/proc/{pid}/stat") as f:
            ppid = int(f.read().rsplit(")", 1)[1].split()[1])
    except OSError:
        return None
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        # ssh-agent disables tracing, which hides its cwd from us.
        cwd = "?"
    return cmd, ppid, cwd


def process_chain(pid):
    lines = []
    while pid > 1 and len(lines) < 12:
        info = proc_info(pid)
        if info is None:
            break
        cmd, ppid, cwd = info
        if len(cmd) > 160:
            cmd = cmd[:157] + "..."
        lines.append(f"{pid}  {cmd}\n        cwd: {cwd}")
        pid = ppid
    return "\n".join(lines)


def agent_clients(agent_sock):
    """PIDs of processes with an open connection to the agent socket."""
    try:
        out = subprocess.run(["ss", "-xH"], capture_output=True, text=True).stdout
    except OSError:
        return []
    # Server side of each connection: "u_str ESTAB 0 0 <path> <inode> * <peer inode>"
    peers = set()
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 8 and fields[4] == agent_sock:
            peers.add(f"socket:[{fields[7]}]")
    pids = []
    for fd in glob.glob("/proc/[0-9]*/fd/*"):
        try:
            if os.readlink(fd) in peers:
                pid = int(fd.split("/")[2])
                if pid not in pids:
                    pids.append(pid)
        except (OSError, ValueError):
            continue
    return pids


def describe_trigger():
    parent = os.getppid()
    try:
        with open(f"/proc/{parent}/comm") as f:
            parent_comm = f.read().strip()
    except OSError:
        parent_comm = ""
    agent_sock = os.environ.get("SSH_AUTH_SOCK", "")
    if parent_comm != "ssh-agent" or not agent_sock:
        return "Triggered by (child first):", process_chain(parent)

    chains = [process_chain(pid) for pid in agent_clients(agent_sock) if pid != parent]
    if not chains:
        return "Triggered by ssh-agent; no connected client found:", process_chain(parent)
    return "Agent request from (child first):", "\n\n".join(chains)


def main():
    prompt = sys.argv[1] if len(sys.argv) > 1 else "Passphrase:"
    mode = os.environ.get("SSH_ASKPASS_PROMPT", "")
    heading, chain = describe_trigger()

    sys.stderr.write(f"ssh-askpass-trace: {prompt!r}\n{heading}\n{chain}\n")

    dialog = Gtk.Dialog(title="SSH prompt")
    dialog.set_keep_above(True)
    dialog.set_position(Gtk.WindowPosition.CENTER)
    box = dialog.get_content_area()
    box.set_spacing(8)
    box.set_border_width(12)

    label = Gtk.Label(label=prompt, xalign=0)
    label.set_line_wrap(True)
    box.add(label)

    expander = Gtk.Label(xalign=0)
    expander.set_markup(
        f"<b>{heading}</b>\n<tt>"
        + chain.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        + "</tt>"
    )
    expander.set_selectable(True)
    box.add(expander)

    entry = None
    if mode == "none":
        # Notification only (e.g. FIDO "touch your key"); ssh kills us when done.
        dialog.add_button("Close", Gtk.ResponseType.CANCEL)
    elif mode == "confirm":
        dialog.add_button("Deny", Gtk.ResponseType.CANCEL)
        dialog.add_button("Allow", Gtk.ResponseType.OK)
    else:
        entry = Gtk.Entry()
        # Host key questions ("yes/no") and git HTTPS usernames need visible input.
        entry.set_visibility("yes/no" in prompt or prompt.startswith("Username"))
        entry.set_activates_default(True)
        box.add(entry)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("OK", Gtk.ResponseType.OK)

    dialog.set_default_response(Gtk.ResponseType.OK)
    dialog.show_all()
    response = dialog.run()

    if response != Gtk.ResponseType.OK:
        return 1
    if entry is not None:
        print(entry.get_text())
    else:
        print("yes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod 755 "$askpass"
echo "Installed $askpass"

# --- Uninstaller -----------------------------------------------------------
cat > "$uninstaller" <<'SHEOF'
#!/usr/bin/env bash
# Undo the ssh-askpass-trace setup: go back to GNOME's gcr-ssh-agent.
# Log out and back in afterwards so the session picks up SSH_AUTH_SOCK again.
set -u

ssh_config="$HOME/.ssh/config"
env_conf="$HOME/.config/environment.d/ssh-agent.conf"
askpass="$HOME/.local/bin/ssh-askpass-trace"
block=$'\nHost *\n    AddKeysToAgent yes'

if [[ -L $HOME/.config/systemd/user/gcr-ssh-agent.socket ]]; then
    echo "Re-enabling gcr-ssh-agent..."
    systemctl --user unmask gcr-ssh-agent.socket gcr-ssh-agent.service
    systemctl --user start gcr-ssh-agent.socket
fi

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
rm -f "$0"

echo "Done. Log out and back in to finish."
SHEOF
chmod 755 "$uninstaller"
echo "Installed $uninstaller"

# --- Session environment ---------------------------------------------------
cat > "$env_conf" <<'EOF'
# Plain OpenSSH agent (ssh-agent.socket) instead of GNOME's gcr-ssh-agent,
# so passphrase prompts come from ssh itself via SSH_ASKPASS.
SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/ssh-agent.socket
SSH_ASKPASS=${HOME}/.local/bin/ssh-askpass-trace
# Use the dialog even when ssh runs in a terminal, so every prompt shows its caller.
SSH_ASKPASS_REQUIRE=prefer
EOF
echo "Wrote $env_conf"

# --- ssh config: keep unlocked keys in the agent ---------------------------
if [[ -f $ssh_config ]] && grep -qiE '^[[:space:]]*AddKeysToAgent[[:space:]]' "$ssh_config"; then
    echo "AddKeysToAgent already set in $ssh_config; leaving it alone"
else
    [[ -f $ssh_config ]] && cp -p "$ssh_config" "$ssh_config.bak"
    printf '\nHost *\n    AddKeysToAgent yes\n' >> "$ssh_config"
    chmod 600 "$ssh_config"
    echo "Added 'Host * / AddKeysToAgent yes' to $ssh_config"
fi

# --- Agents ----------------------------------------------------------------
if systemctl --user cat gcr-ssh-agent.socket >/dev/null 2>&1; then
    systemctl --user stop gcr-ssh-agent.socket gcr-ssh-agent.service 2>/dev/null || true
    systemctl --user mask gcr-ssh-agent.socket gcr-ssh-agent.service
    echo "Masked gcr-ssh-agent"
fi
systemctl --user enable --now ssh-agent.socket
systemctl --user set-environment SSH_AUTH_SOCK="$agent_sock" SSH_ASKPASS="$askpass" \
    SSH_ASKPASS_REQUIRE=prefer

# --- Verify ----------------------------------------------------------------
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok:   $*"; }

echo
live_sock=$(systemctl --user show-environment | sed -n 's/^SSH_AUTH_SOCK=//p')
[[ $live_sock == "$agent_sock" ]] && ok "systemd user environment uses $agent_sock" \
    || fail "systemd user environment has SSH_AUTH_SOCK=${live_sock:-<unset>}, expected $agent_sock"

rc=0
SSH_AUTH_SOCK=$agent_sock ssh-add -l >/dev/null 2>&1 || rc=$?
# ssh-add -l: 0 = keys listed, 1 = agent has no keys, 2 = cannot reach agent.
[[ $rc -le 1 ]] && ok "ssh-agent answers on $agent_sock" || fail "ssh-agent does not answer on $agent_sock"

# What the next login gets, after every environment.d file is merged.
generator=""
for g in /usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator \
         /lib/systemd/user-environment-generators/30-systemd-environment-d-generator; do
    [[ -x $g ]] && { generator=$g; break; }
done
if [[ -n $generator ]]; then
    next_env=$("$generator" 2>/dev/null || true)
    next_sock=$(sed -n 's/^SSH_AUTH_SOCK=//p' <<<"$next_env")
    next_askpass=$(sed -n 's/^SSH_ASKPASS=//p' <<<"$next_env")
    [[ $next_sock == "$agent_sock" ]] && ok "next login: SSH_AUTH_SOCK=$next_sock" \
        || fail "next login: SSH_AUTH_SOCK=${next_sock:-<unset>}, expected $agent_sock"
    [[ $next_askpass == "$askpass" ]] && ok "next login: SSH_ASKPASS=$next_askpass" \
        || fail "next login: SSH_ASKPASS=${next_askpass:-<unset>}, expected $askpass"
else
    warn "systemd environment-d generator not found; cannot check what the next login gets"
fi

echo
if [[ $failures -gt 0 ]]; then
    echo "Installed, but $failures check(s) failed (see FAIL lines). The prompt may not appear." >&2
    echo "Undo with: $uninstaller" >&2
    exit 1
fi
[[ $warnings -gt 0 ]] && echo "Installed with $warnings warning(s); review them above."
echo "Done. Log out and back in so every app uses the new agent."
echo "Undo with: $uninstaller"
}

main "$@"
