#Requires -Version 5.1

<#
.SYNOPSIS
    WinForms front-end for Install-SftpTask.ps1. Collects all the values
    needed to register an SFTP download or upload scheduled task, then invokes
    the installer so there is a single source of truth for the actual logic.

.DESCRIPTION
    Presents a form with grouped fields and radio buttons for the direction,
    authentication mode, and schedule. Auth-specific fields show or hide based on
    the selected mode so the operator only sees what is relevant. On "Create
    Task" the form validates the inputs, builds the matching parameter set, and
    calls Install-SftpTask.ps1 elevated.

    This is a thin UI: every value maps directly to an installer parameter, and
    the installer still performs the real work (prerequisite checks, credential
    storage, fingerprint scan, task registration, optional test run).

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
    - Run on a machine with the Windows desktop experience (WinForms). Launch
      with:  powershell -ExecutionPolicy Bypass -File .\Install-SftpTask.GUI.ps1
    - The GUI self-elevates (UAC prompt) on launch. Admin rights are required to
      see and manage tasks that run as SYSTEM; without elevation the Manage tab
      would silently miss them.
    - The form launches the installer in a NEW elevated PowerShell window so you
      can watch its prompts (SFTP credential, Windows password) and output there.
    - Install-SftpTask.ps1 must sit in the same folder as this script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InstallerPath = (Join-Path -Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) -ChildPath 'Install-SftpTask.ps1')
)

# -------------------------------------------------------------------------
# Self-elevate. Scheduled tasks that run as SYSTEM (and some others) are only
# fully enumerable from an elevated process, so the Manage tab would otherwise
# miss them. If not already running as administrator, relaunch elevated.
# -------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
        [System.Windows.Forms.MessageBox]::Show(
            'Run this script from a file (not pasted into the console) so it can elevate. Right-click > Run with PowerShell, or launch it elevated.',
            'Cannot elevate', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $psi = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        if ($InstallerPath) { $psi += " -InstallerPath `"$InstallerPath`"" }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $psi -Verb RunAs | Out-Null
    }
    catch {
        # User declined the UAC prompt, or elevation failed.
    }
    return   # the elevated copy takes over; this non-elevated one exits.
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $InstallerPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Installer not found at:`n$InstallerPath`n`nPlace Install-SftpTask.ps1 next to this GUI, or pass -InstallerPath.",
        'Missing installer', 'OK', 'Error') | Out-Null
    return
}

# -------------------------------------------------------------------------
# Helpers to build controls
# -------------------------------------------------------------------------

function New-Label {
    param([string]$Text, [int]$X, [int]$Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.AutoSize = $true
    return $l
}

function New-TextBox {
    param([int]$X, [int]$Y, [int]$Width = 300, [string]$Text = '')
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Width = $Width
    $t.Text = $Text
    return $t
}

# -------------------------------------------------------------------------
# Form
# -------------------------------------------------------------------------

# Open at the smaller of the ideal height or what fits on screen, so low-res
# displays and small RDP windows get a usable window with scrolling rather than
# a form taller than the screen.
$idealHeight = 915
$workingHeight = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
$startHeight = [Math]::Min($idealHeight, $workingHeight - 20)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'SFTP Task Setup'
$form.Size = New-Object System.Drawing.Size(580, $startHeight)
$form.MinimumSize = New-Object System.Drawing.Size(580, 300)
$form.StartPosition = 'CenterScreen'
# Sizable so users can grow it on a big screen; content scrolls when shorter.
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true

# Tabbed layout: "Create" (the build form) and "Manage" (list/edit/remove).
# Anchored so it grows/shrinks with the window; the footer stays pinned below.
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(5, 5)
$tabs.Size = New-Object System.Drawing.Size(560, ($form.ClientSize.Height - 30))
$tabs.Anchor = 'Top,Bottom,Left,Right'

$tabCreate = New-Object System.Windows.Forms.TabPage
$tabCreate.Text = 'Create'
$tabCreate.AutoScroll = $true
$tabManage = New-Object System.Windows.Forms.TabPage
$tabManage.Text = 'Manage'
$tabManage.AutoScroll = $true

$tabs.Controls.AddRange(@($tabCreate, $tabManage))
$form.Controls.Add($tabs)

# Attribution / version footer along the bottom of the window. Positioned and
# sized against the form's CLIENT area (not the outer window size) so it stays
# inside the visible area; anchored to the bottom so it tracks on resize.
$ScriptVersion = '1.0.0'
$ScriptReleaseDate = '2026-05-25'
$clientH = $form.ClientSize.Height
$lblFooter = New-Object System.Windows.Forms.Label
$lblFooter.Text = ("by Tobias Tillstam, Tillnet  -  v{0}  -  {1}" -f $ScriptVersion, $ScriptReleaseDate)
$lblFooter.Size = New-Object System.Drawing.Size(545, 18)
$lblFooter.Location = New-Object System.Drawing.Point(10, ($clientH - 22))
$lblFooter.Anchor = 'Bottom,Left,Right'
$lblFooter.TextAlign = 'MiddleRight'
$lblFooter.ForeColor = [System.Drawing.Color]::Gray
$lblFooter.Font = New-Object System.Drawing.Font($lblFooter.Font.FontFamily, 7.5)
$form.Controls.Add($lblFooter)
$lblFooter.BringToFront()

# All the Create-form groupboxes below add themselves to this container instead
# of directly to the form, so they live on the Create tab.
$createHost = $tabCreate

# The edit snapshot (task name + auth mode of a task loaded via Edit) is stored
# on $form.Tag rather than a $script: variable, so both button closures read the
# same live value. $form.Tag stays $null for a fresh create.

$y = 15

# --- Direction ----------------------------------------------------------
$grpDir = New-Object System.Windows.Forms.GroupBox
$grpDir.Text = 'Direction'
$grpDir.Location = New-Object System.Drawing.Point(15, $y)
$grpDir.Size = New-Object System.Drawing.Size(515, 50)

$rbDownload = New-Object System.Windows.Forms.RadioButton
$rbDownload.Text = 'Download (server -> local)'
$rbDownload.Location = New-Object System.Drawing.Point(15, 20)
$rbDownload.AutoSize = $true
$rbDownload.Checked = $true

$rbUpload = New-Object System.Windows.Forms.RadioButton
$rbUpload.Text = 'Upload (local -> server, archive sent files)'
$rbUpload.Location = New-Object System.Drawing.Point(230, 20)
$rbUpload.AutoSize = $true

$grpDir.Controls.AddRange(@($rbDownload, $rbUpload))
$createHost.Controls.Add($grpDir)
$y += 60

# --- Task ---------------------------------------------------------------
$grpTask = New-Object System.Windows.Forms.GroupBox
$grpTask.Text = 'Task'
$grpTask.Location = New-Object System.Drawing.Point(15, $y)
$grpTask.Size = New-Object System.Drawing.Size(515, 105)

$grpTask.Controls.Add((New-Label 'Task name:' 15 25))
$txtTaskName = New-TextBox 150 22 340
$grpTask.Controls.Add($txtTaskName)
$lblTaskHint = New-Label '(blank = "SFTP Download" / "SFTP Upload")' 150 45
$lblTaskHint.ForeColor = [System.Drawing.Color]::Gray
$lblTaskHint.Font = New-Object System.Drawing.Font($lblTaskHint.Font.FontFamily, 7.5)
$grpTask.Controls.Add($lblTaskHint)

$grpTask.Controls.Add((New-Label 'Run as:' 15 75))
$rbRunUser = New-Object System.Windows.Forms.RadioButton
$rbRunUser.Text = 'Current user (password)'
$rbRunUser.Location = New-Object System.Drawing.Point(150, 73)
$rbRunUser.AutoSize = $true
$rbRunUser.Checked = $true
$grpTask.Controls.Add($rbRunUser)

$rbRunSystem = New-Object System.Windows.Forms.RadioButton
$rbRunSystem.Text = 'SYSTEM (no password)'
$rbRunSystem.Location = New-Object System.Drawing.Point(330, 73)
$rbRunSystem.AutoSize = $true
$grpTask.Controls.Add($rbRunSystem)

$createHost.Controls.Add($grpTask)
$y += 115

# --- Connection ---------------------------------------------------------
$grpConn = New-Object System.Windows.Forms.GroupBox
$grpConn.Text = 'Connection'
$grpConn.Location = New-Object System.Drawing.Point(15, $y)
$grpConn.Size = New-Object System.Drawing.Size(515, 175)

$grpConn.Controls.Add((New-Label 'Host name / IP:' 15 25))
$txtHost = New-TextBox 150 22 340
$grpConn.Controls.Add($txtHost)

$grpConn.Controls.Add((New-Label 'Port:' 15 55))
$txtPort = New-TextBox 150 52 80 '22'
$grpConn.Controls.Add($txtPort)

$grpConn.Controls.Add((New-Label 'Remote path (absolute):' 15 85))
$txtRemote = New-TextBox 150 82 340 '/home/user/outbound/'
$grpConn.Controls.Add($txtRemote)

$grpConn.Controls.Add((New-Label 'Local path:' 15 115))
$txtLocal = New-TextBox 150 112 340 'C:\Inbound'
$grpConn.Controls.Add($txtLocal)

$grpConn.Controls.Add((New-Label 'File mask:' 15 145))
$txtMask = New-TextBox 150 142 150 '*.csv'
$grpConn.Controls.Add($txtMask)

# Archive folder (upload only) shares the file-mask row's right side.
$lblArchive = New-Label 'Archive subfolder:' 310 145
$grpConn.Controls.Add($lblArchive)
$txtArchive = New-TextBox 430 142 60 'Archive'
$grpConn.Controls.Add($txtArchive)

$createHost.Controls.Add($grpConn)
$y += 185

# --- Authentication -----------------------------------------------------
$grpAuth = New-Object System.Windows.Forms.GroupBox
$grpAuth.Text = 'Authentication'
$grpAuth.Location = New-Object System.Drawing.Point(15, $y)
$grpAuth.Size = New-Object System.Drawing.Size(515, 105)

$rbEncrypted = New-Object System.Windows.Forms.RadioButton
$rbEncrypted.Text = 'Encrypted file'
$rbEncrypted.Location = New-Object System.Drawing.Point(15, 22)
$rbEncrypted.AutoSize = $true
$rbEncrypted.Checked = $true

$rbClear = New-Object System.Windows.Forms.RadioButton
$rbClear.Text = 'Clear-text JSON'
$rbClear.Location = New-Object System.Drawing.Point(150, 22)
$rbClear.AutoSize = $true

$rbSshKey = New-Object System.Windows.Forms.RadioButton
$rbSshKey.Text = 'SSH key (.ppk)'
$rbSshKey.Location = New-Object System.Drawing.Point(300, 22)
$rbSshKey.AutoSize = $true

$grpAuth.Controls.AddRange(@($rbEncrypted, $rbClear, $rbSshKey))

# SSH key fields (shown only for the key mode).
$lblUser = New-Label 'Username:' 15 52
$grpAuth.Controls.Add($lblUser)
$txtUser = New-TextBox 110 49 200
$grpAuth.Controls.Add($txtUser)

$lblKey = New-Label 'Private key (.ppk):' 15 80
$grpAuth.Controls.Add($lblKey)
$txtKey = New-TextBox 110 77 310
$grpAuth.Controls.Add($txtKey)

$btnKeyBrowse = New-Object System.Windows.Forms.Button
$btnKeyBrowse.Text = '...'
$btnKeyBrowse.Location = New-Object System.Drawing.Point(425, 76)
$btnKeyBrowse.Size = New-Object System.Drawing.Size(35, 23)
$btnKeyBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'PuTTY key (*.ppk)|*.ppk|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { $txtKey.Text = $dlg.FileName }
})
$grpAuth.Controls.Add($btnKeyBrowse)

$createHost.Controls.Add($grpAuth)
$y += 115

# --- Host key fingerprint ----------------------------------------------
$grpFp = New-Object System.Windows.Forms.GroupBox
$grpFp.Text = 'Host key fingerprint & WinSCP location'
$grpFp.Location = New-Object System.Drawing.Point(15, $y)
$grpFp.Size = New-Object System.Drawing.Size(515, 130)

$txtFp = New-TextBox 15 22 480
$grpFp.Controls.Add($txtFp)
$lblFpHint = New-Label 'Leave blank to have the installer scan and prompt you to confirm it.' 15 48
$lblFpHint.ForeColor = [System.Drawing.Color]::Gray
$grpFp.Controls.Add($lblFpHint)

$grpFp.Controls.Add((New-Label 'WinSCP DLL:' 15 78))
$txtAssembly = New-TextBox 100 75 320
$grpFp.Controls.Add($txtAssembly)

$btnAsmBrowse = New-Object System.Windows.Forms.Button
$btnAsmBrowse.Text = '...'
$btnAsmBrowse.Location = New-Object System.Drawing.Point(425, 74)
$btnAsmBrowse.Size = New-Object System.Drawing.Size(35, 23)
$btnAsmBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'WinSCP assembly (WinSCPnet.dll)|WinSCPnet.dll|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { $txtAssembly.Text = $dlg.FileName }
})
$grpFp.Controls.Add($btnAsmBrowse)

$lblAsmHint = New-Label 'Optional. Leave blank if WinSCP is installed normally or via the WinSCP module.' 15 102
$lblAsmHint.ForeColor = [System.Drawing.Color]::Gray
$grpFp.Controls.Add($lblAsmHint)

$createHost.Controls.Add($grpFp)
$y += 140

# --- Schedule and alerting ---------------------------------------------
$grpSched = New-Object System.Windows.Forms.GroupBox
$grpSched.Text = 'Schedule & alerting'
$grpSched.Location = New-Object System.Drawing.Point(15, $y)
$grpSched.Size = New-Object System.Drawing.Size(515, 160)

$rbDaily = New-Object System.Windows.Forms.RadioButton
$rbDaily.Text = 'Daily at'
$rbDaily.Location = New-Object System.Drawing.Point(15, 22)
$rbDaily.AutoSize = $true
$rbDaily.Checked = $true
$grpSched.Controls.Add($rbDaily)

$txtDaily = New-TextBox 95 20 70 '03:00'
$grpSched.Controls.Add($txtDaily)

$rbInterval = New-Object System.Windows.Forms.RadioButton
$rbInterval.Text = 'Every'
$rbInterval.Location = New-Object System.Drawing.Point(200, 22)
$rbInterval.AutoSize = $true
$grpSched.Controls.Add($rbInterval)

$txtInterval = New-TextBox 270 20 50 '15'
$grpSched.Controls.Add($txtInterval)
$grpSched.Controls.Add((New-Label 'minutes' 325 22))

$grpSched.Controls.Add((New-Label 'SMTP relay:' 15 55))
$txtSmtp = New-TextBox 95 52 200
$grpSched.Controls.Add($txtSmtp)
$grpSched.Controls.Add((New-Label 'Port:' 310 55))
$txtSmtpPort = New-TextBox 350 52 50 '25'
$grpSched.Controls.Add($txtSmtpPort)

$grpSched.Controls.Add((New-Label 'Alert to:' 15 85))
$txtEmail = New-TextBox 95 82 200
$grpSched.Controls.Add($txtEmail)
$grpSched.Controls.Add((New-Label 'From:' 310 85))
$txtEmailFrom = New-TextBox 350 82 150
$grpSched.Controls.Add($txtEmailFrom)
$lblFromHint = New-Label 'From blank = sftp-job@<computername>. Alerts need relay + alert-to.' 15 108
$lblFromHint.ForeColor = [System.Drawing.Color]::Gray
$lblFromHint.Font = New-Object System.Drawing.Font($lblFromHint.Font.FontFamily, 7.5)
$grpSched.Controls.Add($lblFromHint)

$chkTest = New-Object System.Windows.Forms.CheckBox
$chkTest.Text = 'Run once after setup to test (-Test)'
$chkTest.Location = New-Object System.Drawing.Point(15, 130)
$chkTest.AutoSize = $true
$grpSched.Controls.Add($chkTest)

$createHost.Controls.Add($grpSched)
$y += 170

# --- Buttons ------------------------------------------------------------
$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text = 'Create Task'
$btnCreate.Location = New-Object System.Drawing.Point(310, $y)
$btnCreate.Size = New-Object System.Drawing.Size(105, 30)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(425, $y)
$btnCancel.Size = New-Object System.Drawing.Size(105, 30)
$btnCancel.Add_Click({ $form.Close() })

$createHost.Controls.AddRange(@($btnCreate, $btnCancel))

# -------------------------------------------------------------------------
# Manage tab - list, run, edit, and remove tasks made by this toolset
# -------------------------------------------------------------------------

$lvTasks = New-Object System.Windows.Forms.ListView
$lvTasks.Location = New-Object System.Drawing.Point(15, 15)
$lvTasks.Size = New-Object System.Drawing.Size(515, 380)
$lvTasks.View = 'Details'
$lvTasks.FullRowSelect = $true
$lvTasks.MultiSelect = $false
$lvTasks.GridLines = $true
[void]$lvTasks.Columns.Add('Task name', 150)
[void]$lvTasks.Columns.Add('Dir', 60)
[void]$lvTasks.Columns.Add('Host', 150)
[void]$lvTasks.Columns.Add('State', 70)
[void]$lvTasks.Columns.Add('Last result', 75)
$tabManage.Controls.Add($lvTasks)

$lblManageHint = New-Label 'Shows tasks created by this tool (matched by description tag or a reference to Get-/Send-SftpFiles.ps1).' 15 400
$lblManageHint.ForeColor = [System.Drawing.Color]::Gray
$lblManageHint.Font = New-Object System.Drawing.Font($lblManageHint.Font.FontFamily, 7.5)
$lblManageHint.Size = New-Object System.Drawing.Size(515, 16)
$tabManage.Controls.Add($lblManageHint)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'
$btnRefresh.Location = New-Object System.Drawing.Point(15, 425)
$btnRefresh.Size = New-Object System.Drawing.Size(110, 30)
$tabManage.Controls.Add($btnRefresh)

$btnRunNow = New-Object System.Windows.Forms.Button
$btnRunNow.Text = 'Run now'
$btnRunNow.Location = New-Object System.Drawing.Point(145, 425)
$btnRunNow.Size = New-Object System.Drawing.Size(110, 30)
$tabManage.Controls.Add($btnRunNow)

$btnEdit = New-Object System.Windows.Forms.Button
$btnEdit.Text = 'Edit'
$btnEdit.Location = New-Object System.Drawing.Point(290, 425)
$btnEdit.Size = New-Object System.Drawing.Size(110, 30)
$tabManage.Controls.Add($btnEdit)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = 'Remove'
$btnRemove.Location = New-Object System.Drawing.Point(420, 425)
$btnRemove.Size = New-Object System.Drawing.Size(110, 30)
$tabManage.Controls.Add($btnRemove)

# Parse a registered task's PowerShell argument string into a hashtable of
# -Param => value. Switches (no following value) map to $true.
function ConvertFrom-TaskArguments {
    param([string]$ArgString)
    $result = @{}
    # Tokenize honoring double-quoted values.
    $tokens = [System.Text.RegularExpressions.Regex]::Matches($ArgString, '("[^"]*"|\S+)') |
        ForEach-Object { $_.Value.Trim('"') }
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $tok = $tokens[$i]
        if ($tok -like '-*') {
            $name = $tok.TrimStart('-')
            $next = if ($i + 1 -lt $tokens.Count) { $tokens[$i + 1] } else { $null }
            if ($null -ne $next -and $next -notlike '-*') {
                $result[$name] = $next
                $i++
            }
            else {
                $result[$name] = $true
            }
        }
    }
    return $result
}

# Load this tool's tasks into the ListView.
$loadTasks = {
    $lvTasks.Items.Clear()
    try {
        $everything = @(Get-ScheduledTask -ErrorAction Stop)

        $all = @()
        foreach ($task in $everything) {
            # Build the argument text with an explicit loop so the outer task
            # variable is never shadowed by a nested pipeline's $_.
            $argText = ''
            foreach ($act in @($task.Actions)) {
                if ($act.Arguments) { $argText += ' ' + $act.Arguments }
            }
            $desc = [string]$task.Description

            $byDesc   = $desc -like '*Install-SftpTask.ps1*'
            $byScript = ($argText -like '*Get-SftpFiles.ps1*') -or ($argText -like '*Send-SftpFiles.ps1*')

            if ($byDesc -or $byScript) { $all += $task }
        }

        foreach ($t in $all) {
            try {
                $argStr = ($t.Actions | Select-Object -First 1).Arguments
                $parsed = ConvertFrom-TaskArguments -ArgString $argStr
                $dir = if ($parsed.ContainsKey('ArchiveFolderName')) { 'Up' } else { 'Down' }

                # Get-ScheduledTaskInfo can throw for some states/accounts; don't
                # let one failure abort the whole list.
                $lastResult = 'n/a'
                try {
                    $info = $t | Get-ScheduledTaskInfo
                    $lastResult = ('0x{0:X}' -f $info.LastTaskResult)
                } catch { }

                $item = New-Object System.Windows.Forms.ListViewItem([string]$t.TaskName)
                [void]$item.SubItems.Add($dir)
                [void]$item.SubItems.Add([string]$parsed['HostName'])
                [void]$item.SubItems.Add([string]$t.State)
                [void]$item.SubItems.Add($lastResult)
                $item.Tag = @{ Task = $t; Parsed = $parsed }
                [void]$lvTasks.Items.Add($item)
            }
            catch {
                # Still show the task so it can be managed, even if parsing failed.
                $item = New-Object System.Windows.Forms.ListViewItem([string]$t.TaskName)
                [void]$item.SubItems.Add('?')
                [void]$item.SubItems.Add('(parse error)')
                [void]$item.SubItems.Add([string]$t.State)
                [void]$item.SubItems.Add('n/a')
                $item.Tag = @{ Task = $t; Parsed = @{} }
                [void]$lvTasks.Items.Add($item)
            }
        }
        if ($lvTasks.Items.Count -eq 0) {
            $lblManageHint.Text = "No matching tasks. ($($everything.Count) tasks scanned in total.)"
        }
        else {
            $lblManageHint.Text = "$($lvTasks.Items.Count) task(s) shown of $($everything.Count) scanned."
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not list scheduled tasks:`n$($_.Exception.Message)",
            'Error', 'OK', 'Error') | Out-Null
    }
}.GetNewClosure()

# Helper: get the selected task's stored data, or $null.
$getSelected = {
    if ($lvTasks.SelectedItems.Count -eq 0) { return $null }
    return $lvTasks.SelectedItems[0].Tag
}.GetNewClosure()

$btnRefresh.Add_Click($loadTasks)

$btnRunNow.Add_Click({
    $sel = & $getSelected
    if (-not $sel) {
        [System.Windows.Forms.MessageBox]::Show('Select a task first.', 'No selection', 'OK', 'Information') | Out-Null
        return
    }
    try {
        Start-ScheduledTask -TaskName $sel.Task.TaskName
        [System.Windows.Forms.MessageBox]::Show(
            "Started '$($sel.Task.TaskName)'. Use Refresh to see the result, or check its log.",
            'Run now', 'OK', 'Information') | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not start the task:`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
    }
}.GetNewClosure())

$btnRemove.Add_Click({
    $sel = & $getSelected
    if (-not $sel) {
        [System.Windows.Forms.MessageBox]::Show('Select a task first.', 'No selection', 'OK', 'Information') | Out-Null
        return
    }
    $name = $sel.Task.TaskName
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Remove the scheduled task '$name'?`n`nThis unregisters the task only. Its credential file and logs are left in place.",
        'Confirm removal', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }
    try {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        [System.Windows.Forms.MessageBox]::Show("Removed '$name'.", 'Removed', 'OK', 'Information') | Out-Null
        & $loadTasks
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not remove the task:`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
    }
}.GetNewClosure())

# -------------------------------------------------------------------------
# Show/hide auth-specific and direction-specific fields
# -------------------------------------------------------------------------

$updateVisibility = {
    $isKey = $rbSshKey.Checked
    $lblUser.Visible = $isKey
    $txtUser.Visible = $isKey
    $lblKey.Visible  = $isKey
    $txtKey.Visible  = $isKey
    $btnKeyBrowse.Visible = $isKey

    $isUpload = $rbUpload.Checked
    $lblArchive.Visible = $isUpload
    $txtArchive.Visible = $isUpload
}.GetNewClosure()

# Edit: prefill the Create tab from the selected task's stored arguments, then
# switch to it. The password is never recovered (it lives in the credential
# file); on save, the existing credential is reused unless the auth mode changes.
$btnEdit.Add_Click({
    $sel = & $getSelected
    if (-not $sel) {
        [System.Windows.Forms.MessageBox]::Show('Select a task first.', 'No selection', 'OK', 'Information') | Out-Null
        return
    }
    $a = $sel.Parsed
    # Snapshot the task being edited, stored on the FORM's Tag (not a $script:
    # variable) so both the Edit and Create closures read the same live value -
    # .GetNewClosure() captures private copies of script variables, which is why
    # earlier flag/script-scope approaches failed.
    $loadedAuth = if ($a.ContainsKey('UseSshKey')) { 'ssh' }
                  elseif ($a.ContainsKey('UseClearTextConfig') -or $a.ContainsKey('ConfigPath')) { 'clear' }
                  else { 'encrypted' }
    $form.Tag = @{ TaskName = [string]$sel.Task.TaskName; Auth = $loadedAuth }

    # Direction
    if ($a.ContainsKey('ArchiveFolderName') -or ($a['Direction'] -eq 'Upload')) {
        $rbUpload.Checked = $true
    } else {
        $rbDownload.Checked = $true
    }

    # Task identity + connection
    $txtTaskName.Text = [string]$sel.Task.TaskName
    $txtHost.Text     = [string]$a['HostName']
    $txtPort.Text     = if ($a.ContainsKey('PortNumber')) { [string]$a['PortNumber'] } else { '22' }
    $txtRemote.Text   = [string]$a['RemotePath']
    $txtLocal.Text    = [string]$a['LocalPath']
    $txtMask.Text     = [string]$a['FileMask']
    if ($a.ContainsKey('ArchiveFolderName')) { $txtArchive.Text = [string]$a['ArchiveFolderName'] }

    # Auth mode
    if ($a.ContainsKey('UseSshKey')) {
        $rbSshKey.Checked = $true
        $txtKey.Text  = [string]$a['SshPrivateKeyPath']
        $txtUser.Text = [string]$a['UserName']
    }
    elseif ($a.ContainsKey('UseClearTextConfig') -or $a.ContainsKey('ConfigPath')) {
        $rbClear.Checked = $true
    }
    else {
        $rbEncrypted.Checked = $true
    }

    # Fingerprint + assembly
    $txtFp.Text = [string]$a['SshHostKeyFingerprint']
    if ($a.ContainsKey('AssemblyPath')) { $txtAssembly.Text = [string]$a['AssemblyPath'] }

    # Schedule - read back from the task's trigger (args don't carry it).
    $trg = ($sel.Task.Triggers | Select-Object -First 1)
    if ($trg -and $trg.Repetition -and $trg.Repetition.Interval) {
        # ISO8601 duration like PT15M; pull the minutes if present.
        if ($trg.Repetition.Interval -match 'PT(\d+)M') {
            $rbInterval.Checked = $true
            $txtInterval.Text = $Matches[1]
        }
    }
    elseif ($trg -and $trg.StartBoundary) {
        $rbDaily.Checked = $true
        try { $txtDaily.Text = ([datetime]$trg.StartBoundary).ToString('HH:mm') } catch { }
    }

    # Run-as
    $runAsUser = ($sel.Task.Principal).UserId
    if ($runAsUser -match 'SYSTEM') { $rbRunSystem.Checked = $true } else { $rbRunUser.Checked = $true }

    # Alerting
    $txtSmtp.Text     = [string]$a['SmtpServer']
    if ($a.ContainsKey('SmtpPort')) { $txtSmtpPort.Text = [string]$a['SmtpPort'] }
    $txtEmail.Text    = [string]$a['EmailTo']
    $txtEmailFrom.Text = [string]$a['EmailFrom']

    & $updateVisibility
    $tabs.SelectedTab = $tabCreate

    [System.Windows.Forms.MessageBox]::Show(
        "Loaded '$($sel.Task.TaskName)' into the Create tab.`n`nChange what you need and click Create Task - the same task name overwrites the existing one. The stored password is reused; you'll only be re-prompted if you change the authentication mode.",
        'Editing', 'OK', 'Information') | Out-Null
}.GetNewClosure())

$rbEncrypted.Add_CheckedChanged($updateVisibility)
$rbClear.Add_CheckedChanged($updateVisibility)
$rbSshKey.Add_CheckedChanged($updateVisibility)
$rbDownload.Add_CheckedChanged($updateVisibility)
$rbUpload.Add_CheckedChanged($updateVisibility)
& $updateVisibility

# Reuse of the stored credential is decided at save time by comparing the
# current auth mode and task name against the snapshot on $form.Tag (see the
# Create handler), so no per-radio event handling is needed here.

# -------------------------------------------------------------------------
# Create Task click: validate, build args, invoke the installer
# -------------------------------------------------------------------------

$btnCreate.Add_Click({
    # --- Basic validation ---
    $missing = @()
    if (-not $txtHost.Text.Trim())   { $missing += 'Host name' }
    if (-not $txtRemote.Text.Trim()) { $missing += 'Remote path' }
    if (-not $txtLocal.Text.Trim())  { $missing += 'Local path' }
    if ($rbSshKey.Checked) {
        if (-not $txtUser.Text.Trim()) { $missing += 'Username (for SSH key)' }
        if (-not $txtKey.Text.Trim())  { $missing += 'Private key path' }
    }
    if ($rbInterval.Checked -and -not ($txtInterval.Text -as [int])) {
        $missing += 'Interval minutes (numeric)'
    }
    if ($txtEmail.Text.Trim() -and -not $txtSmtp.Text.Trim()) {
        $missing += 'SMTP relay (required when an alert address is set)'
    }
    # SYSTEM cannot decrypt a DPAPI credential created by the current user;
    # block the incompatible combination at the GUI rather than failing at runtime.
    if ($rbRunSystem.Checked -and $rbEncrypted.Checked) {
        [System.Windows.Forms.MessageBox]::Show(
            "SYSTEM cannot read an encrypted password file created by your account (DPAPI is per-user).`n`nChoose 'Clear-text JSON config' or 'SSH private key' authentication when running as SYSTEM.",
            'Incompatible combination', 'OK', 'Warning') | Out-Null
        return
    }
    if ($missing.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please provide:`n - $($missing -join "`n - ")",
            'Missing values', 'OK', 'Warning') | Out-Null
        return
    }

    # --- Build the installer parameter set ---
    $p = [ordered]@{
        Direction  = if ($rbUpload.Checked) { 'Upload' } else { 'Download' }
        HostName   = $txtHost.Text.Trim()
        RemotePath = $txtRemote.Text.Trim()
        LocalPath  = $txtLocal.Text.Trim()
        PortNumber = [int]($txtPort.Text.Trim())
    }
    if ($txtMask.Text.Trim()) { $p.FileMask = $txtMask.Text.Trim() }
    if ($rbUpload.Checked -and $txtArchive.Text.Trim()) { $p.ArchiveFolderName = $txtArchive.Text.Trim() }
    if ($txtFp.Text.Trim()) { $p.SshHostKeyFingerprint = $txtFp.Text.Trim() }
    if ($txtTaskName.Text.Trim()) { $p.TaskName = $txtTaskName.Text.Trim() }

    # Auth mode
    if ($rbSshKey.Checked) {
        $p.UseSshKey = $true
        $p.SshPrivateKeyPath = $txtKey.Text.Trim()
        $p.UserName = $txtUser.Text.Trim()
    }
    elseif ($rbClear.Checked) {
        $p.UseClearTextConfig = $true
    }
    # else: encrypted is the installer default, no switch needed.

    # Run-as
    if ($rbRunSystem.Checked) {
        $p.RunAsSystem = $true
    }

    # Schedule
    if ($rbInterval.Checked) {
        $p.RepeatMinutes = [int]($txtInterval.Text.Trim())
    }
    else {
        $p.DailyAt = $txtDaily.Text.Trim()
    }

    # Alerting
    if ($txtSmtp.Text.Trim())  { $p.SmtpServer = $txtSmtp.Text.Trim() }
    if ($txtSmtp.Text.Trim() -and ($txtSmtpPort.Text.Trim() -as [int])) {
        $p.SmtpPort = [int]($txtSmtpPort.Text.Trim())
    }
    if ($txtEmail.Text.Trim())     { $p.EmailTo = $txtEmail.Text.Trim() }
    if ($txtEmailFrom.Text.Trim()) { $p.EmailFrom = $txtEmailFrom.Text.Trim() }

    # Custom WinSCP assembly location (optional)
    if ($txtAssembly.Text.Trim()) { $p.AssemblyPath = $txtAssembly.Text.Trim() }

    if ($chkTest.Checked) { $p.Test = $true }

    # Reuse the stored credential only if this is an edit of the SAME task with
    # the SAME auth mode. The snapshot lives on $form.Tag (see Edit handler),
    # which avoids the closure-capture issue that a $script: variable would hit.
    $snap = $form.Tag
    if ($snap -is [hashtable]) {
        $currentAuth = if ($rbSshKey.Checked) { 'ssh' }
                       elseif ($rbClear.Checked) { 'clear' }
                       else { 'encrypted' }
        $sameTask = ($p.TaskName -eq $snap.TaskName)
        $sameAuth = ($currentAuth -eq $snap.Auth)
        if ($sameTask -and $sameAuth -and $currentAuth -ne 'ssh') {
            # SSH key mode has no stored password to reuse; only clear/encrypted do.
            $p.ReuseCredential = $true
        }
    }

    # --- Turn the hashtable into a command line for a new elevated window ---
    # Build the installer's own argument list.
    $installerArgs = ''
    foreach ($key in $p.Keys) {
        $val = $p[$key]
        if ($val -is [switch] -or $val -is [bool]) {
            if ($val) { $installerArgs += " -$key" }
        }
        elseif ($val -is [int]) {
            $installerArgs += " -$key $val"
        }
        else {
            $installerArgs += " -$key `"$val`""
        }
    }

    # Write a small launcher script that:
    #   1. Starts a transcript so all output is captured to a log file.
    #   2. Runs the installer.
    #   3. Closes the window when done; review the transcript log for any error.
    $logDir = Join-Path -Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) -ChildPath 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $guiLog = Join-Path -Path $logDir -ChildPath ('GuiInstall_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))

    $launcher = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('SftpGuiLaunch_{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
    $launcherContent = @"
Start-Transcript -Path "$guiLog" -Force | Out-Null
try {
    & "$InstallerPath"$installerArgs
}
catch {
    Write-Host ''
    Write-Host "INSTALLER ERROR: `$(`$_.Exception.Message)" -ForegroundColor Red
    Write-Host `$_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    Stop-Transcript | Out-Null
    Remove-Item -LiteralPath "$launcher" -Force -ErrorAction SilentlyContinue
}
"@
    Set-Content -LiteralPath $launcher -Value $launcherContent -Encoding UTF8

    $argLine = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $launcher)

    $promptNote = if ($rbRunSystem.Checked) {
        "You'll be prompted there for the SFTP credential. (No Windows password is needed when running as SYSTEM.)"
    } else {
        "You'll be prompted there for the SFTP credential and the Windows password for the task account."
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "A new elevated PowerShell window will open to run the installer.`n`n$promptNote`n`nThe window stays open when done, and output is logged to:`n$guiLog`n`nProceed?",
        'Confirm', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') {
        Remove-Item -LiteralPath $launcher -Force -ErrorAction SilentlyContinue
        return
    }

    try {
        # -Verb RunAs triggers the UAC elevation prompt.
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs
        [System.Windows.Forms.MessageBox]::Show(
            "The installer is running in a separate window and will close when finished.`n`nThe full output is saved to:`n$guiLog`n`nIf the task doesn't appear, check that log for errors.",
            'Launched', 'OK', 'Information') | Out-Null
        $form.Close()
    }
    catch {
        Remove-Item -LiteralPath $launcher -Force -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            "Could not launch the installer:`n$($_.Exception.Message)",
            'Error', 'OK', 'Error') | Out-Null
    }
})

# Pre-passphrase note: passphrase-protected keys are not handled by the GUI;
# use the command line for those (rare for unattended jobs).

# Populate the Manage tab whenever it becomes the active tab.
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $tabManage) { & $loadTasks }
}.GetNewClosure())

# Initial population so the list is ready if the user opens Manage first.
& $loadTasks

[void]$form.ShowDialog()
