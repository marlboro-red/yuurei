# Ghostty shell integration
export module ghostty {
  def has_feature [feature: string] {
    $feature in ($env.GHOSTTY_SHELL_FEATURES | default "" | split row ',')
  }

  # Wrap `ssh` with `ghostty +ssh` and translate the shell-integration
  # feature flags into command options.
  export def --wrapped ssh [...args] {
    if not ((has_feature "ssh-env") or (has_feature "ssh-terminfo")) {
      ^ssh ...$args
      return
    }

    let ghostty = ($env.GHOSTTY_BIN_DIR? | default "") | path join "ghostty"
    mut flags = []
    if not (has_feature "ssh-env") {
      $flags = ($flags ++ ["--forward-env=false"])
    }
    if not (has_feature "ssh-terminfo") {
      $flags = ($flags ++ ["--terminfo=false"])
    }
    ^$ghostty "+ssh" ...$flags "--" ...$args
  }

  # Wrap `sudo` to preserve Ghostty's TERMINFO environment variable
  export def --wrapped sudo [...args] {
    mut sudo_args = $args

    if (has_feature "sudo") {
      # Extract just the sudo options (before the command)
      let sudo_options = (
        $args | take until {|arg|
          not (($arg | str starts-with "-") or ($arg | str contains "="))
        }
      )

      # Prepend TERMINFO preservation flag if not using sudoedit
      if (not ("-e" in $sudo_options or "--edit" in $sudo_options)) {
        $sudo_args = ($args | prepend "--preserve-env=TERMINFO")
      }
    }

    ^sudo ...$sudo_args
  }
}

# Clean up XDG_DATA_DIRS by removing GHOSTTY_SHELL_INTEGRATION_XDG_DIR
if 'GHOSTTY_SHELL_INTEGRATION_XDG_DIR' in $env {
  if 'XDG_DATA_DIRS' in $env {
    $env.XDG_DATA_DIRS = ($env.XDG_DATA_DIRS | str replace $"($env.GHOSTTY_SHELL_INTEGRATION_XDG_DIR):" "")
  }
  hide-env GHOSTTY_SHELL_INTEGRATION_XDG_DIR
}

# Report the working directory to Ghostty (OSC 7) on each prompt so new
# tabs and windows can inherit it (window/tab-inherit-working-directory).
# The path is sent as a file:// URI with forward slashes; on Windows
# Ghostty converts it back to a native path. (yuurei addition: upstream's
# nushell integration does not report the cwd.)
# Guarded so re-sourcing this file in the same process doesn't append a
# duplicate hook (each duplicate would print the OSC 7 sequence once more
# per prompt). The guard is keyed on the PID rather than mere presence:
# nushell exports env vars to children, so a bare flag would be inherited
# by a nested `nu` and wrongly suppress its hook (no cwd reporting at
# all). A nested shell has a different $nu.pid, so it still installs.
if ($env.GHOSTTY_NU_PROMPT_HOOKED? | default '') != $"($nu.pid)" {
  $env.GHOSTTY_NU_PROMPT_HOOKED = $"($nu.pid)"
  $env.config.hooks.pre_prompt = ($env.config.hooks.pre_prompt | append {||
    # Percent-encode '%' first (the receiver percent-decodes), then
    # normalize separators, so a literal % in a path isn't corrupted.
    let p = ($env.PWD | str replace --all '%' '%25' | str replace --all '\' '/')
    let host = ($env.COMPUTERNAME? | default 'localhost')
    print -rn $"\u{1b}]7;file://($host)/($p)\u{7}"
  })
}
