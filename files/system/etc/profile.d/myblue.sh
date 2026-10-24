# shellcheck shell=sh

# My shell settings, here as secureblue's own are (gnome-disable-jit.sh,
# xx-bash-prompt-command.sh), not in ~/.bashrc or ~/.bash_profile:
# `ujust toggle-bash-environment-lockdown` resets those to /etc/skel and
# locks them. /etc/profile sources this for login shells, /etc/bashrc for
# the others.

if [ "$(/usr/bin/id -u)" != 0 ]; then
    # Use GnuPG as the session-wide SSH agent. This is how COSMIC DE sets SSH_AUTH_SOCK.
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/gnupg/S.gpg-agent.ssh"
    fi

    case ":$PATH:" in
        *":$HOME/.ghcup/bin:"*) ;;
        *) export PATH="$HOME/.ghcup/bin:$PATH" ;;
    esac

    # Start the coding agents inside nono. They can write their own config
    # (hooks, plugins), which would run unsandboxed in a session started
    # without it. `command claude` skips the sandbox.
    alias claude='nono run --profile claude-haskell -- claude'

    # secureblue sets JavaScriptCoreUseJIT=0 globally; opencode's Bun needs the JIT for bun:ffi.
    alias opencode='nono run --profile opencode-haskell -- env -u JavaScriptCoreUseJIT opencode'
fi
