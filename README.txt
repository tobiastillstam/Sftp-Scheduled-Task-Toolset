===============================================================================
 SFTP Scheduled Task Toolset - README
 by Tobias Tillstam, Tillnet
===============================================================================

A set of PowerShell tools to schedule unattended SFTP file transfers on Windows
using the WinSCP .NET assembly. It can download files from a server or upload
files to one, on a schedule, running as a Windows scheduled task.

-------------------------------------------------------------------------------
 THE FILES
-------------------------------------------------------------------------------

  Install-SftpTask.GUI.ps1   The graphical front-end. START HERE - it is the
                             easiest way to create and manage transfer tasks.

  Install-SftpTask.ps1       The installer. Registers a scheduled task. The GUI
                             calls this for you; you can also run it directly
                             from the command line for scripted/bulk setup.

  Get-SftpFiles.ps1          Does the actual DOWNLOAD work (server -> local).
                             Run by the scheduled task; not run by hand normally.

  Send-SftpFiles.ps1         Does the actual UPLOAD work (local -> server, then
                             moves each sent file into an "Archive" subfolder).
                             Run by the scheduled task; not run by hand normally.

  IMPORTANT: keep all four files in the SAME folder (e.g. C:\Scripts\Script-SftpTask).
  The GUI looks for the installer beside itself, and the installer looks for the
  transfer scripts beside itself.

-------------------------------------------------------------------------------
 REQUIREMENTS
-------------------------------------------------------------------------------

  - Windows with the desktop experience (for the GUI / WinForms).
  - PowerShell 5.1 or later.
  - The WinSCP .NET assembly (WinSCPnet.dll). Install whichever way suits the box:
        Install-Module -Name WinSCP -Scope AllUsers -Force
    or download the WinSCP ".NET assembly / Automation" package from winscp.net
    and either place WinSCPnet.dll in C:\Program Files (x86)\WinSCP\, or point
    the "WinSCP DLL" field in the GUI at it.
  - Administrator rights. The GUI self-elevates (you will see a UAC prompt) -
    this is required to register tasks and to see/manage tasks that run as SYSTEM.

-------------------------------------------------------------------------------
 QUICK START (GUI)
-------------------------------------------------------------------------------

  1. Right-click Install-SftpTask.GUI.ps1 > "Run with PowerShell"
     (or: powershell -ExecutionPolicy Bypass -File .\Install-SftpTask.GUI.ps1)
  2. Accept the UAC prompt.
  3. On the CREATE tab, fill in:
        - Direction: Download or Upload
        - Task name: a clear name, e.g. "AXT Download" (used for the task,
          the credential file, and the log file)
        - Host, Port, Remote path (ABSOLUTE, e.g. /home/user/outbound/),
          Local path, File mask (e.g. *.csv)
        - Authentication (see below)
        - Host key fingerprint: leave blank to have it scanned and shown for
          you to confirm
        - Schedule: daily at a time, or every N minutes
        - Optional: SMTP relay + alert address for failure emails
        - Optional: tick "Run once after setup to test"
  4. Click "Create Task". A console window opens, you confirm the SFTP
     credential (and, for a named user, that account's Windows password).
  5. Done. Use the MANAGE tab to list, run, edit, or remove tasks later.

-------------------------------------------------------------------------------
 AUTHENTICATION MODES
-------------------------------------------------------------------------------

  Encrypted file (recommended)
      Password stored encrypted with Windows DPAPI. NOTE: it can only be read
      by the same account that created it on the same machine. If the task runs
      as a different user or as SYSTEM, this mode will NOT work - use one below.

  Clear-text JSON
      Password stored in a JSON file, locked down with NTFS permissions. Use
      where the encrypted mode is not viable (e.g. SYSTEM tasks). Anyone who can
      read the file has the password, so the file permissions are the safeguard.

  SSH private key (.ppk)
      Key-based auth, no password stored at all. The most secure option where the
      server supports it. The key must be in PuTTY .ppk format (convert an
      OpenSSH key with PuTTYgen). Recommended for SYSTEM tasks.

  RUN AS SYSTEM: choose "SYSTEM (no password)" under Run as. Because SYSTEM can't
  read a DPAPI-encrypted file made by your account, pair SYSTEM with Clear-text
  JSON or SSH key. The GUI will stop you if you pick the incompatible combination.

-------------------------------------------------------------------------------
 WHAT GETS CREATED (per task)
-------------------------------------------------------------------------------

  Scheduled task     Visible in Task Scheduler at the root (\), named as you chose.
                     Runs "whether the user is logged on or not".

  Credential file    C:\ProgramData\SftpTaskToolset\<TaskName>.cred.xml   (encrypted)
                or   C:\ProgramData\SftpTaskToolset\<TaskName>.config.json (clear-text)
                     One per task, derived from the task name, so tasks never
                     overwrite each other's credentials.

  Log file           <toolset folder>\Logs\<TaskName>_yyyy-MM-dd.log
                     One file per task per day. Old logs are pruned after 30 days.

-------------------------------------------------------------------------------
 UPLOAD BEHAVIOUR (archive)
-------------------------------------------------------------------------------

  Upload tasks move each successfully uploaded file into an "Archive" subfolder
  of the local path. Archiving happens per file, only after that file's transfer
  is confirmed, so a failed transfer never archives a file that did not arrive.
  Files are MOVED (not deleted), so you keep a local record of what was sent.

-------------------------------------------------------------------------------
 DOWNLOAD BEHAVIOUR (remote delete)
-------------------------------------------------------------------------------

  By default, download tasks DELETE each file from the server after a successful
  download (a typical pickup workflow). To keep files on the server instead, the
  underlying script supports a -KeepRemoteFiles switch (run the installer from
  the command line with that switch if you need it).

-------------------------------------------------------------------------------
 MANAGING EXISTING TASKS (GUI Manage tab)
-------------------------------------------------------------------------------

  Refresh   Reload the list of tasks created by this toolset.
  Run now   Trigger the selected task immediately.
  Edit      Load the selected task's settings into the Create tab. Change what
            you need and click Create Task to save (same name = overwrite). The
            stored password is REUSED automatically; you are only re-prompted if
            you change the authentication mode.
  Remove    Unregister the selected task. Its credential file and logs are left
            in place (delete them manually if you want them gone).

-------------------------------------------------------------------------------
 TROUBLESHOOTING
-------------------------------------------------------------------------------

  Task result is 0x1 / it "failed"
      Open the task's log: <toolset folder>\Logs\<TaskName>_<today>.log
      The last lines state what went wrong.

  "No such file or directory" / "Error listing directory"
      The remote path is wrong. Use the ABSOLUTE path on the server
      (e.g. /home/user/outbound/), not a relative one.

  "Could not locate WinSCPnet.dll"
      WinSCP isn't installed where expected. See REQUIREMENTS above.

  Manage tab doesn't show a task you know exists
      Make sure the GUI is running elevated (it self-elevates; accept the UAC
      prompt). SYSTEM tasks are only visible to an elevated process. If you just
      created it, click Refresh.

  Editing a task asks for the password again unexpectedly
      That happens (correctly) if you changed the authentication mode, or if the
      task's credential file was deleted. Otherwise it should reuse silently.

  Nothing transfers but the run "succeeds"
      No files matched the file mask at the source. That's a clean result, not
      an error - put a matching file in place and run again.

-------------------------------------------------------------------------------
 NOTES
-------------------------------------------------------------------------------

  - Schedule times are LOCAL machine time.
  - Email alerts fire on failure (and on partial failure for uploads) only when
    both an SMTP relay and an alert-to address are configured.
  - When editing these .ps1 files, save as ASCII or UTF-8 with BOM so PowerShell
    5.1 reads them correctly.

===============================================================================
