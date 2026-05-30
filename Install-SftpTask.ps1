#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    One-time setup for the SFTP download job: installs prerequisites, stores the
    SFTP credential securely, and registers the Windows scheduled task that runs
    Get-SftpFiles.ps1.

.DESCRIPTION
    Run this once on the machine that will perform the downloads. It will:

      1. Ensure the WinSCP .NET assembly is available (installs the WinSCP
         PowerShell module from the PSGallery if it cannot be found).
      2. Create the required folders (script location, credential store, local
         download target, log folder).
      3. Prompt for the SFTP username/password and save it as an encrypted file
         using Export-Clixml (DPAPI).
      4. Optionally scan and capture the server's SSH host key fingerprint, so
         you don't have to find it manually.
      5. Register a scheduled task that runs Get-SftpFiles.ps1 on a schedule,
         configured to "Run whether user is logged on or not".

    IMPORTANT - DPAPI / run-as alignment:
        The credential file is encrypted for the account that creates it and can
        only be decrypted by that same account on that same machine. Therefore
        the scheduled task MUST run as the same account that runs THIS setup
        script. By default -RunAsUser is the current user, which keeps them
        aligned. If you point the task at a different service account, run this
        whole script while logged in as that account instead.

    Supports -WhatIf and -Confirm.

.PARAMETER TaskName
    Name for the scheduled task. Default 'SFTP Download'.

.PARAMETER ScriptPath
    Full path to Get-SftpFiles.ps1. Default: a file of that name next to this
    setup script.

.PARAMETER HostName
    SFTP server host name or IP.

.PARAMETER RemotePath
    Remote directory to download from, e.g. '/outbound/'.

.PARAMETER LocalPath
    Local download target folder. Created if missing.

.PARAMETER FileMask
    Optional WinSCP file mask, e.g. '*.csv'.

.PARAMETER PortNumber
    SFTP port. Default 22.

.PARAMETER SshHostKeyFingerprint
    The server's SSH host key fingerprint. If omitted, the script offers to scan
    it from the server and asks you to confirm before trusting it.

.PARAMETER CredentialPath
    Where to store the encrypted credential file (default mode).
    Default 'C:\ProgramData\SftpTaskToolset\sftp-cred.xml'.

.PARAMETER UseClearTextConfig
    Store the SFTP password in a clear-text JSON config file instead of the
    DPAPI-encrypted file. The file is locked down with NTFS ACLs (run-as account
    read, SYSTEM and Administrators full). Use only where DPAPI is not viable.
    NOTE: in clear-text mode the credential is NOT account-bound, so the
    RunAsUser/current-user DPAPI alignment requirement does not apply.

.PARAMETER ConfigPath
    Where to write the clear-text JSON config when -UseClearTextConfig is set.
    Default 'C:\ProgramData\SftpTaskToolset\sftp-config.json'.

.PARAMETER UseSshKey
    Authenticate the task with an SSH private key instead of a password. Requires
    -SshPrivateKeyPath. The key is copied into the secure folder and ACL-locked.
    Recommended over passwords where the server supports key-based auth, since no
    reusable password is stored.

.PARAMETER SshPrivateKeyPath
    Path to a PuTTY-format private key (.ppk) used with -UseSshKey. Convert an
    OpenSSH key with PuTTYgen if needed.

.PARAMETER KeepRemoteFiles
    Pass through to the download job: keep files on the server instead of the
    default behaviour of deleting them after a successful download.

.PARAMETER RunAsUser
    Account the scheduled task runs as. Default: the current user. In the
    default (encrypted) mode this must match the account that creates the
    credential (see DPAPI note above).

.PARAMETER RunAsSystem
    Run the task as the built-in SYSTEM account instead of a named user. No
    Windows password is required. SYSTEM cannot decrypt a DPAPI credential
    created by another user, so combine it with -UseClearTextConfig or
    -UseSshKey (the installer warns if you pick the incompatible combination).

.PARAMETER DailyAt
    Time of day to run, e.g. '03:00'. Mutually exclusive with -RepeatMinutes.

.PARAMETER RepeatMinutes
    Run every N minutes instead of once daily. Mutually exclusive with -DailyAt.

.PARAMETER AssemblyPath
    Full path to WinSCPnet.dll. If omitted, the script locates it from the
    installed WinSCP module.

.PARAMETER SmtpServer
    SMTP relay host for failure alerts. Passed through to the transfer script.
    Alerts are sent only when both -SmtpServer and -EmailTo are provided.

.PARAMETER SmtpPort
    SMTP relay port. Default 25.

.PARAMETER EmailFrom
    From address for alert emails. Defaults (in the transfer script) to
    sftp-job@<computername> if not supplied.

.PARAMETER EmailTo
    One or more recipient addresses for failure alerts.

.PARAMETER Test
    After registering the task, trigger it once, wait for it to finish, report
    the result (LastTaskResult), and print the last 20 lines of today's log so
    you can confirm a clean end-to-end run.

.EXAMPLE
    .\Install-SftpTask.ps1 -HostName 'sftp.example.com' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -FileMask '*.csv' -DailyAt '03:00'
    Full interactive setup that runs the job every day at 03:00.

.EXAMPLE
    .\Install-SftpTask.ps1 -HostName 'sftp.example.com' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -RepeatMinutes 15 -WhatIf
    Shows what would be configured for a job that runs every 15 minutes.

.EXAMPLE
    .\Install-SftpTask.ps1 -HostName 'sftp.example.com' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -DailyAt '03:00' -UseClearTextConfig
    Stores the password in an ACL-restricted clear-text JSON file instead of the encrypted store.

.EXAMPLE
    .\Install-SftpTask.ps1 -HostName 'sftp.example.com' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -DailyAt '03:00' -UseSshKey -SshPrivateKeyPath 'C:\Keys\sftp.ppk' -UserName 'svc_sftp'
    Authenticates with an SSH private key (staged and ACL-locked) instead of a password.

.EXAMPLE
    .\Install-SftpTask.ps1 -HostName 'sftp.example.com' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -DailyAt '03:00' -Test
    Sets everything up, then runs the task once and tails the log to confirm it works.

.NOTES
    Author        : Tobias Tillstam
    Company       : Tillnet
    Version       : 1.0.0
    Date Created  : 2026-05-22
    Last Modified : 2026-05-22

    Change Log
    ----------
    1.0.0 (2026-05-25) - Initial public release on GitHub. Versions reset across
                         all toolset files.

    See CHANGELOG.md in the repository for the full release history.

    Operational notes:
    - Must be run elevated (registers a scheduled task; may install a module
      for all users).
    - You will be prompted twice: once for the SFTP credential, and once for the
      RunAsUser's Windows password (needed to register a task that runs whether
      the user is logged on or not).
    - Re-running with the same -TaskName updates the existing task.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Daily')]
param(
    # Download = pull from server to LocalPath (Get-SftpFiles.ps1).
    # Upload   = push from LocalPath to server, archiving sent files (Send-SftpFiles.ps1).
    [Parameter(Mandatory = $false)]
    [ValidateSet('Download', 'Upload')]
    [string]$Direction = 'Download',

    [Parameter(Mandatory = $false)]
    [string]$TaskName,

    [Parameter(Mandatory = $false)]
    [string]$ScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [Parameter(Mandatory = $true)]
    [string]$RemotePath,

    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    [Parameter(Mandatory = $false)]
    [string]$FileMask,

    # Upload only: local subfolder that successfully sent files are moved into.
    [Parameter(Mandatory = $false)]
    [string]$ArchiveFolderName = 'Archive',

    [Parameter(Mandatory = $false)]
    [int]$PortNumber = 22,

    [Parameter(Mandatory = $false)]
    [string]$SshHostKeyFingerprint,

    # Defaults to a per-task file under C:\ProgramData\SftpTaskToolset derived from
    # the task name (set in the body) so multiple tasks don't share one file.
    [Parameter(Mandatory = $false)]
    [string]$CredentialPath,

    # When set, the SFTP password is written to a clear-text JSON config file
    # (locked down with NTFS ACLs) instead of the DPAPI-encrypted credential
    # file. Use only where the encrypted approach is not viable.
    [Parameter(Mandatory = $false)]
    [switch]$UseClearTextConfig,

    # Defaults to a per-task file (set in the body) like CredentialPath.
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    # When set, the task authenticates with an SSH private key (.ppk) instead of
    # a password. Provide -SshPrivateKeyPath; the script copies the key into the
    # secure folder and ACL-restricts it.
    [Parameter(Mandatory = $false)]
    [switch]$UseSshKey,

    [Parameter(Mandatory = $false)]
    [string]$SshPrivateKeyPath,

    [Parameter(Mandatory = $false)]
    [switch]$KeepRemoteFiles,

    [Parameter(Mandatory = $false)]
    [string]$RunAsUser = "$env:USERDOMAIN\$env:USERNAME",

    # When set, the task runs as the built-in SYSTEM account (LogonType
    # ServiceAccount, no password). SYSTEM cannot decrypt a DPAPI credential
    # created by another user, so pair it with -UseClearTextConfig or -UseSshKey.
    [Parameter(Mandatory = $false)]
    [switch]$RunAsSystem,

    [Parameter(Mandatory = $false, ParameterSetName = 'Daily')]
    [string]$DailyAt = '03:00',

    [Parameter(Mandatory = $true, ParameterSetName = 'Interval')]
    [int]$RepeatMinutes,

    [Parameter(Mandatory = $false)]
    [string]$AssemblyPath,

    # --- Email alerting (optional) ------------------------------------------
    # Passed through to the transfer script so it can email on failure via an
    # unauthenticated SMTP relay. Both -SmtpServer and -EmailTo are needed for
    # alerts to be sent.
    [Parameter(Mandatory = $false)]
    [string]$SmtpServer,

    [Parameter(Mandatory = $false)]
    [int]$SmtpPort = 25,

    [Parameter(Mandatory = $false)]
    [string]$EmailFrom,

    [Parameter(Mandatory = $false)]
    [string[]]$EmailTo,

    # When set (used by the GUI's Edit flow), skip the credential prompt if the
    # credential/config file already exists, so reconfiguring a task's schedule or
    # paths doesn't force re-entering the password. Ignored for SSH-key mode and
    # whenever the target file is missing (then a credential is still required).
    [Parameter(Mandatory = $false)]
    [switch]$ReuseCredential,

    # When set, the task is triggered once immediately after registration and the
    # script waits for it to finish, reports the result, and tails the log.
    [Parameter(Mandatory = $false)]
    [switch]$Test
)

# -------------------------------------------------------------------------
# Begin script body
# -------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

Write-Verbose "Starting $($MyInvocation.MyCommand.Name)"

# Resolve direction-dependent defaults.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ($Direction -eq 'Upload') {
    if (-not $TaskName)   { $TaskName   = 'SFTP Upload' }
    if (-not $ScriptPath) { $ScriptPath = Join-Path -Path $scriptDir -ChildPath 'Send-SftpFiles.ps1' }
}
else {
    if (-not $TaskName)   { $TaskName   = 'SFTP Download' }
    if (-not $ScriptPath) { $ScriptPath = Join-Path -Path $scriptDir -ChildPath 'Get-SftpFiles.ps1' }
}

# Derive per-task credential/config file paths from the task name so multiple
# tasks each get their own file instead of overwriting a single shared one.
# A caller can still override -CredentialPath / -ConfigPath explicitly.
$credBase = 'C:\ProgramData\SftpTaskToolset'
$safeName = ($TaskName -replace '[^A-Za-z0-9._-]', '_').Trim('_')
if (-not $safeName) { $safeName = 'SftpTask' }
if (-not $CredentialPath) { $CredentialPath = Join-Path -Path $credBase -ChildPath "$safeName.cred.xml" }
if (-not $ConfigPath)     { $ConfigPath     = Join-Path -Path $credBase -ChildPath "$safeName.config.json" }

try {
    # --- 1. Resolve / install the WinSCP .NET assembly ----------------------
    Write-Step 'Checking for the WinSCP .NET assembly...'

    if (-not $AssemblyPath) {
        # Common default install location for the standalone .NET package.
        $defaultDll = 'C:\Program Files (x86)\WinSCP\WinSCPnet.dll'

        if (Test-Path -LiteralPath $defaultDll) {
            $AssemblyPath = $defaultDll
        }
        else {
            # Try the WinSCP PowerShell module; install it if absent.
            $module = Get-Module -ListAvailable -Name WinSCP | Select-Object -First 1
            if (-not $module) {
                if ($PSCmdlet.ShouldProcess('PSGallery', 'Install the WinSCP PowerShell module')) {
                    Write-Step 'WinSCP module not found; installing from PSGallery...'
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                        Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
                    }
                    Install-Module -Name WinSCP -Scope AllUsers -Force -AllowClobber
                    $module = Get-Module -ListAvailable -Name WinSCP | Select-Object -First 1
                }
            }
            if ($module) {
                $candidate = Join-Path -Path (Split-Path $module.Path -Parent) -ChildPath 'lib\WinSCPnet.dll'
                if (Test-Path -LiteralPath $candidate) { $AssemblyPath = $candidate }
            }
        }
    }

    if (-not $AssemblyPath -or -not (Test-Path -LiteralPath $AssemblyPath)) {
        throw "Could not locate WinSCPnet.dll. Install WinSCP (Automation package) or run: Install-Module WinSCP -Scope AllUsers, then re-run with -AssemblyPath."
    }
    Write-Host "    Using assembly: $AssemblyPath" -ForegroundColor Gray

    # --- 2. Validate the transfer script ------------------------------------
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        $expected = if ($Direction -eq 'Upload') { 'Send-SftpFiles.ps1' } else { 'Get-SftpFiles.ps1' }
        throw "Transfer script not found: $ScriptPath. Place $expected there or pass -ScriptPath."
    }

    # --- 3. Create folders --------------------------------------------------
    Write-Step 'Creating folders...'
    $credDir = Split-Path -Path $CredentialPath -Parent
    foreach ($dir in @($credDir, $LocalPath)) {
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            if ($PSCmdlet.ShouldProcess($dir, 'Create directory')) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                Write-Host "    Created: $dir" -ForegroundColor Gray
            }
        }
    }

    # --- 4. DPAPI / run-as alignment warning --------------------------------
    $currentUser = "$env:USERDOMAIN\$env:USERNAME"
    $usingEncrypted = (-not $UseClearTextConfig -and -not $UseSshKey)

    if ($RunAsSystem) {
        Write-Host '    Task will run as the built-in SYSTEM account (no password).' -ForegroundColor Gray
        if ($usingEncrypted) {
            Write-Warning ('SYSTEM cannot decrypt a DPAPI credential created by ' + $currentUser + '. ' +
                'The encrypted-credential mode will FAIL under SYSTEM. Use -UseClearTextConfig or ' +
                '-UseSshKey instead, or create the credential file as SYSTEM (e.g. via PsExec -s).')
        }
    }
    elseif ($usingEncrypted -and $RunAsUser -ne $currentUser) {
        Write-Warning ("RunAsUser ('{0}') differs from the current user ('{1}'). " -f $RunAsUser, $currentUser +
            'The encrypted credential created now can only be decrypted by the current user, ' +
            'so the task will FAIL to read it. Re-run this script while logged in as ' + $RunAsUser + '.')
    }

    # --- 5. Capture and store the SFTP credential ---------------------------
    if ($UseSshKey) {
        Write-Step 'Setting up SSH key authentication...'
        if (-not $SshPrivateKeyPath) {
            throw 'SSH key mode requires -SshPrivateKeyPath (a PuTTY .ppk file).'
        }
        if (-not (Test-Path -LiteralPath $SshPrivateKeyPath)) {
            throw "SSH private key not found: $SshPrivateKeyPath. WinSCP requires a PuTTY .ppk file (convert with PuTTYgen if needed)."
        }

        # Copy the key into the secure folder and ACL-restrict it.
        $keyDest = Join-Path -Path $credDir -ChildPath (Split-Path -Path $SshPrivateKeyPath -Leaf)
        if ($PSCmdlet.ShouldProcess($keyDest, 'Copy private key and restrict ACLs')) {
            Copy-Item -LiteralPath $SshPrivateKeyPath -Destination $keyDest -Force
            & icacls $keyDest /inheritance:r `
                /grant:r "${RunAsUser}:(R)" `
                "NT AUTHORITY\SYSTEM:(F)" `
                "BUILTIN\Administrators:(F)" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "icacls returned exit code $LASTEXITCODE; verify the permissions on $keyDest manually."
            }
            Write-Host "    Private key staged (ACL-restricted): $keyDest" -ForegroundColor Gray
        }
        $SshPrivateKeyPath = $keyDest

        # Username is still needed for key auth.
        if (-not $UserName) {
            $UserName = Read-Host "    SFTP username for $HostName"
        }
    }
    else {
        # Edit-reuse: if the relevant credential file already exists and the
        # caller asked to reuse it, leave it untouched and skip the prompt.
        $reuseTarget = if ($UseClearTextConfig) { $ConfigPath } else { $CredentialPath }
        if ($ReuseCredential -and (Test-Path -LiteralPath $reuseTarget)) {
            Write-Step "Reusing existing credential ($reuseTarget); not prompting."
        }
        else {
            Write-Step 'Capturing the SFTP credential...'
            $sftpCred = Get-Credential -Message "Enter the SFTP username and password for $HostName"
            if (-not $sftpCred) { throw 'No credential supplied; aborting.' }

            if ($UseClearTextConfig) {
            Write-Warning ('Clear-text mode: the SFTP password will be written to ' + $ConfigPath +
                '. Anyone who can read that file has the credentials. It will be ACL-restricted to ' +
                $RunAsUser + ', SYSTEM, and Administrators.')

            if ($PSCmdlet.ShouldProcess($ConfigPath, 'Write clear-text JSON config and restrict ACLs')) {
                $configObj = [ordered]@{
                    UserName = $sftpCred.UserName
                    Password = $sftpCred.GetNetworkCredential().Password
                }
                $configObj | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

                # Lock the file down: remove inheritance, grant only the run-as
                # account (read), plus SYSTEM and Administrators (full).
                & icacls $ConfigPath /inheritance:r `
                    /grant:r "${RunAsUser}:(R)" `
                    "NT AUTHORITY\SYSTEM:(F)" `
                    "BUILTIN\Administrators:(F)" | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "icacls returned exit code $LASTEXITCODE; verify the file permissions on $ConfigPath manually."
                }
                Write-Host "    Saved clear-text config (ACL-restricted): $ConfigPath" -ForegroundColor Gray
            }
        }
            else {
                if ($PSCmdlet.ShouldProcess($CredentialPath, 'Save encrypted credential')) {
                    $sftpCred | Export-Clixml -LiteralPath $CredentialPath
                    Write-Host "    Saved encrypted credential: $CredentialPath" -ForegroundColor Gray
                }
            }
        }
    }

    # --- 6. Resolve the SSH host key fingerprint ----------------------------
    if (-not $SshHostKeyFingerprint) {
        Write-Step 'No fingerprint supplied; scanning the server...'
        Add-Type -Path $AssemblyPath
        $scanOptions = New-Object WinSCP.SessionOptions -Property @{
            Protocol   = [WinSCP.Protocol]::Sftp
            HostName   = $HostName
            PortNumber = $PortNumber
        }
        if ($UseSshKey) {
            $scanOptions.UserName          = $UserName
            $scanOptions.SshPrivateKeyPath = $SshPrivateKeyPath
        }
        else {
            $scanOptions.UserName = $sftpCred.UserName
            $scanOptions.Password = $sftpCred.GetNetworkCredential().Password
        }
        $scanSession = New-Object WinSCP.Session
        try {
            $SshHostKeyFingerprint = $scanSession.ScanFingerprint($scanOptions, 'SHA-256')
        }
        finally {
            $scanSession.Dispose()
        }

        Write-Host ''
        Write-Host "    Server reported fingerprint:" -ForegroundColor Yellow
        Write-Host "      $SshHostKeyFingerprint" -ForegroundColor Yellow
        $confirm = Read-Host '    Trust this fingerprint? Verify it with your server admin first. (y/N)'
        if ($confirm -notin @('y', 'Y')) {
            throw 'Fingerprint not confirmed; aborting. Re-run with -SshHostKeyFingerprint once verified.'
        }
    }

    # --- 7. Build the scheduled task argument string ------------------------
    Write-Step 'Building the scheduled task...'
    $argParts = @(
        '-NoProfile'
        '-ExecutionPolicy Bypass'
        ('-File "{0}"'        -f $ScriptPath)
        ('-HostName "{0}"'    -f $HostName)
        ('-SshHostKeyFingerprint "{0}"' -f $SshHostKeyFingerprint)
        ('-RemotePath "{0}"'  -f $RemotePath)
        ('-LocalPath "{0}"'   -f $LocalPath)
        ('-PortNumber {0}'    -f $PortNumber)
    )
    if ($UseSshKey) {
        $argParts += ('-UserName "{0}"' -f $UserName)
        $argParts += ('-SshPrivateKeyPath "{0}"' -f $SshPrivateKeyPath)
    }
    elseif ($UseClearTextConfig) {
        $argParts += ('-ConfigPath "{0}"' -f $ConfigPath)
    }
    else {
        $argParts += ('-CredentialPath "{0}"' -f $CredentialPath)
    }
    if ($FileMask) { $argParts += ('-FileMask "{0}"' -f $FileMask) }
    if ($Direction -eq 'Upload') {
        $argParts += ('-ArchiveFolderName "{0}"' -f $ArchiveFolderName)
    }
    elseif ($KeepRemoteFiles) {
        $argParts += '-KeepRemoteFiles'
    }

    # Pass an explicit log directory so the transfer script never has to rely on
    # $PSScriptRoot / current directory under the scheduled-task account (which
    # may be C:\Windows\System32 and not writable). Defaults to a 'Logs' folder
    # beside the transfer script.
    $scriptDir = Split-Path -Path $ScriptPath -Parent
    $taskLogDir = Join-Path -Path $scriptDir -ChildPath 'Logs'
    $argParts += ('-LogDirectory "{0}"' -f $taskLogDir)

    # Name the log file after the task so each task logs separately, rather than
    # all downloads (or all uploads) sharing one file. The transfer script
    # sanitizes this into a safe filename.
    $argParts += ('-LogName "{0}"' -f $TaskName)

    # Email alerting (optional) - pass through when configured.
    if ($SmtpServer) { $argParts += ('-SmtpServer "{0}"' -f $SmtpServer) }
    if ($SmtpServer -and $SmtpPort) { $argParts += ('-SmtpPort {0}' -f $SmtpPort) }
    if ($EmailFrom)  { $argParts += ('-EmailFrom "{0}"' -f $EmailFrom) }
    if ($EmailTo)    { $argParts += ('-EmailTo "{0}"' -f ($EmailTo -join ',')) }
    if ($AssemblyPath) { $argParts += ('-AssemblyPath "{0}"' -f $AssemblyPath) }

    $arguments = $argParts -join ' '

    # --- 8. Define the task action, trigger, settings -----------------------
    # WorkingDirectory is set to the script folder so a relative current
    # directory never resolves to C:\Windows\System32 under the task account.
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $scriptDir

    if ($PSCmdlet.ParameterSetName -eq 'Interval') {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes)
        $scheduleText = "every $RepeatMinutes minute(s)"
    }
    else {
        # -At interprets the time in the machine's LOCAL time zone (wall-clock),
        # so '03:00' runs at 03:00 local. No UTC conversion is applied.
        $trigger = New-ScheduledTaskTrigger -Daily -At $DailyAt
        $scheduleText = "daily at $DailyAt"
    }

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -DontStopOnIdleEnd `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -MultipleInstances IgnoreNew

    # --- 9. Register the task -----------------------------------------------
    $effectiveRunAs = if ($RunAsSystem) { 'SYSTEM' } else { $RunAsUser }
    Write-Host "    Task will run $scheduleText as '$effectiveRunAs'." -ForegroundColor Gray
    if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {

        $taskDescription = "$(if ($Direction -eq 'Upload') { 'Uploads files to' } else { 'Downloads files from' }) $HostName via SFTP (WinSCP). Managed by Install-SftpTask.ps1."

        if ($RunAsSystem) {
            # SYSTEM is a service account: no password, runs whether logged on or
            # not by nature. RunLevel Highest gives it full rights.
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

            Register-ScheduledTask `
                -TaskName $TaskName `
                -Action $action `
                -Trigger $trigger `
                -Settings $settings `
                -Principal $principal `
                -Description $taskDescription `
                -Force | Out-Null
        }
        else {
            Write-Step "You will now be prompted for $RunAsUser's Windows password (to register the task)."
            $winCred = Get-Credential -UserName $RunAsUser -Message "Windows password for the task account: $RunAsUser"
            if (-not $winCred) { throw 'No Windows password supplied; cannot register a run-whether-logged-on-or-not task.' }

            # NOTE: -User/-Password and -Principal belong to different parameter
            # sets of Register-ScheduledTask and cannot be combined. Supplying
            # -User and -Password makes the task "run whether logged on or not"
            # (LogonType Password), so we let it build the principal itself.
            Register-ScheduledTask `
                -TaskName $TaskName `
                -Action $action `
                -Trigger $trigger `
                -Settings $settings `
                -User $winCred.UserName `
                -Password $winCred.GetNetworkCredential().Password `
                -RunLevel Limited `
                -Description $taskDescription `
                -Force | Out-Null
        }

        Write-Host ''
        Write-Host "Scheduled task '$TaskName' registered successfully." -ForegroundColor Green

        # --- 10. Optional test run ------------------------------------------
        if ($Test) {
            Write-Step 'Running the task once to verify end-to-end...'
            Start-ScheduledTask -TaskName $TaskName

            # Wait for the task to leave the Running state (cap the wait so we
            # never hang the installer).
            $deadline = (Get-Date).AddMinutes(5)
            do {
                Start-Sleep -Seconds 2
                $info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
            } while ($info.LastTaskResult -eq 267009 -and (Get-Date) -lt $deadline)  # 267009 = task currently running

            $code = $info.LastTaskResult
            if ($code -eq 0) {
                Write-Host "Test run completed successfully (LastTaskResult = 0)." -ForegroundColor Green
            }
            elseif ($code -eq 267009) {
                Write-Warning "Task is still running after the wait window; check it manually with Get-ScheduledTaskInfo."
            }
            else {
                Write-Warning ("Test run finished with LastTaskResult = {0} (0x{0:X}). The script's own exit code 1 maps here; check the log below." -f $code)
            }

            # Tail today's log so the operator sees what happened. The log is now
            # named after the task (sanitized the same way the transfer script does).
            $safeLog = ($TaskName -replace '[^A-Za-z0-9._-]', '_').Trim('_')
            if (-not $safeLog) { $safeLog = if ($Direction -eq 'Upload') { 'SftpUpload' } else { 'SftpDownload' } }
            $logDir  = Join-Path -Path (Split-Path -Path $ScriptPath -Parent) -ChildPath 'Logs'
            $logFile = Join-Path -Path $logDir -ChildPath ('{0}_{1}.log' -f $safeLog, (Get-Date -Format 'yyyy-MM-dd'))
            if (Test-Path -LiteralPath $logFile) {
                Write-Host ''
                Write-Host "--- Last 20 log lines ($logFile) ---" -ForegroundColor Cyan
                Get-Content -LiteralPath $logFile -Tail 20 | ForEach-Object { Write-Host "    $_" }
            }
            else {
                Write-Warning "Log file not found at $logFile. If you set a custom -LogDirectory on the task, check there instead."
            }
        }
        else {
            Write-Host "Test it now with:  Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Green
        }
    }
}
catch {
    Write-Error $_
    throw
}
finally {
    Write-Verbose "Finished $($MyInvocation.MyCommand.Name)"
}
