# Ghostty shell integration for PowerShell.
#
# Works with PowerShell 7+ (pwsh) and Windows PowerShell 5.1
# (powershell), so everything here must stay 5.1-compatible.
#
# Normally this is dot-sourced automatically by Ghostty (it rewrites the
# shell command to `pwsh -NoExit -Command . <this file>`). To use it
# manually, add this to your $PROFILE:
#
#   if ($env:GHOSTTY_RESOURCES_DIR) {
#       . "$env:GHOSTTY_RESOURCES_DIR\shell-integration\pwsh\ghostty.ps1"
#   }

# Don't double-install. Test-Path (rather than reading the variable
# directly) keeps this working under Set-StrictMode, which errors on any
# reference to an as-yet-unset variable.
if (Test-Path variable:global:__GhosttyIntegrationDone) { return }
$global:__GhosttyIntegrationDone = $true

$global:__GhosttyFeatures = @{}
foreach ($f in ("$env:GHOSTTY_SHELL_FEATURES" -split ',')) {
    $kv = $f -split ':', 2
    if ($kv[0]) { $global:__GhosttyFeatures[$kv[0]] = $true }
}

# Whether a command is currently executing (between the C and D marks).
$global:__GhosttyCommandActive = $false

# Wrap the line editor so we can emit the "command executed" mark (OSC
# 133;C) at the moment input is submitted, before any output.
$global:__GhosttyOrigReadLine = $function:PSConsoleHostReadLine
function global:PSConsoleHostReadLine {
    $line = if ($global:__GhosttyOrigReadLine) {
        & $global:__GhosttyOrigReadLine
    } else {
        [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine(
            $host.Runspace,
            $ExecutionContext
        )
    }
    [Console]::Write("$([char]27)]133;C$([char]7)")
    $global:__GhosttyCommandActive = $true
    $line
}

# Wrap the prompt to emit, in order: the end-of-command mark with the
# exit code (OSC 133;D), the working directory report (OSC 7), the
# prompt-start mark (OSC 133;A), the original prompt text, and the
# end-of-prompt mark (OSC 133;B).
$global:__GhosttyOrigPrompt = $function:prompt
function global:prompt {
    # Capture these first: anything we run below would clobber them.
    # $LASTEXITCODE is unset until the first external command runs, so
    # guard the read for Set-StrictMode sessions.
    $lastSuccess = $?
    $lastExit = if (Test-Path variable:global:LASTEXITCODE) {
        $global:LASTEXITCODE
    } else {
        $null
    }

    $e = [char]27
    $bel = [char]7
    $out = ""

    if ($global:__GhosttyCommandActive) {
        $global:__GhosttyCommandActive = $false
        $code = if ($lastSuccess -eq $false -and -not $lastExit) {
            1
        } elseif ($lastExit) {
            $lastExit
        } else {
            0
        }
        $out += "$e]133;D;$code$bel"
    }

    $loc = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($loc.Provider.Name -eq "FileSystem") {
        $path = $loc.ProviderPath -replace '\\', '/'
        if ($path -notmatch '^/') { $path = "/$path" }
        $out += "$e]7;file://$([System.Environment]::MachineName)$path$bel"
    }

    if ($global:__GhosttyFeatures['title']) {
        $title = Split-Path -Leaf $loc.Path
        $out += "$e]0;$title$bel"
    }

    $out += "$e]133;A$bel"
    $promptText = if ($global:__GhosttyOrigPrompt) {
        & $global:__GhosttyOrigPrompt
    } else {
        "PS $($loc.Path)> "
    }

    # Restore the exit status the wrapped prompt may have clobbered.
    $global:LASTEXITCODE = $lastExit

    "$out$promptText$e]133;B$bel"
}
