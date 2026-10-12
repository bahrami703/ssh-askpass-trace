# ssh-askpass-trace

An SSH passphrase prompt that shows **which process triggered it**.

GNOME's `gcr-ssh-agent` pops up "unlock private key" dialogs without saying who
asked. This replaces it with the plain OpenSSH `ssh-agent` and an `SSH_ASKPASS`
helper that walks up the parent processes of `ssh`, so the dialog shows the
whole chain, for example:

```
4182  ssh -o SendEnv=GIT_PROTOCOL git@github.com git-upload-pack 'me/repo.git'
        cwd: /home/me/src/repo
4180  git fetch --all
        cwd: /home/me/src/repo
3901  /usr/bin/code
        cwd: /home/me
```

## Tested on

- GNOME (Wayland) on Manjaro

## Requirements

- GNOME, or KDE Plasma 5.25+ (untested); any desktop whose session reads
  `~/.config/environment.d`
- Linux with a systemd user session
- OpenSSH with the `ssh-agent.socket` user unit (shipped on Arch/Manjaro)
- `python3` with PyGObject and GTK 3
- `ss` from iproute2

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/keyhana/ssh-askpass-trace/main/install-ssh-askpass-trace.sh | bash
```

Pass options after `-s --`, for example
`curl -fsSL ... | bash -s -- --force`.

Then log out and back in.

Undo with `~/.local/bin/ssh-askpass-trace-uninstall`.

The installer:

- refuses desktops other than GNOME and KDE unless run with `--force`
- warns about shell, X11 and Plasma startup files that set `SSH_AUTH_SOCK`,
  `SSH_ASKPASS` or start `ssh-agent`, and about gpg-agent `enable-ssh-support`
- writes the helper to `~/.local/bin/ssh-askpass-trace`
- sets `SSH_AUTH_SOCK`, `SSH_ASKPASS` and `SSH_ASKPASS_REQUIRE=prefer` in `~/.config/environment.d/ssh-agent.conf`
- adds `AddKeysToAgent yes` to `~/.ssh/config` (backup in `~/.ssh/config.bak`)
- masks `gcr-ssh-agent` and enables `ssh-agent.socket`
- checks that the agent answers and that the current and next login use it,
  and exits non-zero if not

You are asked for a key's passphrase once per login; the key then stays in the
agent. `SSH_ASKPASS_REQUIRE=prefer` makes `ssh` use the dialog even in a
terminal, so every prompt shows its caller. FIDO "touch your key" messages
still print in the terminal when there is one.

Prompts can also come from `ssh-agent` itself, for example "touch your key"
for a FIDO key that is already in the agent. Then the dialog lists the
processes connected to the agent at that moment, which includes the one
waiting for the signature.

## Known limits

- **KDE Plasma:** untested. A `SSH_ASKPASS=ksshaskpass` line in
  `~/.config/plasma-workspace/env/` may override the helper. Passphrases are no
  longer kept in KWallet.
- **XFCE, XDE and other desktops without a systemd session:** not supported.
  The session ignores `~/.config/environment.d` and often starts its own
  agent, so the helper would go unused. `--force` installs anyway.
- A shell rc file that sets `SSH_AUTH_SOCK` (for example `eval $(ssh-agent)`)
  wins in terminals.
- **VS Code:** its git integration sets its own `SSH_ASKPASS` with
  `SSH_ASKPASS_REQUIRE=force`, which overrides the helper. Set
  `"git.useIntegratedAskPass": false` in VS Code settings. Git HTTPS
  username/password prompts then also go through this dialog, and VS Code's
  built-in GitHub HTTPS sign-in for git is no longer used.
- Linux only: the helper reads `/proc`.

## Uninstall

```sh
~/.local/bin/ssh-askpass-trace-uninstall
```

or run `uninstall-ssh-askpass-trace.sh` from this repo. Then log out and back in.
