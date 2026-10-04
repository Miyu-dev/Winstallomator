#requires -Version 5.1
<#
  Deploy-Provisioning.ps1
  Staging script. Run once as admin (or as SYSTEM via Intune/ESP).
  - Copies Install-Apps.ps1 / Show-Progress.ps1 / apps.json from this folder
    to C:\ProgramData\AppProvisioning
  - Registers two AtLogOn scheduled tasks:
      AppProvision-Install  : runs Install-Apps.ps1 as SYSTEM (no UI)
      AppProvision-Progress : runs Show-Progress.ps1 as the signed-in user (UI only)

  Local test (admin PowerShell):
    .\Deploy-Provisioning.ps1
    # sign out/in, or for immediate test:
    #   Start-ScheduledTask -TaskName 'AppProvision-Install'
    #   Start-ScheduledTask -TaskName 'AppProvision-Progress'
    .\Deploy-Provisioning.ps1 -Cleanup

  To add apps, edit apps.json. No script change needed.
#>
param(
    [switch]$Cleanup,
    [switch]$NoDelay
)

$ErrorActionPreference = 'Stop'

$Root        = 'C:\ProgramData\AppProvisioning'
$PayloadDir  = Join-Path $Root 'payload'
$LogDir      = Join-Path $Root 'logs'
$StatusFile  = Join-Path $Root 'status.json'
$TaskInstall = 'AppProvision-Install'
$TaskGui     = 'AppProvision-Progress'

function Remove-Provisioning {
    foreach ($t in @($TaskInstall, $TaskGui)) {
        try {
            if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $t -Confirm:$false
                Write-Output "removed task: $t"
            }
        } catch { Write-Output "remove task failed $t : $_" }
    }
    if (Test-Path $Root) {
        Remove-Item $Root -Recurse -Force
        Write-Output "removed: $Root"
    }
}

if ($Cleanup) { Remove-Provisioning; exit 0 }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run as administrator (unnecessary when deployed as SYSTEM via Intune)' }

New-Item -ItemType Directory -Force -Path $Root, $PayloadDir, $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'setup.log') -Append
try {
    $localDir = Split-Path -Parent $PSCommandPath
    foreach ($name in @('Install-Apps.ps1', 'Show-Progress.ps1', 'apps.json')) {
        $src = Join-Path $localDir $name
        if (-not (Test-Path $src)) { throw "payload not found: $src" }
        Copy-Item $src (Join-Path $PayloadDir $name) -Force
        Copy-Item $src (Join-Path $Root $name) -Force
        Write-Output "staged: $name"
    }

    # Users may only read. If they could rewrite files executed as SYSTEM,
    # that would be a privilege-escalation path.
    & icacls $Root /inheritance:r /grant 'SYSTEM:(OI)(CI)F' /grant 'BUILTIN\Administrators:(OI)(CI)F' /grant 'BUILTIN\Users:(OI)(CI)RX' | Out-Null

    # Initial status so the GUI can show "waiting" immediately
    $cfg = Get-Content (Join-Path $PayloadDir 'apps.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $init = [ordered]@{
        state          = 'Running'
        startedAt      = (Get-Date).ToString('o')
        updatedAt      = (Get-Date).ToString('o')
        currentName    = ''
        currentIndex   = 0
        total          = @($cfg.apps).Count
        overallPercent = 0
        apps           = @($cfg.apps | ForEach-Object {
            @{ name = [string]$_.name; status = 'Pending'; percent = 0; error = '' }
        })
    }
    ($init | ConvertTo-Json -Depth 8) | Set-Content -Path $StatusFile -Encoding UTF8
    & icacls $StatusFile /grant 'BUILTIN\Users:R' | Out-Null

    foreach ($t in @($TaskInstall, $TaskGui)) {
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false
        }
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $delayInstall = if ($NoDelay) { 'PT15S' } else { 'PT1M' }
    $delayGui = if ($NoDelay) { 'PT5S' } else { 'PT30S' }

    # 1) Installer as SYSTEM
    $tri1 = New-ScheduledTaskTrigger -AtLogOn
    $tri1.Delay = $delayInstall
    $pri1 = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $act1 = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadDir\Install-Apps.ps1`""
    $set1 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    Register-ScheduledTask -TaskName $TaskInstall -Action $act1 -Trigger $tri1 -Principal $pri1 -Settings $set1 -Force | Out-Null
    Write-Output "registered: $TaskInstall (delay $delayInstall)"

    # 2) GUI as the signed-in user (display only)
    $tri2 = New-ScheduledTaskTrigger -AtLogOn
    $tri2.Delay = $delayGui
    try {
        # NOTE: -GroupId と -LogonType は同時指定不可。Group指定時は LogonType を付けない。
        $pri2 = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited
    } catch {
        $pri2 = New-ScheduledTaskPrincipal -GroupId 'S-1-5-4' -RunLevel Limited
    }
    $act2 = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PayloadDir\Show-Progress.ps1`""
    $set2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    Register-ScheduledTask -TaskName $TaskGui -Action $act2 -Trigger $tri2 -Principal $pri2 -Settings $set2 -Force | Out-Null
    Write-Output "registered: $TaskGui (delay $delayGui)"

    Write-Output 'setup complete. sign-out/in to test.'
}
finally {
    try { Stop-Transcript | Out-Null } catch { Out-Null }
}
