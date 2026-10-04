#requires -Version 5.1
<#
  Install-Apps.ps1
  SYSTEM context worker. Reads apps.json, downloads and silently installs
  each app in order, publishing progress to status.json (atomic rewrite).
  Shows no UI. Triggered AtLogOn by the AppProvision-Install scheduled task.

  apps.json entry:
    name, url, fallbackUrl(optional), fileName, installer(msi|exe),
    silentArgs, detectionPath(optional)
#>
$ErrorActionPreference = 'Stop'

$Root       = 'C:\ProgramData\AppProvisioning'
$PayloadDir = Join-Path $Root 'payload'
$WorkDir    = Join-Path $Root 'downloads'
$LogDir     = Join-Path $Root 'logs'
$StatusFile = Join-Path $Root 'status.json'
$DoneFlag   = Join-Path $Root 'done.flag'

$TaskInstall = 'AppProvision-Install'
$TaskGui     = 'AppProvision-Progress'

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

New-Item -ItemType Directory -Force -Path $WorkDir, $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'installer.log') -Append

# Prevent duplicate runs (logon task can fire more than once)
$mutex = New-Object System.Threading.Mutex($false, 'Global\AppProvision-Installer')
if (-not $mutex.WaitOne(0)) {
    Write-Output 'another instance is running - skip'
    Stop-Transcript | Out-Null
    exit 0
}

$script:status = $null

function Write-Status {
    $script:status.updatedAt = (Get-Date).ToString('o')
    $tmp = "$StatusFile.tmp"
    ($script:status | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $StatusFile -Force
}

function Update-Overall {
    $total = @($script:status.apps).Count
    $done  = @($script:status.apps | Where-Object { $_.status -eq 'Installed' -or $_.status -eq 'Skipped' }).Count
    $cur   = $script:status.apps | Where-Object { $_.name -eq $script:status.currentName } | Select-Object -First 1
    $frac  = 0
    if ($cur -and ($cur.status -eq 'Downloading' -or $cur.status -eq 'Installing')) {
        $frac = [Math]::Min([int]$cur.percent, 100) / 100
    }
    $script:status.overallPercent = [int][Math]::Round((($done + $frac) / [Math]::Max($total, 1)) * 100)
}

function Set-AppState {
    param([string]$Name, [string]$State, [int]$Percent = -1, [string]$ErrText = '')
    $a = $script:status.apps | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $a) { return }
    $a.status = $State
    if ($Percent -ge 0) { $a.percent = $Percent }
    $a.error = $ErrText
    Update-Overall
    Write-Status
}

function Wait-Network([string[]]$Probes, [int]$MaxSeconds = 600) {
    # Do not depend on a single probe URL. Any one 200 is enough.
    if (-not $Probes -or $Probes.Count -eq 0) {
        $Probes = @('https://www.microsoft.com/')
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $MaxSeconds) {
        foreach ($u in $Probes) {
            try {
                $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 10 -Method Head
                if ([int]$r.StatusCode -eq 200) { Write-Output "network ok: $u"; return }
            } catch {
                Write-Output ("probe ng: {0} -> {1}" -f $u, $_.Exception.Message)
            }
        }
        Write-Output 'waiting for network...'
        $script:status.currentName = ''
        Write-Status
        Start-Sleep -Seconds 5
    }
    throw 'network not ready (timeout)'
}

function Download-AppFile([string]$Url, [string]$Dest, [string]$AppName) {
    if (Test-Path $Dest) { Remove-Item $Dest -Force }

    # 1) BITS (built into PS 5.1, with progress %, resume and retry)
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        $jobName = "AppProvision-$([Guid]::NewGuid().ToString('N'))"
        Start-BitsTransfer -Source $Url -Destination $Dest -Asynchronous -DisplayName $jobName -ErrorAction Stop | Out-Null
        $lastP = -10
        while ($true) {
            Start-Sleep -Seconds 1
            $j = Get-BitsTransfer | Where-Object { $_.DisplayName -eq $jobName } | Select-Object -First 1
            if (-not $j) { break }
            if ($j.JobState -eq 'Transferred') { Complete-BitsTransfer -BitsJob $j; break }
            if ($j.JobState -eq 'Error') {
                $err = ($j.ErrorDescription | Out-String)
                Cancel-BitsTransfer -BitsJob $j
                throw "BITS error: $err"
            }
            if ([double]$j.BytesTotal -gt 0) {
                $p = [int]([double]$j.BytesTransferred / [double]$j.BytesTotal * 100)
                if ($p -ge $lastP + 2) {
                    $lastP = $p
                    $mb = '{0:N1}/{1:N1} MB' -f ($j.BytesTransferred / 1MB), ($j.BytesTotal / 1MB)
                    Set-AppState $AppName 'Downloading' ([Math]::Min($p, 99)) ("GET $Url ($mb)")
                }
            }
        }
        if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 100KB) {
            Set-AppState $AppName 'Downloading' 100
            return
        }
        throw 'BITS completed but file missing/too small'
    } catch {
        Write-Output ("BITS failed, fallback to Invoke-WebRequest: " + $_)
    }

    # 2) Fallback: Invoke-WebRequest (no extra assemblies needed)
    for ($i = 1; $i -le 3; $i++) {
        try {
            Set-AppState $AppName 'Downloading' 5
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 600
            if ((Get-Item $Dest).Length -lt 100KB) { throw 'downloaded file too small' }
            Set-AppState $AppName 'Downloading' 100
            return
        } catch {
            Write-Output ("download attempt $i failed: " + $_)
            if ($i -eq 3) { throw "download failed: $Url" }
            Start-Sleep -Seconds (5 * $i)
        }
    }
}

function Install-AppFile($App, [string]$FilePath) {
    $okCodes = @(0, 3010, 1641)
    if ($App.installExitCodes) { $okCodes = @($App.installExitCodes) }
    if ($App.installer -eq 'msi' -or $FilePath -match '\.msi$') {
        $logArg = "/L*v `"$LogDir\$($App.fileName).log`""
        $proc = Start-Process msiexec.exe -ArgumentList "/i `"$FilePath`" $($App.silentArgs) $logArg" -Wait -PassThru
    } else {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $App.silentArgs -WorkingDirectory $WorkDir -Wait -PassThru
    }
    if ($proc.ExitCode -eq 1618) {
        # Another MSI installation in progress. Wait once and retry.
        Write-Output 'msiexec busy (1618), waiting 60s and retrying once'
        Start-Sleep -Seconds 60
        return (Install-AppFile -App $App -FilePath $FilePath)
    }
    if ($okCodes -notcontains $proc.ExitCode) { throw "install exit code $($proc.ExitCode)" }
}

try {
    $configPath = Join-Path $PayloadDir 'apps.json'
    if (-not (Test-Path $configPath)) { $configPath = Join-Path $Root 'apps.json' }
    $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $apps = @($config.apps)
    if ($apps.Count -eq 0) { throw 'apps.json contains no apps' }

    # Resume: keep previous Installed/Skipped states on re-run
    $prev = @{}
    if (Test-Path $StatusFile) {
        try {
            $old = Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($o in @($old.apps)) { $prev[[string]$o.name] = [string]$o.status }
        } catch { Out-Null }
    }
    $appStates = @($apps | ForEach-Object {
        $s = 'Pending'
        if ($prev[[string]$_.name] -eq 'Installed' -or $prev[[string]$_.name] -eq 'Skipped') { $s = $prev[[string]$_.name] }
        @{ name = [string]$_.name; status = $s; percent = 0; error = '' }
    })
    $script:status = [ordered]@{
        state          = 'Running'
        startedAt      = (Get-Date).ToString('o')
        updatedAt      = ''
        currentName    = ''
        currentIndex   = 0
        total          = $appStates.Count
        overallPercent = 0
        apps           = $appStates
    }
    Update-Overall
    Write-Status

    $maxSec = 600
    if ($config.internetWaitSeconds) { $maxSec = [int]$config.internetWaitSeconds }
    $probes = @($apps | ForEach-Object { $_.url } | Select-Object -First 3)
    $probes += 'https://www.microsoft.com/'
    Wait-Network -Probes $probes -MaxSeconds $maxSec

    for ($i = 0; $i -lt $apps.Count; $i++) {
        $app = $apps[$i]
        $script:status.currentName = [string]$app.name
        $script:status.currentIndex = $i + 1
        Update-Overall
        Write-Status

        $cur = $script:status.apps | Where-Object { $_.name -eq $app.name } | Select-Object -First 1
        if ($cur.status -eq 'Installed' -or $cur.status -eq 'Skipped') { continue }
        if ($app.detectionPath -and (Test-Path $app.detectionPath)) {
            Set-AppState $app.name 'Skipped' 100 'already installed'
            continue
        }

        try {
            Set-AppState $app.name 'Downloading' 0
            $file = Join-Path $WorkDir $app.fileName
            $urls = @($app.url)
            if ($app.fallbackUrl -and $app.fallbackUrl.Trim()) { $urls += $app.fallbackUrl }
            $dlOk = $false
            $dlErr = ''
            foreach ($u in $urls) {
                try {
                    Write-Output "download [$($app.name)]: $u"
                    Download-AppFile -Url $u -Dest $file -AppName $app.name
                    $dlOk = $true
                    break
                } catch {
                    $dlErr = [string]$_
                    Write-Output "download failed: $dlErr"
                    Set-AppState $app.name 'Downloading' 5 $dlErr
                    Start-Sleep -Seconds 5
                }
            }
            if (-not $dlOk) { throw $dlErr }

            Set-AppState $app.name 'Installing' 0
            Install-AppFile -App $app -FilePath $file
            if ($app.detectionPath -and -not (Test-Path $app.detectionPath)) {
                throw 'install finished but detection path not found'
            }
            Set-AppState $app.name 'Installed' 100
        } catch {
            Write-Output ("FAILED [$($app.name)]: " + $_)
            Set-AppState $app.name 'Failed' 0 ([string]$_)
        }
    }

    $failed = @($script:status.apps | Where-Object { $_.status -eq 'Failed' -or $_.status -eq 'Pending' -or $_.status -eq 'Downloading' -or $_.status -eq 'Installing' })
    $script:status.state = if ($failed.Count -eq 0) { 'Complete' } else { 'Error' }
    $script:status.currentName = ''
    Update-Overall
    if ($failed.Count -eq 0) { $script:status.overallPercent = 100 }
    Write-Status

    # Remove both tasks only when everything succeeded (stay for retry otherwise)
    if ($failed.Count -eq 0) {
        New-Item -ItemType File -Path $DoneFlag -Force | Out-Null
        foreach ($t in @($TaskInstall, $TaskGui)) {
            try {
                if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
                    Unregister-ScheduledTask -TaskName $t -Confirm:$false
                }
            } catch { Out-Null }
        }
    }
}
catch {
    Write-Output ("fatal: " + $_)
    try {
        if ($script:status) { $script:status.state = 'Error'; Write-Status }
    } catch { Out-Null }
}
finally {
    try { $mutex.ReleaseMutex() } catch { Out-Null }
    $mutex.Dispose()
    try { Stop-Transcript | Out-Null } catch { Out-Null }
}
