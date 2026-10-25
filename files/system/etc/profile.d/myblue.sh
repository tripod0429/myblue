# shellcheck shell=sh

# My shell settings, here as secureblue's own are (gnome-disable-jit.sh,
# xx-bash-prompt-command.sh), not in ~/.bashrc or ~/.bash_profile:
# `ujust toggle-bash-environment-lockdown` resets those to /etc/skel and
# locks them. /etc/profile sources this for login shells, /etc/bashrc for
# the others.

if [ "$(/usr/bin/id -u)" != 0 ]; then
    case ":$PATH:" in
        *":$HOME/.ghcup/bin:"*) ;;
        *) export PATH="$HOME/.ghcup/bin:$PATH" ;;
    esac

    # Start the coding agents inside nono. They can write their own config
    # (hooks, plugins), which would run unsandboxed in a session started
    # without it. `command claude` skips the sandbox. --rollback snapshots
    # the launch folder (`nono rollback` restores it); --strict-broker-path
    # refuses to start if the agent could write to a directory on PATH.
    # myblue-agent-check first compares the agents' instructions, skills and
    # agent definitions with the dotfiles, since either sandbox can edit them.
    # nono only grants a folder that exists when it starts, and /tmp is
    # emptied at boot, so the alias makes Claude's temp folder first (its
    # scratchpad and TMPDIR). Without it /tmp is write-only to Claude: it can
    # write files there but not read them back.
    alias claude='myblue-agent-check && mkdir -p -m 700 "/tmp/claude-$(id -u)" && nono run --profile claude-haskell --rollback --strict-broker-path -- claude'

    # myblue-opencode gives opencode its server inside the sandbox.
    alias opencode='myblue-agent-check && nono run --profile opencode-haskell --rollback --strict-broker-path -- myblue-opencode'

    # The ChatGPT sign-in waits for the browser on a random local port.
    # --listen-port 0 allows that, on any interface, so only the login gets it.
    alias opencode-login='myblue-agent-check && nono run --profile opencode-haskell --rollback --strict-broker-path --listen-port 0 -- myblue-opencode auth login'
fi
