# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0 (the "License").
# You may obtain a copy of the License at https://www.apache.org/licenses/LICENSE-2.0
# Distributed on an "AS IS" basis, without warranties or conditions.
# PowerShell 5.1 acceptance harness for a user-approved screen-capture session.
param([string]$Serial = 'LMX430CUAEPZJJEEUC')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui_lab.ps1')
$project = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$client = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$run = Join-Path $PSScriptRoot ('evidence/run-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$stdout = Join-Path $run 'stdout.txt'
$androidLog = Join-Path $run 'device-logcat.txt'
$qtLog = Join-Path $run 'client-stderr.txt'
$qtLogSource = Join-Path $client 'out/deploy/startup.stderr.log'
$script:auditStart = [DateTime]::UtcNow
$script:logStartLocal = Get-Date
$script:relayRun = 0
$script:phase = 'P0'
$script:exitCode = 1
function Emit([string]$value) {
    $line = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + ' ' + $value
    [IO.File]::AppendAllText($stdout, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    Write-Host $line
}
function Begin-Phase([string]$name) {
    $script:phase = $name
    Emit ($name + '_BEGIN')
}
function End-Phase([string]$text) {
    Emit ($script:phase + '_OK ' + $text)
}
function Wait-For([scriptblock]$predicate, [int]$seconds, [string]$reason) {
    $until = [DateTime]::UtcNow.AddSeconds($seconds)
    while ([DateTime]::UtcNow -lt $until) {
        if (& $predicate) { return }
        Start-Sleep -Milliseconds 200
    }
    throw $reason
}
function Device-Log() {
    if (Test-Path $androidLog) {
        return @(Get-Content $androidLog -ErrorAction SilentlyContinue | Where-Object {
            if ($_ -match '^\s*(\d\d)-(\d\d)\s+(\d\d:\d\d:\d\d\.\d{3})') {
                $stamp = '2026-' + $Matches[1] + '-' + $Matches[2] + ' ' + $Matches[3]
                $when = [datetime]::ParseExact($stamp,'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)
                return $when -ge $script:logStartLocal.AddSeconds(-5)
            }
            return $false
        })
    }
    return @()
}
function Device-Count([string]$pattern) {
    return @((Device-Log) | Where-Object { $_ -match $pattern }).Count
}
function Qt-Log-Has([string]$pattern,[datetime]$since = [datetime]::MinValue) {
    if (-not (Test-Path $qtLogSource)) { return $false }
    $threshold = if ($since -gt $script:auditStart) { $since } else { $script:auditStart }
    return @((Get-Content $qtLogSource -ErrorAction SilentlyContinue) |
        Where-Object {
            $_ -match $pattern -and $_.Length -ge 24 -and
            [datetime]::Parse($_.Substring(0,24)).ToUniversalTime() -ge $threshold
        }).Count -gt 0
}
function Live-Video() {
    return @(Get-QscVideo $script:qt.Id)
}
function Wait-Video([int]$seconds) {
    Wait-For { -not $script:qt.HasExited -and (Live-Video).Count -eq 1 } $seconds 'VIDEO_NOT_CONNECTED'
}
function Wait-Closed([int]$seconds) {
    Wait-For { (Live-Video).Count -eq 0 } $seconds 'VIDEO_NOT_CLOSED'
}
function Open-Again() {
    $start = [DateTime]::UtcNow
    Close-QscVideo $script:qt.Id
    Wait-Closed 3
    Wait-For { Qt-Log-Has 'Remote stream disconnected for relay/phone-01' $start } 3 'CLIENT_CLEAN_DISCONNECT_NOT_LOGGED'
    Invoke-QscConnect $script:qt.Id
    $gap = ([DateTime]::UtcNow - $start).TotalSeconds
    Emit ('REPAIR_GAP_SECONDS={0:F3}' -f $gap)
    if ($gap -gt 8) { throw 'REPAIR_GAP_OVER_8_SECONDS' }
    Wait-Video 12
}
function Start-Relay() {
    $script:relayRun++
    $dir = Join-Path $project 'relay'
    $binary = Join-Path $dir 'qtscrcpy-relay.exe'
    $script:relay = Start-Process -FilePath $binary -WorkingDirectory $dir -PassThru -WindowStyle Hidden -ArgumentList @(
        '--ctl', '8443', '--data', '9000', '--tokens', 'tokens.json'
    ) -RedirectStandardError (Join-Path $run ('relay-' + $script:relayRun + '-stderr.txt')) -RedirectStandardOutput (Join-Path $run ('relay-' + $script:relayRun + '-stdout.txt'))
    Wait-For {
        @((Get-NetTCPConnection -LocalPort 8443,9000 -State Listen -ErrorAction SilentlyContinue |
            Where-Object OwningProcess -eq $script:relay.Id)).Count -eq 2
    } 8 'RELAY_PORTS_NOT_LISTENING'
    Emit ('RELAY_STARTED pid=' + $script:relay.Id)
}
function Stop-Relay() {
    if ($null -ne $script:relay -and -not $script:relay.HasExited) {
        Stop-Process -Id $script:relay.Id -Force -ErrorAction Stop
        $script:relay.WaitForExit(4000) | Out-Null
    }
}
function Clear-StaleRelay() {
    $ids = @(Get-NetTCPConnection -LocalPort 8443,9000 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($id in $ids) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
        $expected = Join-Path $project 'relay/qtscrcpy-relay.exe'
        if ($null -eq $p -or $p.Name -ne 'qtscrcpy-relay.exe' -or $p.ExecutablePath -ne $expected) {
            throw 'RELAY_PORTS_OWNED_BY_OTHER_PROCESS'
        }
        Stop-Process -Id $id -Force
        Emit ('STALE_RELAY_SESSION_ENDED pid=' + $id)
    }
}
function Request-ApprovedSession() {
    $prior = Device-Count 'agent_registered device_id=phone-01'
    $failed = Device-Count 'session_failed:'
    & adb -s $Serial shell am start -n br.net.qtscrcpy.agent/.MainActivity | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ANDROID_ACTIVITY_NOT_AVAILABLE' }
    # The owner fills host=localhost and token, chooses Start, then approves
    # the official Android MediaProjection dialog on the physical device.
    Emit 'OWNER_TAP_REQUIRED: conferir o token do device phone-01, iniciar espelhamento e aprovar a caixa oficial de captura no aparelho'
    try {
        Wait-For {
            if ((Device-Count 'session_failed:') -gt $failed) {
                if (@((Device-Log) | Where-Object { $_ -match 'Registro rejeitado pelo relay \(HTTP 401\)' }).Count -gt 0) {
                    throw 'AGENT_AUTH_FAILED_HTTP_401'
                }
                throw 'AGENT_SESSION_FAILED_CHECK_LOGCAT'
            }
            (Device-Count 'agent_registered device_id=phone-01') -gt $prior
        } 120 'OWNER_TAP_REQUIRED'
    } catch {
        if ($_.Exception.Message -match 'OWNER_TAP_REQUIRED') { $script:exitCode = 4 }
        throw
    }
    Emit ('AGENT_REGISTERED count=' + (Device-Count 'agent_registered device_id=phone-01'))
}
function Start-SwipeLoop() {
    $script:swipes = Start-Job -ScriptBlock {
        param($device)
        while ($true) {
            & adb -s $device shell input swipe 360 1200 360 600 300 *> $null
            Start-Sleep -Milliseconds 100
        }
    } -ArgumentList $Serial
}
function Stop-SwipeLoop() {
    if ($null -ne $script:swipes) {
        Stop-Job $script:swipes -ErrorAction SilentlyContinue
        Remove-Job $script:swipes -Force -ErrorAction SilentlyContinue
        $script:swipes = $null
    }
}
function Fps-ForPeriod([datetime]$first, [datetime]$last) {
    $points = @()
    foreach ($line in (Device-Log)) {
        if ($line -match '^\s*(\d\d)-(\d\d)\s+(\d\d:\d\d:\d\d\.\d{3}).*?(?:stream_frames=(\d+)|capture_stopped frames=(\d+))') {
            $stamp = '2026-' + $Matches[1] + '-' + $Matches[2] + ' ' + $Matches[3]
            $time = [datetime]::ParseExact($stamp,'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)
            if ($time -ge $first.AddSeconds(-1) -and $time -le $last.AddSeconds(1)) {
                $count = if ($Matches[4]) { [int]$Matches[4] } else { [int]$Matches[5] }
                $points += [pscustomobject]@{Time=$time;Count=$count}
            }
        }
    }
    if ($points.Count -lt 2) {
        Emit ('ACTIVE_NOT_CONFIRMED insufficient_fps_markers=' + $points.Count)
        return $false
    }
    $rates = @()
    $progress = $true
    for ($index=1; $index -lt $points.Count; $index++) {
        $deltaFrames = $points[$index].Count - $points[$index-1].Count
        $deltaSeconds = ($points[$index].Time - $points[$index-1].Time).TotalSeconds
        if ($deltaSeconds -le 0) { throw 'FPS_TIME_INTERVAL_INVALID' }
        $fps = $deltaFrames / $deltaSeconds
        Emit ('P2_FPS_INTERVAL index={0} dFrames={1} dt_seconds={2:F3} fps={3:F3}' -f $index,$deltaFrames,$deltaSeconds,$fps)
        $rates += $fps
        if ($deltaFrames -le 0) { $progress = $false; Emit 'ACTIVE_NOT_CONFIRMED delta_frames_zero' }
    }
    $script:fpsMean = ($rates | Measure-Object -Average).Average
    Emit ('P2_FPS_MEAN={0:F3} interval_count={1}' -f $script:fpsMean,$rates.Count)
    return ($progress -and $script:fpsMean -ge 10)
}
function Run-P2([int]$attempt) {
    $start = Get-Date
    & adb -s $Serial shell am start -a android.settings.SETTINGS | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'SCREEN_ACTIVITY_NOT_STARTED' }
    Start-SwipeLoop
    try {
        foreach ($second in @(10,33,55)) {
            $remaining = $second - ((Get-Date) - $start).TotalSeconds
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining * 1000)) }
            $file = Join-Path $run ('P2-attempt' + $attempt + '-second' + $second + '.png')
            $ratio = Save-QscFrame $script:qt.Id $file
            Emit ('P2_NONBLACK attempt={0} second={1} ratio={2:F4} title=relay/phone-01 file={3}' -f $attempt,$second,$ratio,[IO.Path]::GetFileName($file))
            if ($ratio -lt 0.5) { throw 'P2_NONBLACK_BELOW_HALF' }
        }
        $remaining = 60 - ((Get-Date) - $start).TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining * 1000)) }
    } finally { Stop-SwipeLoop }
    return (Fps-ForPeriod $start (Get-Date))
}
function Count-SessionBoundaries() {
    $registrations = Device-Count 'agent_registered device_id=phone-01'
    $initializations = Device-Count 'capture_initialized width='
    $stops = Device-Count 'service_stopped sent_frames=\d+'
    Emit "P4_COUNTS agent_registered=$registrations capture_initialized=$initializations service_stopped=$stops"
    if ($registrations -ne 2 -or $initializations -ne 2 -or $stops -ne 2) {
        throw 'P4_COUNTS_NOT_EXACTLY_TWO'
    }
    $lines = @(Device-Log)
    $firstInit=-1; $secondInit=-1; $firstStop=-1
    for ($index=0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match 'capture_initialized') {
            if ($firstInit -lt 0) { $firstInit=$index } else { $secondInit=$index }
        }
        if ($firstStop -lt 0 -and $lines[$index] -match 'service_stopped') { $firstStop=$index }
    }
    if ($firstInit -lt 0 -or $firstStop -le $firstInit -or $secondInit -le $firstStop) {
        throw 'P4_ENCODER_RECREATED_WITHIN_SESSION'
    }
}
try {
    $deploy = Join-Path $client 'out/deploy'
    $binary = Join-Path $deploy 'QtScrcpy.exe'
    $tokenMap = Join-Path $project 'relay/tokens.json'
    if (-not (Test-Path $binary) -or -not (Test-Path $tokenMap)) { throw 'LAB_ARTIFACT_MISSING' }
    $script:token = ([IO.File]::ReadAllText($tokenMap) | ConvertFrom-Json).'phone-01'
    if ($script:token -notmatch '^[A-Za-z0-9_-]+$') { throw 'TOKEN_FORMAT_REQUIRES_OWNER_INPUT' }
    if (@(Get-Process QtScrcpy -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'PREEXISTING_QT_INSTANCE_CLOSE_BEFORE_TEST'
    }
    if ((& adb -s $Serial get-state) -ne 'device') { throw 'ADB_NOT_READY' }
    Begin-Phase 'P0'
    Clear-StaleRelay
    Start-Relay
    & adb -s $Serial reverse tcp:8443 tcp:8443 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ADB_REVERSE_CONTROL_FAILED' }
    & adb -s $Serial reverse tcp:9000 tcp:9000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ADB_REVERSE_DATA_FAILED' }
    $script:logcat = Start-Process -FilePath (Get-Command adb).Source -ArgumentList @(
        '-s',$Serial,'logcat','-T','1','-v','threadtime','-s','QscnetAgent:I'
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $androidLog
    Start-Sleep -Seconds 2
    Request-ApprovedSession
    End-Phase 'relay started and agent registered'

    Begin-Phase 'P1'
    $script:qt = Start-Process -FilePath $binary -WorkingDirectory $deploy -PassThru -RedirectStandardError $qtLog
    Wait-For { @(Get-QscMain $script:qt.Id).Count -eq 1 } 12 'QT_MAIN_WINDOW_MISSING'
    Set-QscToken $script:qt.Id $script:token
    Invoke-QscConnect $script:qt.Id
    Start-Sleep -Milliseconds 700
    Invoke-QscConnect $script:qt.Id
    Wait-Video 20
    if ((Live-Video).Count -ne 1) { throw 'P1_MORE_THAN_ONE_VIDEO_WINDOW' }
    Wait-For { Qt-Log-Has 'Remote device relay/phone-01 is already connected' } 10 'P1_OUTLOG_ALREADY_CONNECTED_NOT_VERIFIED'
    Emit 'P1_OUTLOG_SOURCE=client-stderr.txt video_windows=1'
    End-Phase 'duplicate connect identified distinctly; one video window'

    Begin-Phase 'P2'
    Open-Again
    $passed = Run-P2 1
    if (-not $passed) {
        Emit 'ACTIVE_NOT_CONFIRMED repeating_P2_once'
        $passed = Run-P2 2
    }
    if (-not $passed) { throw 'P2_FPS_GATE_FAILED' }
    End-Phase ('60s active video and three nonblack samples; mean_fps={0:F3}' -f $script:fpsMean)

    Begin-Phase 'P3'
    Open-Again
    Start-Sleep -Seconds 5
    if ((Live-Video).Count -ne 1) { throw 'P3_VIDEO_DID_NOT_LAST_FIVE_SECONDS' }
    $killed = [DateTime]::UtcNow
    Stop-Relay
    Emit ('P3_RELAY_KILLED_AT=' + $killed.ToString('yyyy-MM-ddTHH:mm:ss.fff'))
    Wait-For {
        (Live-Video).Count -eq 0 -or
        (Qt-Log-Has 'Remote stream disconnected for relay/phone-01' $killed)
    } 10 'P3_CLIENT_NO_REACTION_WITHIN_10S'
    $seconds = ([DateTime]::UtcNow - $killed).TotalSeconds
    if ($seconds -gt 10 -or $script:qt.HasExited) { throw 'P3_CLIENT_REACTION_INVALID' }
    Emit ('P3_CLIENT_REACTION_SECONDS={0:F3}' -f $seconds)
    Wait-For { (Device-Count 'service_stopped sent_frames=\d+') -ge 1 } 45 'P3_AGENT_DID_NOT_STOP'
    Wait-Closed 10
    Start-Relay
    Request-ApprovedSession
    Invoke-QscConnect $script:qt.Id
    Wait-Video 20
    Start-Sleep -Seconds 10
    if ((Live-Video).Count -ne 1) { throw 'P3_RECOVERY_VIDEO_UNDER_10S' }
    $sample = Save-QscFrame $script:qt.Id (Join-Path $run 'P3-recovery.png')
    Emit ('P3_RECOVERED_VIDEO_NONBLACK={0:F4}' -f $sample)
    Close-QscVideo $script:qt.Id
    Wait-Closed 5
    End-Phase ('client reacted in {0:F3}s; new agent session video ten seconds' -f $seconds)

    Begin-Phase 'P4'
    Start-Sleep -Seconds 12
    Count-SessionBoundaries
    End-Phase 'two registrations, encoder starts and clean stops'
    $script:exitCode = 0
} catch {
    $reason = $_.Exception.Message -replace '[\r\n]+',' '
    if ($reason -match 'OWNER_TAP_REQUIRED') { $script:exitCode=4 }
    Emit ($script:phase + '_FAIL ' + $reason)
} finally {
    Stop-SwipeLoop
    if ($null -ne $script:logcat -and -not $script:logcat.HasExited) {
        Stop-Process -Id $script:logcat.Id -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:qt -and -not $script:qt.HasExited) {
        foreach ($w in (Get-QscWindows $script:qt.Id)) {
            [void][QscUiLab]::PostMessage($w.Handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
        }
    }
    if (Test-Path $qtLogSource) {
        @(Get-Content $qtLogSource | Where-Object {
            $_.Length -ge 24 -and
            [datetime]::Parse($_.Substring(0,24)).ToUniversalTime() -ge $script:auditStart
        }) | Set-Content -Encoding UTF8 -LiteralPath $qtLog
    }
    Stop-Relay
    Emit ('TASK006_HARNESS_EXIT=' + $script:exitCode)
}
exit $script:exitCode
