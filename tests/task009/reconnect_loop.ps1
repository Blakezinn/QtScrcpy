# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# Physical Windows Qt / Android accessibility-control acceptance harness.
param([string]$Serial = 'LMX430CUAEPZJJEEUC')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../task006/ui_lab.ps1')
. (Join-Path $PSScriptRoot '../task007/task006_phase_helpers.ps1')
. (Join-Path $PSScriptRoot '../task007/win_input.ps1')

$project = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$client = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$run = Join-Path $PSScriptRoot ('evidence/run-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$stdout = Join-Path $run 'stdout.txt'
$androidLog = Join-Path $run 'device-logcat.txt'
$qtLog = Join-Path $run 'client-stderr.txt'
$qtLogSource = Join-Path $client 'out/deploy/startup.stderr.log'
$script:auditStart = [DateTime]::UtcNow
$script:logStartLocal = Get-Date
$script:relayRun = 0
$script:firstRegisteredLine = $null
$script:phase = 'P0'
$script:exitCode = 1
$script:qt = $null
$script:relay = $null
$script:logcat = $null
$script:bridgeId = 'br.net.qtscrcpy.agent/br.net.qtscrcpy.agent.InputBridgeService'

function Cmd-Adb([string[]]$argsList) {
    # Secret arguments are never included in console output or evidence.
    # ActivityManager prints harmless "already started" messages on stderr
    # even when adb exits zero. Do not turn these into PowerShell failures.
    $previousPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $text = & adb -s $Serial @argsList 2>$null | Out-String
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$previousPreference }
    if ($code -ne 0) { throw ('ADB_FAILED '+$argsList[0]) }
    return $text.Trim()
}
function Try-ApproveBridgeDialog {
    # Only the native Android Settings authorization screen may be touched.
    # Never approve an unrelated permission prompt.
    $activity=Cmd-Adb @('shell','dumpsys','activity','activities')
    if ($activity -notmatch 'com.android.settings') { return $false }
    $dump=Start-Process -FilePath (Get-Command adb).Source -PassThru -WindowStyle Hidden -ArgumentList @(
        '-s',$Serial,'shell','uiautomator','dump','/sdcard/task007-bridge-ui.xml'
    ) -RedirectStandardOutput (Join-Path $run 'bridge-uia-stdout.txt') -RedirectStandardError (Join-Path $run 'bridge-uia-stderr.txt')
    if (-not $dump.WaitForExit(6000)) {
        Stop-Process -Id $dump.Id -Force -ErrorAction SilentlyContinue
        return $false
    }
    if ($dump.ExitCode -ne 0) { return $false }
    $xmlText=Cmd-Adb @('shell','cat','/sdcard/task007-bridge-ui.xml')
    try {
        [xml]$document=$xmlText
        $button=@($document.SelectNodes('//node') | Where-Object {
            $_.text -in @('Permitir','Allow') -and
            $_.bounds -match '^\[\d+,\d+\]\[\d+,\d+\]$'
        } | Select-Object -First 1)
        if ($button.Count -ne 1) { return $false }
        $bounds=[regex]::Match($button[0].bounds,'^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
        $x=[int](([int]$bounds.Groups[1].Value+[int]$bounds.Groups[3].Value)/2)
        $y=[int](([int]$bounds.Groups[2].Value+[int]$bounds.Groups[4].Value)/2)
        if ($x -lt 0 -or $x -gt 720 -or $y -lt 0 -or $y -gt 1560) { return $false }
        Invoke-DeviceInput @('tap',([string]$x),([string]$y))
        Emit 'BRIDGE_OFFICIAL_PERMISSION_APPROVED=true'
        return $true
    } catch { return $false }
}
function Enable-Bridge {
    $previous = Cmd-Adb @('shell','settings','get','secure','enabled_accessibility_services')
    if ($previous -eq 'null') { $previous = '' }
    $existing = @($previous.Split(':') | Where-Object { $_ })
    if ($existing -contains $script:bridgeId) {
        # logcat -c removed the previous onServiceConnected message.
        # Rebind only our bridge to obtain a fresh, real ready event;
        # keep every other service enabled throughout this operation.
        $others = @($existing | Where-Object { $_ -ne $script:bridgeId })
        if ($others.Count -eq 0) {
            Cmd-Adb @('shell','settings','delete','secure','enabled_accessibility_services') | Out-Null
        } else {
            Cmd-Adb @('shell','settings','put','secure','enabled_accessibility_services',($others -join ':')) | Out-Null
        }
        Start-Sleep -Milliseconds 500
    }
    $enabled = (@($existing | Where-Object { $_ -ne $script:bridgeId }) +
        @($script:bridgeId)) -join ':'
    Cmd-Adb @('shell','settings','put','secure','enabled_accessibility_services',$enabled) | Out-Null
    Cmd-Adb @('shell','settings','put','secure','accessibility_enabled','1') | Out-Null
    Emit 'ACCESSIBILITY_SETTINGS_APPLIED preserving_existing_services=true'
    $deadline=(Get-Date).AddSeconds(5)
    while ((Device-Count 'input_bridge ready') -lt 1 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if ((Device-Count 'input_bridge ready') -lt 1) {
        if (-not (Try-ApproveBridgeDialog)) {
            Emit 'OWNER_TAP_REQUIRED: confirmar o dialogo oficial de acessibilidade do Android'
            $script:exitCode=4
            throw 'OWNER_TAP_REQUIRED'
        }
        Wait-For { (Device-Count 'input_bridge ready') -ge 1 } 30 'INPUT_BRIDGE_NOT_READY'
    }
    Emit 'INPUT_BRIDGE_READY=true'
}
function Video-Bounds {
    $wins = @(Get-QscVideo $script:qt.Id)
    if ($wins.Count -ne 1) { throw 'EXPECTED_ONE_QT_VIDEO_WINDOW' }
    $w = $wins[0]
    # Unskinned Qt has a title bar of 30 px. The frame contents keep 720:1560.
    $innerWidth = $w.Right - $w.Left - 8
    $innerHeight = $w.Bottom - $w.Top - 39
    return [pscustomobject]@{
        Left = $w.Left + 4
        Top = $w.Top + 30
        Width = $innerWidth
        Height = $innerHeight
        Handle = $w.Handle
    }
}
function Qt-Point([double]$nx,[double]$ny) {
    $area = Video-Bounds
    return [pscustomobject]@{
        X = [int]($area.Left + $area.Width * $nx)
        Y = [int]($area.Top + $area.Height * $ny)
    }
}
function Qt-Focus {
    $w = Video-Bounds
    for($attempt=1;$attempt -le 6;$attempt++) {
        [QscWinInput]::BringToFront($w.Handle)
        Start-Sleep -Milliseconds 100
        if([QscWinInput]::AcceptsInput($w.Handle,
                [int]($w.Left+$w.Width*0.5),[int]($w.Top+$w.Height*0.5))) {
            return
        }
    }
    throw 'QT_VIDEO_NOT_FOREGROUND_OR_OBSCURED'
}
function Require-QtTarget([int]$x,[int]$y) {
    $w=Video-Bounds
    [QscWinInput]::BringToFront($w.Handle)
    if(-not [QscWinInput]::AcceptsInput($w.Handle,$x,$y)) {
        throw 'QT_INPUT_TARGET_OBSCURED'
    }
}
function Qt-Tap([double]$nx,[double]$ny,[int]$hold = 50) {
    Qt-Focus
    $point = Qt-Point $nx $ny
    Require-QtTarget $point.X $point.Y
    [QscWinInput]::Tap($point.X,$point.Y,$hold)
}
function Qt-Swipe([double]$nx,[double]$from,[double]$to) {
    Qt-Focus
    $a = Qt-Point $nx $from
    $b = Qt-Point $nx $to
    Require-QtTarget $a.X $a.Y
    Require-QtTarget $b.X $b.Y
    [QscWinInput]::Drag($a.X,$a.Y,$b.X,$b.Y,700)
}
function Image-Difference([string]$before,[string]$after) {
    $first = [System.Drawing.Bitmap]::FromFile($before)
    $second = [System.Drawing.Bitmap]::FromFile($after)
    try {
        if ($first.Width -ne $second.Width -or $first.Height -ne $second.Height) {
            throw 'FRAME_DIMENSIONS_CHANGED'
        }
        $diff=0; $sampled=0
        for ($y=48;$y -lt $first.Height-35;$y+=6) {
            for ($x=14;$x -lt $first.Width-14;$x+=6) {
                $a=$first.GetPixel($x,$y); $b=$second.GetPixel($x,$y)
                if (([math]::Abs([int]$a.R-[int]$b.R) +
                     [math]::Abs([int]$a.G-[int]$b.G) +
                     [math]::Abs([int]$a.B-[int]$b.B)) -gt 75) { $diff++ }
                $sampled++
            }
        }
        return $diff/[math]::Max($sampled,1)
    } finally {
        $first.Dispose()
        $second.Dispose()
    }
}
function Image-TopBrightness([string]$imagePath) {
    $bitmap=[System.Drawing.Bitmap]::FromFile($imagePath)
    try {
        $total=0.0; $count=0
        for($y=45;$y -lt [math]::Min(110,$bitmap.Height-10);$y+=8) {
            for($x=25;$x -lt $bitmap.Width-25;$x+=12) {
                $pixel=$bitmap.GetPixel($x,$y)
                $total += ($pixel.R+$pixel.G+$pixel.B)/3
                $count++
            }
        }
        return ($total/[math]::Max(1,$count))
    } finally {$bitmap.Dispose()}
}
function Redact-ShadeEvidence([string]$imagePath) {
    # System notification cards may contain contacts, credentials and photos.
    # Keep the quick-setting tiles and shade title visible, but never commit
    # personally identifying notification contents as acceptance evidence.
    $temporary=$imagePath+'.redacted.png'
    $bitmap=[System.Drawing.Bitmap]::FromFile($imagePath)
    try {
        $canvas=[System.Drawing.Graphics]::FromImage($bitmap)
        $fill=New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(239,241,243))
        $ink=New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(50,54,58))
        $font=New-Object System.Drawing.Font ('Segoe UI',12)
        try {
            $height=[math]::Max(0,$bitmap.Height-445)
            $canvas.FillRectangle($fill,18,370,$bitmap.Width-36,$height)
            $canvas.DrawString('Notificações omitidas na evidência',$font,$ink,34,404)
        } finally {
            $canvas.Dispose(); $fill.Dispose(); $ink.Dispose(); $font.Dispose()
        }
        $bitmap.Save($temporary,[System.Drawing.Imaging.ImageFormat]::Png)
    } finally {$bitmap.Dispose()}
    Move-Item -LiteralPath $temporary -Destination $imagePath -Force
}
function Music-Level {
    $text = Cmd-Adb @('shell','dumpsys','audio')
    $section = [regex]::Match($text,'(?s)- STREAM_MUSIC:.*?(?=\r?\n\s*- STREAM_[A-Z]|\z)').Value
    $current = [regex]::Match($section,'Current:.*?2 \(speaker\):\s*(\d+)')
    if (-not $current.Success) { throw 'MUSIC_SPEAKER_LEVEL_UNREADABLE' }
    return [int]$current.Groups[1].Value
}
function Invoke-VolumeButton {
    # Toolbar is a separate top-level Qt window in this fork.
    # Query every top-level Qt window through UIA: the toolbar is narrower
    # than the TASK-006 80-pixel threshold for video window enumeration.
    $filter=New-Object System.Windows.Automation.PropertyCondition -ArgumentList @(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,$script:qt.Id)
    $root=[System.Windows.Automation.AutomationElement]::RootElement
    $windows=$root.FindAll([System.Windows.Automation.TreeScope]::Children,$filter)
    foreach($element in $windows) {
        $item = Find-QscElement $element 'volume_up' 'Button'
        if ($null -ne $item) {
            [void][QscUiLab]::SetForegroundWindow([IntPtr]$element.Current.NativeWindowHandle)
            $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Emit 'VOLUME_UP_UI_AUTOMATION_TRIGGERED=true'
            return
        }
    }
    throw 'VOLUME_UP_UI_AUTOMATION_MISSING'
}
function Wait-KeyLog([string]$pattern,[int]$before,[int]$seconds = 5) {
    Wait-For { (Device-Count $pattern) -gt $before } $seconds ('INPUT_LOG_NOT_OBSERVED_'+$pattern)
}
function Ensure-Awake {
    $status = Cmd-Adb @('shell','dumpsys','power')
    if ($status -notmatch 'mWakefulness=Awake') {
        Cmd-Adb @('shell','input','keyevent','224') | Out-Null
        Wait-For { (Cmd-Adb @('shell','dumpsys','power')) -match 'mWakefulness=Awake' } 10 'SCREEN_STILL_ASLEEP'
    }
    Emit 'ANDROID_SCREEN_AWAKE=true'
}
function Test-Counts {
    $registered=Device-Count 'agent_registered device_id=phone-01'
    $encoder=Device-Count 'capture_initialized width='
    $stopped=Device-Count 'service_stopped sent_frames=\d+'
    Emit "P4_COUNTS agent_registered=$registered capture_initialized=$encoder service_stopped=$stopped"
    if ($registered -ne 1 -or $encoder -ne 1 -or $stopped -ne 1) {
        throw 'P4_COUNTS_NOT_ONE_ONE_ONE'
    }
}

# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# TASK-009: TASK-007 helper functions are inserted above this block.
$script:approveMediaProjection = (Get-Command 'Approve-CaptureDialog').ScriptBlock
function Audio-PermissionGranted {
    $packageInfo=Cmd-Adb @('shell','dumpsys','package','br.net.qtscrcpy.agent')
    return $packageInfo -match 'android.permission.RECORD_AUDIO: granted=true'
}
function Approve-CaptureDialog {
    if (-not (Audio-PermissionGranted)) {
        # A one-time RECORD_AUDIO permission is required for playback capture
        # on this Android 10 device. Only press a verified native permission UI.
        $activity=Cmd-Adb @('shell','dumpsys','activity','activities')
        if ($activity -notmatch 'GrantPermissionsActivity|permissioncontroller') {
            Emit 'OWNER_TAP_REQUIRED: android RECORD_AUDIO permission dialog not identified'
            $script:exitCode=4
            throw 'OWNER_TAP_REQUIRED'
        }
        $dump=Cmd-Adb @('shell','uiautomator','dump','/sdcard/task008-permission.xml')
        $data=Cmd-Adb @('shell','cat','/sdcard/task008-permission.xml')
        [xml]$xml=$data
        $button=@($xml.SelectNodes('//node') | Where-Object {
            $_.text -match '^(Allow|Permitir|Only while using the app|While using the app|Durante o uso do app|Permitir somente durante o uso do app|Permitir durante o uso do app)$' -and
            $_.bounds -match '^\[\d+,\d+\]\[\d+,\d+\]$'
        } | Select-Object -First 1)
        if($button.Count -ne 1) {
            Emit 'OWNER_TAP_REQUIRED: permission action not recognized'
            $script:exitCode=4
            throw 'OWNER_TAP_REQUIRED'
        }
        $bounds=[regex]::Match($button[0].bounds,'^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
        $x=[int](([int]$bounds.Groups[1].Value+[int]$bounds.Groups[3].Value)/2)
        $y=[int](([int]$bounds.Groups[2].Value+[int]$bounds.Groups[4].Value)/2)
        if($x -lt 0 -or $x -gt 720 -or $y -lt 0 -or $y -gt 1560){throw 'PERMISSION_BUTTON_OUTSIDE_SCREEN'}
        Invoke-DeviceInput @('tap',([string]$x),([string]$y))
        Wait-For { Audio-PermissionGranted } 6 'AUDIO_PERMISSION_NOT_GRANTED'
        Emit 'AUDIO_RUNTIME_PERMISSION_APPROVED=true'
        Start-Sleep -Milliseconds 750
    }
    & $script:approveMediaProjection
}
function Qt-Audio-Log-Has([string]$pattern) {
    $file=Join-Path $run 'qt-process-stderr.txt'
    if (-not (Test-Path $file)) { return $false }
    return @((Get-Content $file -ErrorAction SilentlyContinue) |
        Where-Object { $_ -match $pattern }).Count -gt 0
}
function Redact-HomeEvidence([string]$path) {
    # Preserve wallpaper/status/navigation for nonblack video proof while
    # hiding private application names, badges and their positions.
    $temporary=$path+'.redacted.png'
    $bitmap=[System.Drawing.Bitmap]::FromFile($path)
    try {
        $canvas=[System.Drawing.Graphics]::FromImage($bitmap)
        $fill=New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(42,25,77))
        $ink=New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(234,231,245))
        $font=New-Object System.Drawing.Font ('Segoe UI',11)
        try {
            $canvas.FillRectangle($fill,12,295,$bitmap.Width-24,$bitmap.Height-375)
            $canvas.DrawString('Aplicativos omitidos na imagem',$font,$ink,28,480)
        } finally {
            $canvas.Dispose();$fill.Dispose();$ink.Dispose();$font.Dispose()
        }
        $bitmap.Save($temporary,[System.Drawing.Imaging.ImageFormat]::Png)
    } finally {$bitmap.Dispose()}
    Move-Item -LiteralPath $temporary -Destination $path -Force
}
# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# Native Windows UI and physical Android reconnection acceptance.
function Start-Relay {
    $script:relayRun++
    # Use the freshly built TASK-009 binary without replacing the existing
    # existing local relay executable belonging to the lab.
    $dir=Join-Path $project 'relay'
    $binary=Join-Path $dir 'qtscrcpy-relay-task009.exe'
    if (-not (Test-Path $binary)) { throw 'TASK009_RELAY_BINARY_MISSING' }
    $script:relay=Start-Process -FilePath $binary -WorkingDirectory $dir -PassThru -WindowStyle Hidden -ArgumentList @(
        '--ctl','8443','--data','9000','--tokens','tokens.json'
    ) -RedirectStandardError (Join-Path $run ('relay-'+$script:relayRun+'-stderr.txt')) -RedirectStandardOutput (Join-Path $run ('relay-'+$script:relayRun+'-stdout.txt'))
    Wait-For {
        @((Get-NetTCPConnection -LocalPort 8443,9000 -State Listen -ErrorAction SilentlyContinue |
            Where-Object OwningProcess -eq $script:relay.Id)).Count -eq 2
    } 8 'RELAY_PORTS_NOT_LISTENING'
    Emit ('RELAY_STARTED round='+$script:relayRun+' pid='+$script:relay.Id)
}
function Qt-Audio-Log-Count([string]$pattern) {
    $file=Join-Path $run 'qt-process-stderr.txt'
    if(-not(Test-Path $file)){return 0}
    return @((Get-Content $file -ErrorAction SilentlyContinue) | Where-Object{$_ -match $pattern}).Count
}
function Reconnection-Counts {
    $registered=Device-Count 'agent_registered device_id=phone-01'
    $captures=Device-Count 'capture_initialized width='
    $stopped=Device-Count 'service_stopped sent_frames=\d+'
    $audioStopped=Device-Count 'audio_stopped'
    $audioStarted=Device-Count 'audio_capturing sdk=29'
    $attempts=Qt-Audio-Log-Count 'relay_reconnect attempt='
    $repaired=Qt-Audio-Log-Count '^relay_reconnect ok'
    $audioQt=Qt-Audio-Log-Count 'audio_stream_open rate='
    Emit "P4_COUNTS agent_registered=$registered capture_initialized=$captures service_stopped=$stopped audio_stopped=$audioStopped audio_capturing=$audioStarted qt_attempts=$attempts qt_repairs=$repaired qt_audio_opens=$audioQt"
    if($registered -ne 2 -or $captures -ne 2 -or $stopped -ne 1 -or
        $audioStopped -ne 1 -or $attempts -lt 1 -or $attempts -gt 3 -or $repaired -ne 1){
        throw 'P4_COUNTS_MISMATCH'
    }
}
try {
    $deploy=Join-Path $client 'out/deploy'
    $binary=Join-Path $deploy 'QtScrcpy.exe'
    $tokenMap=Join-Path $project 'relay/tokens.json'
    if (-not (Test-Path $binary) -or -not (Test-Path $tokenMap)){throw 'LAB_ARTIFACT_MISSING'}
    $script:token=([IO.File]::ReadAllText($tokenMap)|ConvertFrom-Json).'phone-01'
    if ($script:token -notmatch '^[A-Za-z0-9_-]+$'){throw 'TOKEN_FORMAT_REQUIRES_OWNER_INPUT'}
    if(@(Get-Process QtScrcpy -ErrorAction SilentlyContinue).Count -gt 0){throw 'PREEXISTING_QT_INSTANCE'}
    if((Cmd-Adb @('get-state')) -ne 'device'){throw 'ADB_DEVICE_UNAVAILABLE'}
    Begin-Phase 'P0'
    $active=Cmd-Adb @('shell','dumpsys','activity','services','br.net.qtscrcpy.agent')
    if($active -match 'ServiceRecord\{[^\r\n]*MirrorService'){throw 'MIRROR_ALREADY_ACTIVE'}
    Clear-StaleRelay
    try { Cmd-Adb @('logcat','-c')|Out-Null } catch {
        # ADB on this LG may transiently return nonzero immediately after an
        # APK reinstall, despite get-state reporting device. Retry once.
        Start-Sleep -Seconds 1
        Cmd-Adb @('logcat','-c')|Out-Null
    }
    $script:logStartLocal=Get-Date
    $script:logcat=Start-Process -FilePath (Get-Command adb).Source -ArgumentList @(
        '-s',$Serial,'logcat','-T','1','-v','threadtime','-s','QscnetAgent:I'
    ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $androidLog
    Start-Sleep -Seconds 1
    Enable-Bridge
    Start-Relay
    Cmd-Adb @('reverse','tcp:8443','tcp:8443')|Out-Null
    Cmd-Adb @('reverse','tcp:9000','tcp:9000')|Out-Null
    Request-ApprovedSession
    $oldAudioVar=$env:QSC_AUDIO_DUMP
    try {
        $env:QSC_AUDIO_DUMP=Join-Path $run 'audio_reconnect.wav'
        $script:qt=Start-Process -FilePath $binary -WorkingDirectory $deploy -PassThru -RedirectStandardError (Join-Path $run 'qt-process-stderr.txt')
    } finally {$env:QSC_AUDIO_DUMP=$oldAudioVar}
    Wait-For {@(Get-QscMain $script:qt.Id).Count -eq 1} 12 'QT_MAIN_MISSING'
    Wait-For {try{Set-QscToken $script:qt.Id $script:token;$true}catch{$false}} 10 'QT_TOKEN_FIELD_MISSING'
    Invoke-QscConnect $script:qt.Id
    Wait-Video 20
    Wait-For {(Device-Count 'agent_paired width=') -ge 1 -and
        (Device-Count 'audio_capturing sdk=29') -ge 1 -and
        (Qt-Audio-Log-Count 'audio_stream_open rate=') -ge 1} 30 'INITIAL_AUDIO_VIDEO_MISSING'
    Ensure-Awake
    Cmd-Adb @('shell','am','start','-a','android.settings.SETTINGS','-f','0x10008000')|Out-Null
    Wait-For {(Device-Count 'stream_frames=\d+') -ge 1} 25 'NO_REAL_FRAMES'
    Emit ('P0_COUNTS registered='+(Device-Count 'agent_registered device_id=phone-01')+
        ' paired='+(Device-Count 'agent_paired width=')+' audio='+(Qt-Audio-Log-Count 'audio_stream_open rate='))
    End-Phase 'authenticated relay with real audio and frames'

    Begin-Phase 'P1'
    $firstKilled=[DateTime]::UtcNow
    Stop-Relay
    Emit ('P1_RELAY_KILLED_AT='+$firstKilled.ToString('o'))
    Wait-For {((Device-Count 'control_closed:|stream_retry=1|stream_reregister=1') -ge 1) -and
        ((Qt-Audio-Log-Count 'relay_reconnect attempt=') -ge 1 -or
         (Qt-Log-Has 'Relay TCP connection closed|Relay data timeout'))} 10 'RELAY_KILL_NOT_DETECTED'
    $detected=([DateTime]::UtcNow-$firstKilled).TotalSeconds
    Emit ('P1_DETECTED_SECONDS={0:F3}' -f $detected)
    if($detected -gt 10){throw 'P1_DETECTION_OVER_TEN_SECONDS'}
    End-Phase 'both peers noticed relay death'

    Begin-Phase 'P2'
    $restart=[DateTime]::UtcNow
    Start-Relay
    Wait-For {
        (Device-Count 'stream_reregister=1') -ge 1 -and
        (Device-Count 'agent_registered device_id=phone-01') -ge 2 -and
        (Device-Count 'agent_paired width=') -ge 2 -and
        (Device-Count 'stream_repair_ok session=[0-9a-f]{8}') -ge 1 -and
        (Qt-Audio-Log-Count '^relay_reconnect ok') -ge 1 -and
        (Qt-Audio-Log-Count 'audio_stream_open rate=') -ge 2
    } 25 'RECOVERY_MARKERS_NOT_COMPLETE'
    $recovered=([DateTime]::UtcNow-$restart).TotalSeconds
    Emit ('P2_RECOVERED_AFTER_RESTART_SECONDS={0:F3}' -f $recovered)
    if($recovered -gt 25){throw 'P2_RECOVERY_OVER_TWENTYFIVE'}
    # Playback capture and MediaProjection remain alive by contract. Count the
    # initial capture marker separately from the reopened Qt audio stream.
    Emit ('P2_CAPTURE_MARKERS='+(Device-Count 'capture_initialized width=')+
        ' AUDIO_CAPTURE_MARKERS='+(Device-Count 'audio_capturing sdk=29'))
    Wait-Video 6
    Start-Sleep -Milliseconds 800
    $pic=Join-Path $run 'S_rec.png'
    $nonblack=Save-QscFrame $script:qt.Id $pic
    Emit ('P2_RECOVERED_NONBLACK={0:F4}' -f $nonblack)
    if($nonblack -lt 0.5){throw 'P2_RECOVERED_FRAME_BLACK'}
    End-Phase 'same Qt window reconnected with playback audio'

    Begin-Phase 'P3'
    $secondKilled=[DateTime]::UtcNow
    Stop-Relay
    Emit ('P3_RELAY_KILLED_AT='+$secondKilled.ToString('o'))
    Wait-For {Qt-Log-Has 'Remote stream disconnected for relay/phone-01' $secondKilled} 60 'P3_CLIENT_DID_NOT_TIMEOUT'
    $qtTimeout=([DateTime]::UtcNow-$secondKilled).TotalSeconds
    Emit ('P3_CLIENT_TIMEOUT_SECONDS={0:F3}' -f $qtTimeout)
    Wait-For {(Device-Count 'service_stopped sent_frames=\d+|Conexão perdida após reconexão de registro') -ge 1} 45 'P3_AGENT_DID_NOT_STOP'
    Wait-Closed 8
    $service=Cmd-Adb @('shell','dumpsys','activity','services','br.net.qtscrcpy.agent')
    if($service -match 'ServiceRecord\{[^\r\n]*MirrorService'){throw 'P3_SERVICE_STILL_ALIVE'}
    End-Phase 'terminal after permanent relay loss'

    Begin-Phase 'P4'
    $script:integrityMismatch=$false
    try {
        Reconnection-Counts
        End-Phase 'exact session and retry counts'
    } catch {
        $script:integrityMismatch=$true
        Emit ('P4_FAIL '+$_.Exception.Message)
    }

    Begin-Phase 'P5'
    $smoke=Join-Path $deploy 'transport-smoke.exe'
    $smokeOutput=Join-Path $run 'adb-forward.txt'
    $smokeError=Join-Path $run 'adb-forward-stderr.txt'
    # This Windows-subsystem executable can write normal diagnostics to
    # stderr; invoke it as a process rather than making PowerShell's
    # NativeCommandError abort the acceptance before ExitCode is recorded.
    $smokeArgs='"'+$deploy+'" '+$Serial+' forward'
    $smokeProcess=Start-Process -FilePath $smoke -ArgumentList $smokeArgs -WorkingDirectory $deploy -PassThru -WindowStyle Hidden -RedirectStandardOutput $smokeOutput -RedirectStandardError $smokeError
    if(-not $smokeProcess.WaitForExit(30000)){
        Stop-Process -Id $smokeProcess.Id -Force -ErrorAction SilentlyContinue
        throw 'P5_ADB_FORWARD_PROCESS_TIMED_OUT'
    }
    $smokeExit=$smokeProcess.ExitCode
    if($null -eq $smokeExit){
        # Qt GUI subsystem builds sometimes expose no Win32 ExitCode through
        # Start-Process; the smoke app writes its own final SMOKE_EXIT status.
        $smokeExit=if(@(Get-Content $smokeOutput,$smokeError -ErrorAction SilentlyContinue |
            Where-Object {$_ -match '^SMOKE_EXIT 0$'}).Count -gt 0){0}else{5}
    }
    Emit ('P5_ADB_FORWARD_EXIT='+$smokeExit)
    if($smokeExit -eq 5){
        Ensure-Awake
        $smokeProcess=Start-Process -FilePath $smoke -ArgumentList $smokeArgs -WorkingDirectory $deploy -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $run 'adb-forward-retry.txt') -RedirectStandardError (Join-Path $run 'adb-forward-retry-stderr.txt')
        if(-not $smokeProcess.WaitForExit(30000)){
            Stop-Process -Id $smokeProcess.Id -Force -ErrorAction SilentlyContinue
            throw 'P5_ADB_FORWARD_RETRY_TIMED_OUT'
        }
        $smokeExit=$smokeProcess.ExitCode
        if($null -eq $smokeExit){
            $smokeExit=if(@(Get-Content (Join-Path $run 'adb-forward-retry.txt'),(Join-Path $run 'adb-forward-retry-stderr.txt') -ErrorAction SilentlyContinue |
                Where-Object {$_ -match '^SMOKE_EXIT 0$'}).Count -gt 0){0}else{5}
        }
        Emit ('P5_ADB_FORWARD_RETRY_EXIT='+$smokeExit)
    }
    if($smokeExit -ne 0){throw 'P5_ADB_FORWARD_NOT_GREEN'}
    End-Phase 'ADB remains unchanged'
    $script:exitCode=if($script:integrityMismatch){1}else{0}
} catch {
    $reason=$_.Exception.Message -replace '[\r\n]+',' '
    if($reason -match 'OWNER_TAP_REQUIRED'){$script:exitCode=4}
    Emit ($script:phase+'_FAIL '+$reason)
} finally {
    try {Cmd-Adb @('shell','am','broadcast','-p','br.net.qtscrcpy.agent',
        '-a','br.net.qtscrcpy.agent.STOP_TONE')|Out-Null} catch {}
    if($script:logcat -and -not $script:logcat.HasExited){
        Stop-Process -Id $script:logcat.Id -Force -ErrorAction SilentlyContinue
    }
    if($script:qt -and -not $script:qt.HasExited){
        try {
            foreach($w in (Get-QscWindows $script:qt.Id)){
                [void][QscUiLab]::PostMessage($w.Handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
            }
            if(-not $script:qt.WaitForExit(2500)){
                Stop-Process -Id $script:qt.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {Emit 'QT_SHUTDOWN_FAILED'}
    }
    try {Stop-Relay} catch {Emit 'RELAY_SHUTDOWN_FAILED'}
    foreach($f in @(Get-ChildItem -LiteralPath $run -Filter 'relay-*-stdout.txt' -File -ErrorAction SilentlyContinue)){
        $data=[IO.File]::ReadAllText($f.FullName)
        $redacted=[regex]::Replace($data,'(?i)\b[a-f0-9]{64}\b','<session-redacted>')
        [IO.File]::WriteAllText($f.FullName,$redacted,(New-Object Text.UTF8Encoding($false)))
    }
    Emit ('TASK009_HARNESS_EXIT='+$script:exitCode)
}
exit $script:exitCode
