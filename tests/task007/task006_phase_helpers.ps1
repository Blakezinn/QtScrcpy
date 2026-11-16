# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# TASK-006 session helpers reused; UI dump bounded to avoid a stalled device.
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
        $lines = @(Get-Content $androidLog -ErrorAction SilentlyContinue | Where-Object {
            if ($_ -match '^\s*(\d\d)-(\d\d)\s+(\d\d:\d\d:\d\d\.\d{3})') {
                $stamp = '2026-' + $Matches[1] + '-' + $Matches[2] + ' ' + $Matches[3]
                $when = [datetime]::ParseExact($stamp,'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)
                return $when -ge $script:logStartLocal.AddSeconds(-5)
            }
            return $false
        })
        if ($null -ne $script:firstRegisteredLine) {
            $start = -1
            for ($i=0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -eq $script:firstRegisteredLine) { $start=$i; break }
            }
            if ($start -ge 0) { return @($lines | Select-Object -Skip $start) }
        }
        return $lines
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

function Invoke-DeviceInput([string[]]$parts) {
    # Never log the arguments: a field value may be the authentication token.
    & adb -s $Serial shell input @parts 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'DEVICE_INPUT_FAILED' }
}

function Set-DeviceField([int]$x,[int]$y,[string]$value) {
    if ($value -notmatch '^[A-Za-z0-9_.-]+$') { throw 'DEVICE_FIELD_UNSUPPORTED_VALUE' }
    Invoke-DeviceInput @('tap',([string]$x),([string]$y))
    Invoke-DeviceInput @('keyevent','123')
    # The same forty DEL key events, sent by one Android input invocation.
    # Android's input keyevent accepts multiple keycodes per invocation.
    $keyEvents = @('shell','input','keyevent') + @((1..40) | ForEach-Object { '67' })
    & adb -s $Serial @keyEvents 1>$null 2>$null
    if($LASTEXITCODE -ne 0) {
        for($i=0;$i -lt 40;$i++) { Invoke-DeviceInput @('keyevent','67') }
    }
    Invoke-DeviceInput @('text',$value)
}

function Test-CaptureDialog {
    $state = (& adb -s $Serial shell dumpsys activity activities 2>$null | Out-String)
    return ($state -match 'MediaProjectionPermissionActivity')
}

function Approve-CaptureDialog {
    $foundDialog = $false
    # Prefer the official button bounds. On this LG, the accessibility dump
    # may be slow; after one failed dump the independently verified official
    # permission dialog allows the TASK-006 documented coordinate fallback.
    for ($attempt=1;$attempt -le 1;$attempt++) {
        Start-Sleep -Milliseconds 500
        if(Test-CaptureDialog) { $foundDialog = $true }
        $dump = Start-Process -FilePath (Get-Command adb).Source -PassThru -WindowStyle Hidden -ArgumentList @(
            '-s',$Serial,'shell','uiautomator','dump','/sdcard/task007-ui.xml'
        ) -RedirectStandardOutput (Join-Path $run 'uia-dump-stdout.txt') -RedirectStandardError (Join-Path $run 'uia-dump-stderr.txt')
        if (-not $dump.WaitForExit(6000)) {
            Stop-Process -Id $dump.Id -Force -ErrorAction SilentlyContinue
            Emit 'OFFICIAL_UI_DUMP_TIMED_OUT fallback_if_dialog_verified'
            continue
        }
        if ($dump.ExitCode -ne 0) { continue }
        $xmlData = (& adb -s $Serial shell cat /sdcard/task007-ui.xml 2>$null | Out-String)
        if ($xmlData -notmatch 'Começar agora|Come&#231;ar agora|Start now') { continue }
        try {
            [xml]$xml = $xmlData
            $button = @($xml.SelectNodes('//node') | Where-Object {
                $_.text -in @('Começar agora','Start now')
            } | Select-Object -First 1)
            if ($button.Count -ne 1) { continue }
            $rect = [regex]::Match($button[0].bounds,'^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
            if (-not $rect.Success) { continue }
            $x = [int](([int]$rect.Groups[1].Value+[int]$rect.Groups[3].Value)/2)
            $y = [int](([int]$rect.Groups[2].Value+[int]$rect.Groups[4].Value)/2)
            if ($x -lt 0 -or $x -gt 720 -or $y -lt 0 -or $y -gt 1560) { continue }
            Invoke-DeviceInput @('tap',([string]$x),([string]$y))
            Emit ('OFFICIAL_DIALOG_APPROVED via=xml attempt='+$attempt)
            return
        } catch {
            Emit ('CONSENT_XML_PARSE_RETRY attempt='+$attempt)
        }
    }
    if ($foundDialog -and (Test-CaptureDialog)) {
        # Coordinates are the documented validated fallback for this LG.
        Invoke-DeviceInput @('tap','488','1381')
        Emit 'OFFICIAL_DIALOG_APPROVED via=verified_window_fallback'
        return
    }
    Emit 'OWNER_TAP_REQUIRED: MediaProjectionPermissionActivity or approval button not detected'
    $script:exitCode=4
    throw 'OWNER_TAP_REQUIRED'
}

function Request-ApprovedSession() {
    $prior = Device-Count 'agent_registered device_id=phone-01'
    $failed = Device-Count 'session_failed:'
    & adb -s $Serial shell am start -n br.net.qtscrcpy.agent/.MainActivity | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ANDROID_ACTIVITY_NOT_AVAILABLE' }
    Start-Sleep -Milliseconds 650
    Set-DeviceField 360 179 'localhost'
    Set-DeviceField 360 336 'phone-01'
    Set-DeviceField 360 493 $script:token
    Invoke-DeviceInput @('keyevent','4')
    Start-Sleep -Milliseconds 300
    $focus = (& adb -s $Serial shell dumpsys activity activities 2>$null | Out-String)
    if ($focus -notmatch 'br.net.qtscrcpy.agent/.MainActivity') {
        Emit 'OWNER_TAP_REQUIRED: Android MainActivity not in foreground after keyboard'
        $script:exitCode=4
        throw 'OWNER_TAP_REQUIRED'
    }
    Invoke-DeviceInput @('tap','360','609')
    Approve-CaptureDialog
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
    if ($null -eq $script:firstRegisteredLine) {
        $line = @((Device-Log) | Where-Object { $_ -match 'agent_registered device_id=phone-01' } | Select-Object -Last 1)
        if ($line.Count -eq 1) { $script:firstRegisteredLine = $line[0] }
    }
}
