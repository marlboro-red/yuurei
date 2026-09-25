# Configuring yuurei

yuurei reads the standard Ghostty configuration — the same format, the same
options, the same themes. The full option reference is upstream's:
[ghostty.org/docs/config](https://ghostty.org/docs/config), or run

```powershell
ghostty +show-config --default --docs
```

to print every option with its documentation. This guide covers what is
Windows-specific: where the file lives, how editing works here, and the
options this fork adds.

## Where the config lives

```
%LOCALAPPDATA%\ghostty\config
```

(e.g. `C:\Users\you\AppData\Local\ghostty\config`). Plain text, one
`key = value` per line, `#` comments. The file doesn't exist until you create
it — yuurei runs fine with no config at all.

If `XDG_CONFIG_HOME` is set it takes precedence, and the file is
`$XDG_CONFIG_HOME\ghostty\config`. Nothing is written to the registry; the
app stays portable.

Other paths yuurei uses under `%LOCALAPPDATA%\ghostty\`:

| Path | What |
| --- | --- |
| `config` | the main configuration |
| `profiles\*.conf` | shell profiles — see [PROFILES.md](PROFILES.md) |
| `session` | saved tabs for `windows-restore-session` |

## Editing and reloading

- **Ctrl+,** opens the built-in settings window. Browse **Appearance**,
  **Terminal**, **Windows & tabs**, or **Input**, or search across all four.
  Edits stay in the window until **Save changes** (**Ctrl+S**). Saving writes
  the config file and reloads yuurei.
- **Reset** removes that setting from the base config when you save.
  **Revert** discards pending edits and rereads the file. If an editor changes
  the file while settings is open, saving reports a conflict; use Revert
  to reload before reapplying your edits.
- Settings edits the **base configuration**. Profile overrides keep taking
  precedence; edit those through [profile files](PROFILES.md). **Open config
  file** opens the base file in Notepad for options not exposed in the UI.
- **Ctrl+F** focuses search, **Tab/Shift+Tab** moves between controls, and
  **Escape** clears a search or closes settings (with a prompt for unsaved
  edits). Use the mouse wheel or **Previous/Next** to browse longer lists.
  The window resizes and follows the configured light/dark interface theme.
- Or edit the file with any editor and press **Ctrl+Shift+,**
  (`reload_config`), or run *Reload configuration* from the command palette
  (**Ctrl+Shift+P**).
- Most options apply on reload. The exceptions say so in their docs — e.g.
  `windows-flip-model` and `win32-input-mode` only affect new terminals.

## A starter config

```ini
# Any Ghostty option works. These are just common picks on Windows.
font-family = Cascadia Code
font-size = 11
theme = dark:catppuccin-mocha,light:catppuccin-latte

# Shell: full command line, resolved from PATH. Unset = pwsh, then
# powershell, then cmd, whichever is found first.
command = nu

# Start in your home directory ("inherit" = wherever yuurei started).
working-directory = home

# Fork extras (see below).
windows-titlebar-thin = true
windows-restore-session = true
```

## Windows-specific options

These options are yuurei additions (or upstream options with
Windows-specific behavior worth knowing):

| Option | Default | What it does |
| --- | --- | --- |
| `windows-titlebar-thin` | `false` | Compact 26 px (logical) tab strip, wezterm-style, with compact caption buttons. Skips the Mica backdrop (DWM's native caption buttons need the full-height strip). Live-reloadable. |
| `windows-restore-session` | `false` | Save open tabs (profile, working directory, manual title) when a window closes or the app quits, and reopen them on the next launch. Splits are not yet recorded — a tab restores as its focused pane. |
| `windows-flip-model` | `false` | Present through a DXGI flip-model swapchain on DirectComposition (the Windows Terminal presentation path) instead of classic SwapBuffers. Classic measures better for typing latency, which is why it's the default; flip can be promoted to hardware overlays and is the base for future per-pixel transparency. New terminals only. |
| `win32-input-mode` | `true` | Honor ConPTY's win32-input-mode request so console apps that read `INPUT_RECORD`s (many Rust/crossterm TUIs) get full modifier fidelity — e.g. Shift+Enter. Set to `false` for legacy VT-only key encoding. New terminals only. |
| `window-vsync` | `true` | On Windows this controls the WGL swap interval and only applies when `windows-flip-model` is enabled. |

## Shells and integration

- **Default shell**: with no `command` set, yuurei looks for `pwsh.exe`, then
  `powershell.exe`, then falls back to `cmd.exe`.
- **Shell integration** (prompt marks, working-directory reporting for tab
  inheritance and session restore, title updates) is injected automatically
  for **pwsh/PowerShell** and **Nushell**, controlled by the standard
  `shell-integration` option. Nushell needs **0.108 or newer** (the
  integration script uses `@complete` attributes).
- Working-directory inheritance for new tabs/splits/windows
  (`window/tab/split-inherit-working-directory`, all on by default) relies on
  the shell reporting its cwd — which the injected integrations do.

## Quick terminal and global hotkeys

The quick terminal is a dockable dropdown window, positioned by the standard
`quick-terminal-position` / `quick-terminal-size` options. Summon it from
anywhere with a `global:` keybind, which yuurei registers as a system-wide
Win32 hotkey:

```ini
keybind = global:f12=toggle_quick_terminal
```

`global:` works for any action, not just the quick terminal.

## Keybinds

All of upstream's keybind syntax works (`keybind = mods+key=action`,
`unconsumed:`, `global:`, chords). Defaults follow upstream's Linux/Windows
set: **Ctrl+Shift+T** new tab, **Ctrl+Shift+P** command palette, **Ctrl+,**
settings, **Ctrl+Shift+,** reload. One fork extra: **Ctrl+Shift+1..9** opens
the Nth shell profile unless you bind that chord yourself — see
[PROFILES.md](PROFILES.md).
