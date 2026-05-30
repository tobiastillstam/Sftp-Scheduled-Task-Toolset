# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/), and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-05-25

Initial public release. All four scripts reset to v1.0.0 from internal
iteration versions; what follows describes the feature set shipping in 1.0.0
rather than a long pre-public history.

### Features

- **Bidirectional SFTP transfer** via the WinSCP .NET assembly:
  - `Get-SftpFiles.ps1` downloads files (optional delete-on-success).
  - `Send-SftpFiles.ps1` uploads files and moves each successfully sent file
    into a local `Archive` subfolder.
- **Four authentication modes:**
  - DPAPI-encrypted credential file (default, account-bound).
  - Clear-text JSON config (ACL-restricted; for SYSTEM or cross-account use).
  - SSH private key (`.ppk`, with optional passphrase).
  - PSCredential passed directly (interactive testing).
- **Run as the current user or as SYSTEM.** The installer warns when SYSTEM is
  paired with the encrypted credential mode, which DPAPI can't decrypt across
  accounts.
- **Per-task isolation:**
  - Each task gets its own credential/config file, named after the task,
    under `C:\ProgramData\SftpTaskToolset\`.
  - Each task writes to its own log file, named after the task, under
    `Logs/<TaskName>_yyyy-MM-dd.log`.
- **Scheduled-task installer (`Install-SftpTask.ps1`)** that registers tasks
  for daily or interval schedules in local time, with `-Force` to update an
  existing task, and an optional `-Test` switch that triggers and tails the
  run.
- **GUI front-end (`Install-SftpTask.GUI.ps1`)** with two tabs:
  - **Create** — collects every option as labelled fields and radio buttons,
    blocks the SYSTEM + encrypted incompatible combination, and launches the
    installer.
  - **Manage** — lists this toolset's tasks (via task description tag or
    script reference), with Refresh / Run now / Edit / Remove. Edit prefills
    the Create tab from the selected task; saving reuses the stored
    credential unless the auth mode changed.
  - Self-elevates on launch (SYSTEM tasks are only enumerable from an
    elevated process).
- **Logging:**
  - One log per task per day, with timestamped severity levels.
  - Configurable retention (default 30 days).
  - Non-zero exit codes on failure so Task Scheduler's `LastTaskResult`
    reflects the real outcome.
- **Optional email alerting** via an unauthenticated SMTP relay, fired on
  failure or partial failure, including the last 20 log lines for context.
- **Operational niceties:** WhatIf/Confirm support, host-key fingerprint
  scanning with confirmation prompt, fallback if `$PSScriptRoot` is empty,
  and pure-ASCII source files so encoding never bites.

### Files

| File                          | Role                                          |
| ----------------------------- | --------------------------------------------- |
| `Install-SftpTask.GUI.ps1`    | Graphical front-end (start here).             |
| `Install-SftpTask.ps1`        | Scheduled-task installer.                     |
| `Get-SftpFiles.ps1`           | Download worker (run by the scheduled task).  |
| `Send-SftpFiles.ps1`          | Upload worker (run by the scheduled task).    |
| `README.md` / `README.txt`    | Operator guide.                               |
| `LICENSE`                     | MIT license.                                  |

[1.0.0]: https://github.com/<your-user>/<repo>/releases/tag/v1.0.0
