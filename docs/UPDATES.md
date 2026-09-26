# Updating Yuurei

Portable release builds check GitHub Releases once per day and download newer
stable versions automatically. Checks begin after startup and use a short-lived
Windows PowerShell helper; there is no installed service, scheduled task, or
permanent updater process.

Open **Settings > Updates** to see the current version and update status, check
manually, or disable **Automatic updates** (`windows-auto-update = false`). With
automatic updates disabled, a manual check offers **Download update**. Downloading
manually authorizes installation on exit. A previously downloaded update can be
scheduled with **Install on exit**.

Updates install when you exit normally, once all Yuurei processes using that
installation have closed. The updater never closes terminals or kills shells,
and it does not restart the application. If another instance remains open, the
update stays pending. An interrupted download is retried on a later check.

The updater requires the complete extracted release layout, the original
`bin/ghostty.exe` filename, and a writable installation directory. Source builds,
renamed executables, and elevated instances do not use it. Managed environments
that block PowerShell can continue updating by extracting a release manually.
The helper uses a process-local execution policy; it does not change the system
or user PowerShell policy, and Group Policy still applies.

Downloads come only from this repository's stable GitHub releases over HTTPS.
The published SHA256 must match before a ZIP is accepted, and is checked again
before installation. Archive paths, size limits, required files, and Windows
product version are validated. These checks rely on the GitHub release and its
checksum; the release binaries are not code-signed.

Only files provided by the package are replaced. Configuration, profiles,
session state, and unrelated files are preserved. Previous files and a recovery
journal remain in `.yuurei-update` inside the installation until a later update.
Replacement failures trigger rollback; an interrupted transaction is recovered
on the next installation attempt. Keep this directory if recovering from a
power loss or interrupted installation.

Pending downloads and update status are stored per installation beneath
`%LOCALAPPDATA%\yuurei\updates`. Failed installations are shown in Settings and
retried on a later exit. Read-only folders require a manual update or moving the
portable installation to a writable location.

The updater first becomes available in the release that includes this feature;
v0.2.17 and earlier still require a manual upgrade.
