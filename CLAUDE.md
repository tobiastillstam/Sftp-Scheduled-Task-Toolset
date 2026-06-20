# SFTP Scheduled Task Toolset

Project memory for this repo. My global conventions (PowerShell template,
working style, publication rules) live in ~/.claude/CLAUDE.md and already
apply here. This file only covers what is specific to THIS project.

Repo:    tobiastillstam/Sftp-Scheduled-Task-Toolset
License: MIT (Tillnet brand)
Status:  Released as v1.0.0, production-tested on Windows Server.

## Overview

A toolset for running bidirectional SFTP file transfers as scheduled tasks
on Windows Server. Built around four PowerShell scripts plus a WinForms GUI
for creating and editing transfer tasks in place.

## Layout

- `Install-SftpTask.ps1`     - CLI installer: installs prerequisites (WinSCP
                               module), stores credentials, registers the
                               scheduled task. Run once per task, elevated.
- `Install-SftpTask.GUI.ps1` - WinForms front-end for Install-SftpTask.ps1.
                               Collects direction/auth/schedule via a form,
                               then calls the CLI installer. Self-elevates via
                               UAC. Edit-in-place: can update existing tasks.
- `Get-SftpFiles.ps1`        - Download worker: called by the scheduled task.
                               Downloads files from the SFTP server to a local
                               folder; optionally deletes remote files after.
- `Send-SftpFiles.ps1`       - Upload worker: called by the scheduled task.
                               Uploads files from a local folder to the SFTP
                               server; moves each successfully uploaded file to
                               an Archive subfolder (per-file, after confirmed
                               transfer).

## Project-specific conventions

- Bidirectional: direction (download/upload) is chosen at install time and
  determines which worker script the task calls.
- Four authentication modes (apply consistently across all scripts):
  1. DPAPI-encrypted credential file (default; account-bound, machine-bound).
  2. Clear-text JSON config locked with NTFS ACLs (use when DPAPI is not viable,
     e.g. SYSTEM account or cross-account scenarios).
  3. Directly supplied PSCredential object (-Credential parameter).
  4. SSH private key (.ppk, PuTTY format; -UseSshKey + -SshPrivateKeyPath).
- Per-task isolation: each task keeps its own credential file/config and its own
  log. Do not share credential stores or log files across tasks.
- SMTP failure alerts: failed transfers send an email alert when both -SmtpServer
  and -EmailTo are provided. Default From: sftp-job@<computername>.
- DPAPI / run-as alignment: the credential file is encrypted for the account that
  creates it and can only be decrypted by that same account on that same machine.
  The scheduled task MUST run as the same account that ran the installer. Warn if
  -RunAsSystem is combined with the default encrypted credential mode.
- The GUI is a thin UI: all real logic lives in the CLI installer. The GUI maps
  form fields 1:1 to installer parameters and calls Install-SftpTask.ps1 elevated.

## Notes / gotchas

- WinForms closure capture: event handlers in PowerShell WinForms capture
  variables by reference, so handlers wired up in a loop all end up seeing the
  final loop value. The fix is to stash per-control state on $form.Tag and read
  it back inside the handler. Reuse this pattern; do not wire handlers that close
  over loop variables directly.
- SSH keys must be in PuTTY (.ppk) format. OpenSSH keys need PuTTYgen conversion.
- $PSScriptRoot is unavailable when a script runs under Task Scheduler if the
  working directory is not set; the fallback to (Get-Location).Path covers this.

## Commands

- Lint: `Invoke-ScriptAnalyzer -Path . -Recurse`
- Test: no Pester suite yet.
- Run (download task, interactive setup):
  `.\Install-SftpTask.ps1 -HostName 'sftp.example.com' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -DailyAt '03:00' -Test`
- Run (GUI):
  `.\Install-SftpTask.GUI.ps1`  (self-elevates; no parameters needed)
