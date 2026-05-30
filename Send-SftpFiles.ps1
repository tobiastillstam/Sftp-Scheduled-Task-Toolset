#Requires -Version 5.1

<#
.SYNOPSIS
    Uploads files from a local folder to an SFTP server using the WinSCP .NET
    assembly, then moves each successfully uploaded file to an "Archive" subfolder.
    Designed for unattended execution under Windows Task Scheduler.

.DESCRIPTION
    Opens an SFTP session against the specified host, uploads files matching an
    optional mask from a local folder to a remote path, and - for each file that
    transfers successfully - moves the local copy into an "Archive" subfolder so
    it is not uploaded again on the next run.

    Archiving is per-file and only happens after that file's transfer is
    confirmed, so a partial failure never archives a file that did not arrive.

    Built for scheduled, non-interactive runs:
      - Four authentication modes: DPAPI-encrypted credential file, clear-text
        JSON config, a directly supplied PSCredential, or SSH private key.
      - All activity is written to a dated log file with timestamps and severity
        levels, plus a summary of every transfer.
      - Returns exit code 0 on success and 1 on failure, so Task Scheduler's
        "Last Run Result" reflects the real outcome.

    The server's SSH host key fingerprint must be supplied so the connection can
    be verified - this prevents man-in-the-middle attacks.

    Requires the WinSCP .NET assembly (WinSCPnet.dll). Install via:
        Install-Module -Name WinSCP -Scope AllUsers
    or download the WinSCP Automation/.NET package.

    Supports -WhatIf and -Confirm. The upload (and each archive move) is wrapped
    in ShouldProcess.

.PARAMETER HostName
    The SFTP server host name or IP address.

.PARAMETER CredentialPath
    Path to a DPAPI-encrypted credential file created with Export-Clixml. Create
    it ONCE, logged in as the exact account the scheduled task runs under:
        Get-Credential | Export-Clixml -Path 'C:\Secure\sftp-cred.xml'

.PARAMETER Credential
    A PSCredential supplied directly (e.g. for interactive testing).

.PARAMETER ConfigPath
    Path to a JSON config file holding the credential in CLEAR TEXT, e.g.
        { "UserName": "svc_sftp", "Password": "..." }
    Use only when DPAPI storage is not viable, and ACL-restrict the file.

.PARAMETER UserName
    The SFTP username, used together with -SshPrivateKeyPath for key-based auth.

.PARAMETER SshPrivateKeyPath
    Path to a PuTTY-format private key (.ppk) for key-based authentication.

.PARAMETER SshPrivateKeyPassphrase
    Optional SecureString passphrase if the private key is encrypted.

.PARAMETER SshHostKeyFingerprint
    The expected SSH host key fingerprint of the server. Required.

.PARAMETER LocalPath
    The local folder containing files to upload.

.PARAMETER RemotePath
    The remote directory to upload into, e.g. '/inbound/'.

.PARAMETER FileMask
    Optional wildcard to select which local files to upload, e.g. '*.csv'.
    Default is all files in LocalPath (the Archive subfolder is always skipped).

.PARAMETER ArchiveFolderName
    Name of the local subfolder that successfully uploaded files are moved into.
    Default 'Archive'. Created under LocalPath if it does not exist.

.PARAMETER PortNumber
    The SFTP port. Defaults to 22.

.PARAMETER LogDirectory
    Folder for log files. Defaults to a 'Logs' subfolder next to this script.

.PARAMETER LogName
    Base name for the log file, so each task can log separately. The installer
    passes the task name here; the script sanitizes it and appends the date,
    producing e.g. AXT_Upload_yyyy-MM-dd.log. Defaults to 'SftpUpload'.

.PARAMETER LogRetentionDays
    Delete log files older than this many days. Default 30. Set to 0 to keep all.

.PARAMETER AssemblyPath
    Full path to WinSCPnet.dll. Defaults to the standard install location.

.EXAMPLE
    .\Send-SftpFiles.ps1 -HostName 'sftp.example.com' -CredentialPath 'C:\Secure\sftp-cred.xml' -SshHostKeyFingerprint 'ssh-ed25519 256 ab:cd:...' -LocalPath 'C:\Outbox' -RemotePath '/inbound/' -WhatIf
    Dry run - logs what would be uploaded and archived without changing anything.

.EXAMPLE
    .\Send-SftpFiles.ps1 -HostName 'sftp.example.com' -CredentialPath 'C:\Secure\sftp-cred.xml' -SshHostKeyFingerprint 'ssh-ed25519 256 ab:cd:...' -LocalPath 'C:\Outbox' -RemotePath '/inbound/' -FileMask '*.csv'
    Typical scheduled run: upload all .csv files, then move each one to C:\Outbox\Archive.

.EXAMPLE
    .\Send-SftpFiles.ps1 -HostName 'sftp.example.com' -UserName 'svc_sftp' -SshPrivateKeyPath 'C:\Secure\sftp.ppk' -SshHostKeyFingerprint 'ssh-ed25519 256 ab:cd:...' -LocalPath 'C:\Outbox' -RemotePath '/inbound/'
    Uploads using SSH private key authentication.

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
    - Requires the WinSCP .NET assembly (WinSCPnet.dll):
          Install-Module -Name WinSCP -Scope AllUsers
    - Files are archived locally (moved into the Archive subfolder), not deleted,
      so you retain a record of what was sent.
    - The Archive subfolder is always excluded from the upload set, so archived
      files are never re-sent.
    - #Requires -RunAsAdministrator was intentionally omitted: uploading files
      does not need elevation.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'StoredCredential')]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [Parameter(Mandatory = $true, ParameterSetName = 'StoredCredential')]
    [string]$CredentialPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'DirectCredential')]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential,

    # Path to a JSON config file containing UserName and Password in clear text.
    # SECURITY: protect this file with NTFS ACLs; anyone who can read it has the
    # SFTP credentials.
    [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
    [string]$ConfigPath,

    # SSH private key authentication (PuTTY .ppk format).
    [Parameter(Mandatory = $true, ParameterSetName = 'SshKey')]
    [string]$UserName,

    [Parameter(Mandatory = $true, ParameterSetName = 'SshKey')]
    [string]$SshPrivateKeyPath,

    [Parameter(Mandatory = $false, ParameterSetName = 'SshKey')]
    [securestring]$SshPrivateKeyPassphrase,

    [Parameter(Mandatory = $true)]
    [string]$SshHostKeyFingerprint,

    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    [Parameter(Mandatory = $true)]
    [string]$RemotePath,

    [Parameter(Mandatory = $false)]
    [string]$FileMask = '*.*',

    [Parameter(Mandatory = $false)]
    [string]$ArchiveFolderName = 'Archive',

    [Parameter(Mandatory = $false)]
    [int]$PortNumber = 22,

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = (Join-Path -Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) -ChildPath 'Logs'),

    # Base name for the log file, normally the task name so each task logs to its
    # own file. Sanitized to safe filename characters. Defaults to 'SftpUpload'.
    [Parameter(Mandatory = $false)]
    [string]$LogName = 'SftpUpload',

    [Parameter(Mandatory = $false)]
    [int]$LogRetentionDays = 30,

    # --- Email alerting (optional) ------------------------------------------
    # If both -SmtpServer and -EmailTo are supplied, an alert is sent whenever
    # the run fails OR partially fails. Unauthenticated SMTP relay (no creds).
    [Parameter(Mandatory = $false)]
    [string]$SmtpServer,

    [Parameter(Mandatory = $false)]
    [int]$SmtpPort = 25,

    [Parameter(Mandatory = $false)]
    [string]$EmailFrom = "sftp-job@$env:COMPUTERNAME",

    [Parameter(Mandatory = $false)]
    [string[]]$EmailTo,

    [Parameter(Mandatory = $false)]
    [string]$AssemblyPath = 'C:\Program Files (x86)\WinSCP\WinSCPnet.dll'
)

# -------------------------------------------------------------------------
# Logging helper
# -------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line -ForegroundColor Gray }
    }
}

function Send-FailureAlert {
    <#
        Sends a failure alert via an unauthenticated SMTP relay. No-op unless
        both -SmtpServer and -EmailTo were supplied. Never throws - a mail
        problem must not mask the original job failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    if (-not $SmtpServer -or -not $EmailTo) { return }

    $msg = $null
    try {
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = $EmailFrom
        foreach ($addr in $EmailTo) { $msg.To.Add($addr) }
        $msg.Subject = $Subject
        $msg.Body    = $Body

        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
        $smtp.Send($msg)
        Write-Log "Alert email sent to: $($EmailTo -join ', ')."
    }
    catch {
        Write-Log "Could not send alert email: $($_.Exception.Message)" 'WARN'
    }
    finally {
        if ($msg) { $msg.Dispose() }
    }
}

# -------------------------------------------------------------------------
# Begin script body
# -------------------------------------------------------------------------

$script:LogFile = $null
$session        = $null
$exitCode       = 0
$startTime      = Get-Date

try {
    # --- Set up logging -----------------------------------------------------
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    # Sanitize the log base name to safe filename characters.
    $safeLogName = ($LogName -replace '[^A-Za-z0-9._-]', '_').Trim('_')
    if (-not $safeLogName) { $safeLogName = 'SftpUpload' }
    $script:LogFile = Join-Path -Path $LogDirectory -ChildPath ('{0}_{1}.log' -f $safeLogName, (Get-Date -Format 'yyyy-MM-dd'))

    Write-Log '======================================================================'
    Write-Log "Run started. Script: $($MyInvocation.MyCommand.Name)"
    Write-Log "Host: $HostName  Port: $PortNumber  Local: $LocalPath  Remote: $RemotePath"
    Write-Log "File mask: $FileMask  Archive subfolder: $ArchiveFolderName"

    # --- Log retention ------------------------------------------------------
    if ($LogRetentionDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -Path $LogDirectory -Filter ('{0}_*.log' -f $safeLogName) -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "Removed old log: $($_.Name)"
            }
    }

    # --- Resolve credential -------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'StoredCredential') {
        if (-not (Test-Path -LiteralPath $CredentialPath)) {
            throw "Credential file not found: $CredentialPath. Create it as the task's run-as account: Get-Credential | Export-Clixml -Path '$CredentialPath'"
        }
        Write-Log "Loading credential from '$CredentialPath'."
        $Credential = Import-Clixml -LiteralPath $CredentialPath
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "Config file not found: $ConfigPath. It must be JSON with 'UserName' and 'Password' fields."
        }
        Write-Log "Loading credential from config file '$ConfigPath'."
        Write-Log 'NOTE: this config file holds the password in clear text; ensure it is ACL-restricted.' 'WARN'
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if (-not $config.UserName -or -not $config.Password) {
            throw "Config file '$ConfigPath' must contain non-empty 'UserName' and 'Password' fields."
        }
        $securePass = ConvertTo-SecureString -String $config.Password -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential($config.UserName, $securePass)
    }

    if ($PSCmdlet.ParameterSetName -eq 'SshKey') {
        Write-Log "Authenticating as '$UserName' using SSH key '$SshPrivateKeyPath'."
    }
    else {
        Write-Log "Authenticating as '$($Credential.UserName)'."
    }

    # --- Input validation ---------------------------------------------------
    if (-not (Test-Path -LiteralPath $AssemblyPath)) {
        throw "WinSCP assembly not found at: $AssemblyPath. Install the WinSCP .NET/Automation package or correct -AssemblyPath."
    }
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        throw "Local source folder not found: $LocalPath"
    }

    # Ensure the Archive subfolder exists.
    $archivePath = Join-Path -Path $LocalPath -ChildPath $ArchiveFolderName
    if (-not (Test-Path -LiteralPath $archivePath)) {
        Write-Log "Creating archive subfolder: $archivePath"
        New-Item -ItemType Directory -Path $archivePath -Force | Out-Null
    }

    # --- Gather the files to upload -----------------------------------------
    # Only top-level files in LocalPath, excluding the Archive subfolder itself.
    $filesToUpload = Get-ChildItem -LiteralPath $LocalPath -File -Filter $FileMask -ErrorAction SilentlyContinue

    if (-not $filesToUpload -or $filesToUpload.Count -eq 0) {
        Write-Log "No files matching '$FileMask' found in '$LocalPath'. Nothing to upload." 'WARN'
    }
    else {
        Write-Log "Found $($filesToUpload.Count) file(s) to upload."

        # --- Load the WinSCP .NET assembly ----------------------------------
        Write-Log "Loading WinSCP assembly from '$AssemblyPath'."
        Add-Type -Path $AssemblyPath

        # --- Build the session options --------------------------------------
        $sessionOptions = New-Object WinSCP.SessionOptions -Property @{
            Protocol              = [WinSCP.Protocol]::Sftp
            HostName              = $HostName
            PortNumber            = $PortNumber
            SshHostKeyFingerprint = $SshHostKeyFingerprint
        }

        if ($PSCmdlet.ParameterSetName -eq 'SshKey') {
            if (-not (Test-Path -LiteralPath $SshPrivateKeyPath)) {
                throw "SSH private key not found: $SshPrivateKeyPath. WinSCP requires a PuTTY .ppk file."
            }
            $sessionOptions.UserName          = $UserName
            $sessionOptions.SshPrivateKeyPath = $SshPrivateKeyPath
            if ($SshPrivateKeyPassphrase) {
                $sessionOptions.SecurePrivateKeyPassphrase = $SshPrivateKeyPassphrase
            }
        }
        else {
            $sessionOptions.UserName = $Credential.UserName
            $sessionOptions.Password = $Credential.GetNetworkCredential().Password
        }

        # --- Open the session -----------------------------------------------
        $session = New-Object WinSCP.Session
        Write-Log "Connecting to $HostName on port $PortNumber."
        $session.Open($sessionOptions)
        Write-Log 'Connection established.'

        $transferOptions = New-Object WinSCP.TransferOptions
        $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary

        # Normalise the remote target to end with '/' so WinSCP treats it as a folder.
        $remoteTarget = $RemotePath
        if (-not $remoteTarget.EndsWith('/')) { $remoteTarget += '/' }

        $uploaded = 0
        $failed   = 0

        # --- Upload each file, archive on success ---------------------------
        foreach ($file in $filesToUpload) {
            $remoteFile = $remoteTarget + $file.Name

            if (-not $PSCmdlet.ShouldProcess($file.FullName, "Upload to $remoteFile and archive")) {
                Write-Log "Skipped by -WhatIf / -Confirm: $($file.Name)" 'WARN'
                continue
            }

            try {
                # Upload a single file. The 4th arg ($false) means "do not remove
                # the source"; we handle the local move ourselves after success.
                $result = $session.PutFiles($file.FullName, $remoteFile, $false, $transferOptions)
                $result.Check()   # throws if this transfer failed

                Write-Log "Uploaded: $($file.Name)"

                # Move the local file into the Archive subfolder. Handle the case
                # where a same-named file is already archived from a prior run.
                $dest = Join-Path -Path $archivePath -ChildPath $file.Name
                if (Test-Path -LiteralPath $dest) {
                    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                    $dest  = Join-Path -Path $archivePath -ChildPath ('{0}_{1}{2}' -f $file.BaseName, $stamp, $file.Extension)
                }
                Move-Item -LiteralPath $file.FullName -Destination $dest -Force
                Write-Log "Archived: $($file.Name) -> $ArchiveFolderName\$(Split-Path $dest -Leaf)"

                $uploaded++
            }
            catch {
                # Log and continue so one bad file doesn't abort the whole batch.
                $failed++
                Write-Log "FAILED to upload '$($file.Name)': $($_.Exception.Message)" 'ERROR'
            }
        }

        Write-Log "Upload complete. Succeeded: $uploaded  Failed: $failed."
        if ($failed -gt 0) {
            # Surface partial failure as a non-zero exit code for Task Scheduler.
            $exitCode = 1
        }
    }
}
catch {
    $exitCode = 1
    Write-Log "FAILED: $($_.Exception.Message)" 'ERROR'
    Write-Log "Detail: $($_.InvocationInfo.PositionMessage)" 'ERROR'
}
finally {
    if ($session) {
        Write-Log 'Closing SFTP session.'
        $session.Dispose()
    }
    $duration = (Get-Date) - $startTime
    Write-Log ("Run finished in {0:N1}s. Exit code: {1}." -f $duration.TotalSeconds, $exitCode)
    Write-Log '======================================================================'

    # Email on failure or partial failure. $failed is set in the upload loop;
    # a hard error before the loop leaves it at its initial value.
    if ($exitCode -ne 0) {
        $failedCount = if ($null -ne $failed) { $failed } else { 'unknown' }
        $uploadedCount = if ($null -ne $uploaded) { $uploaded } else { 0 }
        $kind = if ($uploadedCount -gt 0) { 'PARTIAL FAILURE' } else { 'FAILED' }

        $tail = ''
        if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
            $tail = (Get-Content -LiteralPath $script:LogFile -Tail 25) -join "`r`n"
        }
        $body = @"
The SFTP upload job on $env:COMPUTERNAME finished with errors.

Status     : $kind
Host       : $HostName
Local      : $LocalPath
Remote     : $RemotePath
Uploaded   : $uploadedCount
Failed     : $failedCount
Exit code  : $exitCode
Finished   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

--- Last log lines ---
$tail
"@
        Send-FailureAlert -Subject "[SFTP] Upload $kind on $env:COMPUTERNAME ($HostName)" -Body $body
    }
}

exit $exitCode
