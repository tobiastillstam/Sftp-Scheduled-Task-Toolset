#Requires -Version 5.1

<#
.SYNOPSIS
    Connects to an SFTP server and downloads files using the WinSCP .NET assembly.
    Designed for unattended execution under Windows Task Scheduler.

.DESCRIPTION
    Opens an SFTP session against the specified host using username/password
    authentication, then downloads files from a remote path to a local folder.
    Optionally removes the files from the server after a successful download.

    Built for scheduled, non-interactive runs:
      - Credentials are read from an encrypted file (DPAPI), never stored in the
        script or the task definition.
      - All activity is written to a dated log file with timestamps and severity
        levels, plus a summary of every transfer.
      - The script returns exit code 0 on success and 1 on failure, so Task
        Scheduler's "Last Run Result" reflects the real outcome.

    The server's SSH host key fingerprint must be supplied so the connection can
    be verified - this prevents man-in-the-middle attacks.

    Requires the WinSCP .NET assembly (WinSCPnet.dll). Install via:
        Install-Module -Name WinSCP -Scope AllUsers
    or download the WinSCP Automation/.NET package.

    Supports -WhatIf and -Confirm. The download (and any post-download deletion)
    is wrapped in ShouldProcess.

.PARAMETER HostName
    The SFTP server host name or IP address.

.PARAMETER CredentialPath
    Path to an encrypted credential file created with Export-Clixml. This is the
    default, unattended authentication method. Create it ONCE, logged in as the
    exact account the scheduled task will run under:

        Get-Credential | Export-Clixml -Path 'C:\Secure\sftp-cred.xml'

    The password is encrypted with DPAPI and can only be decrypted by that same
    account on that same machine.

.PARAMETER Credential
    A PSCredential supplied directly (e.g. for interactive testing). Use this OR
    -CredentialPath, not both.

.PARAMETER ConfigPath
    Path to a JSON config file holding the credential in CLEAR TEXT, e.g.
        { "UserName": "svc_sftp", "Password": "..." }
    Use this only when DPAPI-protected storage (-CredentialPath) is not viable.
    SECURITY: anyone who can read this file has the SFTP password. Restrict it
    with NTFS ACLs to just the task's run-as account and Administrators.
    Install-SftpTask.ps1 creates and locks down this file for you.

.PARAMETER UserName
    The SFTP username, used together with -SshPrivateKeyPath for key-based auth.

.PARAMETER SshPrivateKeyPath
    Path to a PuTTY-format private key (.ppk). WinSCP requires .ppk; convert an
    OpenSSH key with PuTTYgen if needed. Key auth avoids storing a reusable
    password on disk and is the recommended approach where the server allows it.

.PARAMETER SshPrivateKeyPassphrase
    Optional SecureString passphrase if the private key is encrypted.

.PARAMETER SshHostKeyFingerprint
    The expected SSH host key fingerprint of the server, e.g.
    'ssh-ed25519 256 xx:xx:...'. Required to verify the server identity.

.PARAMETER RemotePath
    The remote directory (or file) to download from, e.g. '/outbound/'.

.PARAMETER LocalPath
    The local directory to download into. Created if it does not exist.

.PARAMETER FileMask
    Optional WinSCP file mask, e.g. '*.csv' or '*.csv>=1D'. Default is all files.

.PARAMETER PortNumber
    The SFTP port. Defaults to 22.

.PARAMETER KeepRemoteFiles
    By default, files are deleted from the server after a successful download
    (a typical "pickup" workflow). Specify this switch to leave them in place.

.PARAMETER LogDirectory
    Folder for log files. Defaults to a 'Logs' subfolder next to this script.

.PARAMETER LogName
    Base name for the log file, so each task can log separately. The installer
    passes the task name here; the script sanitizes it and appends the date,
    producing e.g. AXT_Download_yyyy-MM-dd.log. Defaults to 'SftpDownload'.

.PARAMETER LogRetentionDays
    Delete log files older than this many days. Default 30. Set to 0 to keep all.

.PARAMETER AssemblyPath
    Full path to WinSCPnet.dll. Defaults to the standard install location.

.EXAMPLE
    .\Get-SftpFiles.ps1 -HostName 'sftp.example.com' -CredentialPath 'C:\Secure\sftp-cred.xml' -SshHostKeyFingerprint 'ssh-ed25519 256 ab:cd:...' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -WhatIf
    Dry run - logs what would be downloaded without transferring anything.

.EXAMPLE
    .\Get-SftpFiles.ps1 -HostName 'sftp.example.com' -CredentialPath 'C:\Secure\sftp-cred.xml' -SshHostKeyFingerprint 'ssh-ed25519 256 ab:cd:...' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -FileMask '*.csv'
    Typical scheduled run: download all .csv files; they are removed from the server on success (the default).

.EXAMPLE
    .\Get-SftpFiles.ps1 -HostName 'sftp.example.com' -CredentialPath 'C:\Secure\sftp-cred.xml' -SshHostKeyFingerprint 'ssh-ed25519 256 ab:cd:...' -RemotePath '/outbound/' -LocalPath 'C:\Inbound' -KeepRemoteFiles
    Same, but leaves the downloaded files on the server.

.EXAMPLE
    .\Get-SftpFiles.ps1 -HostName 'sftp.example.com' -UserName 'svc_sftp' -SshPrivateKeyPath 'C:\Secure\sftp.ppk' -SshHostKeyFingerprint 'ssh-ed25519 256 ab:cd:...' -RemotePath '/outbound/' -LocalPath 'C:\Inbound'
    Authenticates with an SSH private key instead of a password.

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

    [Parameter(Mandatory = $true, ParameterSetName = 'ConfigFile')]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'SshKey')]
    [string]$UserName,

    [Parameter(Mandatory = $true, ParameterSetName = 'SshKey')]
    [string]$SshPrivateKeyPath,

    [Parameter(Mandatory = $false, ParameterSetName = 'SshKey')]
    [securestring]$SshPrivateKeyPassphrase,

    [Parameter(Mandatory = $true)]
    [string]$SshHostKeyFingerprint,

    [Parameter(Mandatory = $true)]
    [string]$RemotePath,

    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    [Parameter(Mandatory = $false)]
    [string]$FileMask,

    [Parameter(Mandatory = $false)]
    [int]$PortNumber = 22,

    [Parameter(Mandatory = $false)]
    [switch]$KeepRemoteFiles,

    [Parameter(Mandatory = $false)]
    [string]$LogDirectory = (Join-Path -Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) -ChildPath 'Logs'),

    [Parameter(Mandatory = $false)]
    [string]$LogName = 'SftpDownload',

    [Parameter(Mandatory = $false)]
    [int]$LogRetentionDays = 30,

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
    # Sends a failure alert via an unauthenticated SMTP relay. No-op unless
    # both -SmtpServer and -EmailTo were supplied. Never throws.
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

$script:LogFile = $null
$session        = $null
$exitCode       = 0
$startTime      = Get-Date

try {
    # --- Set up logging -----------------------------------------------------
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $safeLogName = ($LogName -replace '[^A-Za-z0-9._-]', '_').Trim('_')
    if (-not $safeLogName) { $safeLogName = 'SftpDownload' }
    $script:LogFile = Join-Path -Path $LogDirectory -ChildPath ('{0}_{1}.log' -f $safeLogName, (Get-Date -Format 'yyyy-MM-dd'))

    Write-Log '======================================================================'
    Write-Log "Run started. Script: $($MyInvocation.MyCommand.Name)"
    Write-Log "Host: $HostName  Port: $PortNumber  Remote: $RemotePath  Local: $LocalPath"
    if ($FileMask) { Write-Log "File mask: $FileMask" }

    $removeAfter = -not $KeepRemoteFiles.IsPresent
    if ($removeAfter) {
        Write-Log 'Remote files WILL be deleted after a successful download.' 'WARN'
    }
    else {
        Write-Log 'Remote files will be kept (-KeepRemoteFiles specified).'
    }

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
        Write-Log "Local path '$LocalPath' does not exist; creating it."
        New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
    }

    # --- Load the WinSCP .NET assembly --------------------------------------
    Write-Log "Loading WinSCP assembly from '$AssemblyPath'."
    Add-Type -Path $AssemblyPath

    # --- Build the session options ------------------------------------------
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

    # --- Open the session and download --------------------------------------
    $session = New-Object WinSCP.Session

    Write-Log "Connecting to $HostName on port $PortNumber."
    $session.Open($sessionOptions)
    Write-Log 'Connection established.'

    $remoteSource = $RemotePath
    if ($FileMask) {
        $remoteSource = [WinSCP.RemotePath]::Combine($RemotePath, $FileMask)
    }

    $action = "Download '$remoteSource' to '$LocalPath'"
    if ($removeAfter) { $action += ' (and delete from server)' }

    if ($PSCmdlet.ShouldProcess($HostName, $action)) {

        $transferOptions = New-Object WinSCP.TransferOptions
        $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary

        # Trailing '*' tells WinSCP to drop files into the folder.
        $localTarget = [System.IO.Path]::Combine($LocalPath, '*')

        Write-Log "Starting download: $remoteSource"
        $result = $session.GetFiles($remoteSource, $localTarget, $removeAfter, $transferOptions)
        $result.Check()

        if ($result.Transfers.Count -eq 0) {
            Write-Log "No files matched '$remoteSource'. Nothing downloaded." 'WARN'
        }
        else {
            foreach ($transfer in $result.Transfers) {
                Write-Log "Downloaded: $($transfer.FileName)"
            }
            Write-Log "SUCCESS: $($result.Transfers.Count) file(s) downloaded to '$LocalPath'."
        }
    }
    else {
        Write-Log 'Skipped by -WhatIf / -Confirm; no files transferred.' 'WARN'
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

    # Email on failure. Include a tail of the log so the operator has context.
    if ($exitCode -ne 0) {
        $tail = ''
        if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
            $tail = (Get-Content -LiteralPath $script:LogFile -Tail 25) -join "`r`n"
        }
        $body = @"
The SFTP download job on $env:COMPUTERNAME finished with errors.

Host       : $HostName
Remote     : $RemotePath
Local      : $LocalPath
Exit code  : $exitCode
Finished   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

--- Last log lines ---
$tail
"@
        Send-FailureAlert -Subject "[SFTP] Download FAILED on $env:COMPUTERNAME ($HostName)" -Body $body
    }
}

exit $exitCode
