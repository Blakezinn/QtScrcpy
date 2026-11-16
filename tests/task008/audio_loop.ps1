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
# TASK-008: TASK-007 helper functions are inserted above this block.
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
try {
    $deploy=Join-Path $client 'out/deploy'
    $binary=Join-Path $deploy 'QtScrcpy.exe'
    $tokenMap=Join-Path $project 'relay/tokens.json'
    if (-not (Test-Path $binary) -or -not (Test-Path $tokenMap)) { throw 'LAB_ARTIFACT_MISSING' }
    $script:token=([IO.File]::ReadAllText($tokenMap)|ConvertFrom-Json).'phone-01'
    if ($script:token -notmatch '^[A-Za-z0-9_-]+$') { throw 'TOKEN_FORMAT_REQUIRES_OWNER_INPUT' }
    if (@(Get-Process QtScrcpy -ErrorAction SilentlyContinue).Count -gt 0) { throw 'CLOSE_EXISTING_QT_INSTANCE' }
    if ((Cmd-Adb @('get-state')) -ne 'device') { throw 'DEVICE_UNAVAILABLE' }
    Begin-Phase 'P0'
    $active=Cmd-Adb @('shell','dumpsys','activity','services','br.net.qtscrcpy.agent')
    if ($active -match 'ServiceRecord\{[^\r\n]*MirrorService') { throw 'MIRROR_SERVICE_ALREADY_ACTIVE' }
    Clear-StaleRelay
    Cmd-Adb @('logcat','-c') | Out-Null
    $script:logStartLocal=Get-Date
    $script:logcat=Start-Process -FilePath (Get-Command adb).Source -ArgumentList @(
        '-s',$Serial,'logcat','-T','1','-v','threadtime','-s','QscnetAgent:I'
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $androidLog
    Start-Sleep -Seconds 1
    Enable-Bridge
    Start-Relay
    Cmd-Adb @('reverse','tcp:8443','tcp:8443') | Out-Null
    Cmd-Adb @('reverse','tcp:9000','tcp:9000') | Out-Null
    Request-ApprovedSession
    $oldAudioVar=$env:QSC_AUDIO_DUMP
    try {
        $env:QSC_AUDIO_DUMP=Join-Path $run 'audio.wav'
        $script:qt=Start-Process -FilePath $binary -WorkingDirectory $deploy -PassThru -RedirectStandardError (Join-Path $run 'qt-process-stderr.txt')
    } finally { $env:QSC_AUDIO_DUMP=$oldAudioVar }
    Wait-For { @(Get-QscMain $script:qt.Id).Count -eq 1 } 12 'QT_MAIN_MISSING'
    Wait-For { try {Set-QscToken $script:qt.Id $script:token;return $true} catch {return $false} } 12 'QT_TOKEN_FIELD_NOT_READY'
    Invoke-QscConnect $script:qt.Id
    Wait-Video 20
    Wait-For { (Device-Count 'audio_capturing sdk=29 src=(?:voice_comm|default) codec=pcm rate=(?:44100|48000|16000) ch=1') -gt 0 -or
        (Device-Count 'audio_unavailable sdk=29') -gt 0 } 30 'AUDIO_CAPTURE_RESULT_MISSING'
    if ((Device-Count 'audio_unavailable sdk=29') -gt 0) { throw 'AUDIO_CAPTURE_UNAVAILABLE' }
    $captureLine=@((Device-Log) | Where-Object { $_ -match 'audio_capturing sdk=29' } | Select-Object -Last 1)[0]
    $rateMatch=[regex]::Match($captureLine,'rate=(44100|48000|16000) ch=1')
    if(-not $rateMatch.Success){throw 'CAPTURE_RATE_UNKNOWN'}
    $captureRate=[int]$rateMatch.Groups[1].Value
    Emit ('P0_CAPTURE_RATE='+$captureRate)
    Wait-For { Qt-Audio-Log-Has ('audio_stream_open rate='+$captureRate+' ch=1 codec=pcm_s16le') } 30 'QT_AUDIO_STREAM_NOT_OPEN'
    Emit ('P0_AUDIO_STREAM_OPEN rate='+$captureRate)
    End-Phase 'authenticated pair; Android and Qt audio rates match'

    Begin-Phase 'P1'
    Ensure-Awake
    Cmd-Adb @('shell','am','start','-a','android.settings.SETTINGS','-f','0x10008000') | Out-Null
    Start-Sleep -Seconds 2
    Qt-Focus
    $p1=Join-Path $run 'S1.png'
    $ratio=Save-QscFrame $script:qt.Id $p1
    Emit ('P1_S1_NONBLACK={0:F4}' -f $ratio)
    if ($ratio -lt 0.5) { throw 'P1_NONBLACK_BELOW_HALF' }
    End-Phase 'video remains visible with audio channel active'

    Begin-Phase 'P2'
    Cmd-Adb @('shell','am','broadcast','-p','br.net.qtscrcpy.agent','-a','br.net.qtscrcpy.agent.PLAY_TONE','--ei','ms','20000') | Out-Null
    Wait-For { (Device-Count 'tone_play ms=20000') -ge 1 } 5 'TONE_DID_NOT_START'
    Emit 'P2_TONE_PLAY=true'
    End-Phase '440Hz looping tone broadcast acknowledged'

    Begin-Phase 'P3'
    $downBefore=Device-Count 'touch_down x='
    $gestureBefore=Device-Count 'input_gesture ok=true'
    Qt-Tap 0.5 0.5 50
    Wait-KeyLog 'touch_down x=' $downBefore 5
    Wait-KeyLog 'input_gesture ok=true' $gestureBefore 5
    $downLine=@((Device-Log) | Where-Object {$_ -match 'touch_down x='} | Select-Object -Last 1)[0]
    $coordinates=[regex]::Match($downLine,'touch_down x=(\d+) y=(\d+)')
    if(-not $coordinates.Success){throw 'P3_COORDINATES_MISSING'}
    $x=[int]$coordinates.Groups[1].Value;$y=[int]$coordinates.Groups[2].Value
    Emit "P3_TAP_COORD x=$x y=$y expected=360,780 tol=14,31"
    if([math]::Abs($x-360) -gt 14 -or [math]::Abs($y-780) -gt 31){throw 'P3_TAP_OUTSIDE_TOLERANCE'}
    Qt-Focus
    $homes=Device-Count 'global_action=HOME'
    [QscWinInput]::Shortcut('h')
    Wait-KeyLog 'global_action=HOME' $homes 5
    Start-Sleep -Seconds 4
    $p3=Join-Path $run 'S4.png'
    $ratio=Save-QscFrame $script:qt.Id $p3
    Emit ('P3_S4_NONBLACK={0:F4}' -f $ratio)
    if ($ratio -lt 0.5) { throw 'P3_NONBLACK_BELOW_HALF' }
    Redact-HomeEvidence $p3
    Emit 'P3_S4_EVIDENCE_REDACTED=true ratio_measured_before_redaction'
    End-Phase 'tap, HOME and nonblack video during tone playback'

    Begin-Phase 'P4'
    Cmd-Adb @('shell','am','broadcast','-p','br.net.qtscrcpy.agent','-a','br.net.qtscrcpy.agent.STOP_TONE') | Out-Null
    Wait-For { (Device-Count 'tone_stop') -ge 1 } 5 'TONE_DID_NOT_STOP'
    Close-QscVideo $script:qt.Id
    Wait-Closed 5
    Wait-For { (Device-Count 'service_stopped sent_frames=\d+') -ge 1 } 12 'AGENT_DID_NOT_STOP'
    Test-Counts
    $stopped=Device-Count 'audio_stopped'
    Emit ('P4_AUDIO_STOPPED_COUNT='+$stopped)
    if ($stopped -ne 1) { throw 'AUDIO_STOP_COUNT_INVALID' }
    Wait-For { (Qt-Audio-Log-Has 'audio_dump_wrote_bytes=[1-9]\d*') -and
        (Qt-Audio-Log-Has 'audio_stream_closed bytes=[1-9]\d*') } 8 'QT_AUDIO_DUMP_OR_CLOSE_MISSING'
    if($script:qt.HasExited){throw 'QT_PROCESS_CRASHED'}
    $audioPath=Join-Path $run 'audio.wav'
    if(-not (Test-Path $audioPath)){throw 'AUDIO_WAV_NOT_WRITTEN'}
    $probeArgs=@('-v','error','-show_entries','stream=sample_rate,channels:format=format_name,duration','-of','default=noprint_wrappers=1',$audioPath)
    $probe=@(& ffprobe @probeArgs 2>&1)
    $probeExit=$LASTEXITCODE
    $probe | Set-Content (Join-Path $run 'ffprobe.txt') -Encoding UTF8
    foreach($line in $probe){Emit ('FFPROBE '+$line)}
    if($probeExit -ne 0){throw 'FFPROBE_ERROR'}
    $probeText=$probe -join [Environment]::NewLine
    if($probeText -notmatch 'format_name=wav' -or $probeText -notmatch 'channels=1' -or
        $probeText -notmatch ('sample_rate='+$captureRate)){throw 'WAV_FORMAT_MISMATCH'}
    $durationMatch=[regex]::Match($probeText,'duration=(\d+(?:\.\d+)?)')
    if(-not $durationMatch.Success -or [double]::Parse($durationMatch.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture) -lt 2.0) {
        throw 'WAV_DURATION_LT_TWO_SECONDS'
    }
    $analysis=@(& python (Join-Path $PSScriptRoot 'analyze_audio.py') $audioPath 2>&1)
    $analysisExit=$LASTEXITCODE
    $analysis | Set-Content (Join-Path $run 'analysis.txt') -Encoding UTF8
    foreach($line in $analysis){Emit ('ANALYSIS '+$line)}
    if($analysisExit -ne 0){throw 'AUDIO_SPECTRUM_TEST_FAILED'}
    End-Phase 'terminal 1/1/1; WAV 440Hz validated in >=3 adjacent seconds'
    $script:exitCode=0
} catch {
    $reason=$_.Exception.Message -replace '[\r\n]+',' '
    if ($reason -match 'OWNER_TAP_REQUIRED') { $script:exitCode=4 }
    Emit ($script:phase+'_FAIL '+$reason)
} finally {
    if ($null -ne $script:logcat -and -not $script:logcat.HasExited) {
        Stop-Process -Id $script:logcat.Id -Force -ErrorAction SilentlyContinue
    }
    try {
        if (Test-Path $qtLogSource) {
            @(Get-Content $qtLogSource | Where-Object {
                $_.Length -ge 24 -and
                [datetime]::Parse($_.Substring(0,24)).ToUniversalTime() -ge $script:auditStart
            }) | Set-Content -Encoding UTF8 -LiteralPath $qtLog
        }
    } catch { Emit 'QT_OUTLOG_CAPTURE_UNAVAILABLE' }
    if ($null -ne $script:qt -and -not $script:qt.HasExited) {
        try {
            foreach($w in (Get-QscWindows $script:qt.Id)) {
                [void][QscUiLab]::PostMessage($w.Handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
            }
            if (-not $script:qt.WaitForExit(2500)) {
                Stop-Process -Id $script:qt.Id -ErrorAction SilentlyContinue
            }
        } catch { Emit 'QT_CLOSE_FAILED' }
    }
    try { Cmd-Adb @('shell','am','broadcast','-p','br.net.qtscrcpy.agent','-a','br.net.qtscrcpy.agent.STOP_TONE') | Out-Null } catch {}
    try { Stop-Relay } catch { Emit 'RELAY_CLOSE_FAILED' }
    # Session IDs are bearer capabilities. Keep traffic counters/diagnostics,
    # but never retain these 64-hex identifiers in committed evidence.
    foreach($relayFile in @(Get-ChildItem -LiteralPath $run -Filter 'relay-*-stdout.txt' -File -ErrorAction SilentlyContinue)) {
        $original=[IO.File]::ReadAllText($relayFile.FullName)
        $safe=[regex]::Replace($original,'(?i)\b[a-f0-9]{64}\b','<session-redacted>')
        [IO.File]::WriteAllText($relayFile.FullName,$safe,(New-Object Text.UTF8Encoding($false)))
    }
    Emit ('TASK008_HARNESS_EXIT='+$script:exitCode)
}
exit $script:exitCode
