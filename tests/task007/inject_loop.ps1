# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# Physical Windows Qt / Android accessibility-control acceptance harness.
param([string]$Serial = 'LMX430CUAEPZJJEEUC')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../task006/ui_lab.ps1')
. (Join-Path $PSScriptRoot 'task006_phase_helpers.ps1')
. (Join-Path $PSScriptRoot 'win_input.ps1')

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

try {
    $deploy=Join-Path $client 'out/deploy'
    $binary=Join-Path $deploy 'QtScrcpy.exe'
    $tokenMap=Join-Path $project 'relay/tokens.json'
    if (-not (Test-Path $binary) -or -not (Test-Path $tokenMap)) { throw 'LAB_ARTIFACT_MISSING' }
    $script:token=([IO.File]::ReadAllText($tokenMap)|ConvertFrom-Json).'phone-01'
    if ($script:token -notmatch '^[A-Za-z0-9_-]+$') { throw 'TOKEN_FORMAT_REQUIRES_OWNER_INPUT' }
    if (@(Get-Process QtScrcpy -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'CLOSE_EXISTING_QT_INSTANCE'
    }
    if ((Cmd-Adb @('get-state')) -ne 'device') { throw 'DEVICE_UNAVAILABLE' }
    Begin-Phase 'P0'
    $active = Cmd-Adb @('shell','dumpsys','activity','services','br.net.qtscrcpy.agent')
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
    End-Phase 'relay and agent registered; input bridge active'

    Begin-Phase 'P1'
    $script:qt=Start-Process -FilePath $binary -WorkingDirectory $deploy -PassThru -RedirectStandardError (Join-Path $run 'qt-process-stderr.txt')
    Wait-For { @(Get-QscMain $script:qt.Id).Count -eq 1 } 12 'QT_MAIN_MISSING'
    # The top-level window becomes visible before Qt populates its dynamic
    # remote GroupBox; wait for all three QLineEdits in that group.
    Wait-For {
        try {
            Set-QscToken $script:qt.Id $script:token
            return $true
        } catch {
            return $false
        }
    } 10 'QT_REMOTE_TOKEN_FIELD_NOT_READY'
    Invoke-QscConnect $script:qt.Id
    Wait-Video 20
    Ensure-Awake
    Cmd-Adb @('shell','am','start','-a','android.settings.SETTINGS','-f','0x10008000') | Out-Null
    Start-Sleep -Seconds 3
    Qt-Focus
    $baseline=Join-Path $run 'S0.png'
    $ratio=Save-QscFrame $script:qt.Id $baseline
    $baseBrightness=Image-TopBrightness $baseline
    Emit ('S0_NONBLACK={0:F4} window=relay/phone-01' -f $ratio)
    Emit ('S0_TOP_BRIGHTNESS={0:F1}' -f $baseBrightness)
    if ($ratio -lt 0.5) { throw 'P1_BASELINE_NONBLACK_BELOW_HALF' }
    if ($baseBrightness -lt 140) {throw 'P1_BASELINE_OBSCURED_OR_NOT_SETTINGS'}
    End-Phase 'visible remote frame and awake Android display'

    Begin-Phase 'P2'
    $x=-1; $y=-1
    for($tapAttempt=1; $tapAttempt -le 3; $tapAttempt++) {
        $downBefore=Device-Count 'touch_down x='
        $gestureBefore=Device-Count 'input_gesture ok=true'
        Qt-Tap 0.5 0.5 50
        Wait-KeyLog 'touch_down x=' $downBefore
        Wait-KeyLog 'input_gesture ok=true' $gestureBefore
        $downLine=@((Device-Log)|Where-Object {$_ -match 'touch_down x='}|Select-Object -Last 1)[0]
        $m=[regex]::Match($downLine,'touch_down x=(\d+) y=(\d+)')
        if (-not $m.Success) { throw 'TOUCH_COORDINATES_MISSING' }
        $x=[int]$m.Groups[1].Value; $y=[int]$m.Groups[2].Value
        Emit "P2_TAP_COORD attempt=$tapAttempt x=$x y=$y expected=360,780 tol=14,31"
        if ([math]::Abs($x-360) -le 14 -and [math]::Abs($y-780) -le 31) { break }
        Emit "P2_TAP_RETRY inaccurate_cursor_position attempt=$tapAttempt"
    }
    if ([math]::Abs($x-360) -gt 14 -or [math]::Abs($y-780) -gt 31) { throw 'TOUCH_COORDINATES_OUT_OF_TOLERANCE' }
    $before=Device-Count 'input_gesture ok=true pts=(?:[3-9](?!\d)|[1-9]\d+)'
    Qt-Swipe 0.5 0.06 0.42
    Wait-KeyLog 'input_gesture ok=true pts=(?:[3-9](?!\d)|[1-9]\d+)' $before 6
    Start-Sleep -Seconds 2
    $after=Join-Path $run 'S1.png'
    $nonblack=Save-QscFrame $script:qt.Id $after
    $difference=Image-Difference $baseline $after
    Emit ('P2_FIRST_SWIPE_CHANGED_RATIO={0:F4} S1_NONBLACK={1:F4}' -f $difference,$nonblack)
    if ($difference -lt 0.30) {
        # On LG's Android 10 status bar, y=0.06 can land just below the
        # draggable status region. Preserve the requested first swipe and
        # then retry from within the actual status bar to expose the shade.
        Emit 'P2_SHADE_FALLBACK reason=first_swipe_below_status_region'
        $before=Device-Count 'input_gesture ok=true pts=(?:[3-9](?!\d)|[1-9]\d+)'
        Qt-Swipe 0.5 0.015 0.55
        Wait-KeyLog 'input_gesture ok=true pts=(?:[3-9](?!\d)|[1-9]\d+)' $before 6
        Start-Sleep -Seconds 2
        $nonblack=Save-QscFrame $script:qt.Id $after
        $difference=Image-Difference $baseline $after
    }
    Emit ('P2_S1_CHANGED_RATIO={0:F4} S1_NONBLACK={1:F4}' -f $difference,$nonblack)
    if ($difference -lt 0.05) { throw 'NOTIFICATION_SHADE_NOT_VISUALLY_CONFIRMED' }
    Redact-ShadeEvidence $after
    Emit 'S1_EVIDENCE_REDACTED=true ratio_measured_before_redaction'
    $scrolls=Device-Count 'input_scroll dx='
    for($wheelAttempt=1;$wheelAttempt -le 3;$wheelAttempt++) {
        Qt-Focus
        $center=Qt-Point 0.5 0.5
        Require-QtTarget $center.X $center.Y
        [QscWinInput]::MoveCursor($center.X,$center.Y)
        [QscWinInput]::WheelDown(5)
        Start-Sleep -Milliseconds 400
        if((Device-Count 'input_scroll dx=') -gt $scrolls) { break }
        Emit ('P2_WHEEL_RETRY attempt='+$wheelAttempt)
    }
    if((Device-Count 'input_scroll dx=') -le $scrolls) {
        throw 'INPUT_SCROLL_NOT_CONFIRMED'
    }
    Qt-Swipe 0.5 0.42 0.06
    $shadeClosed = Join-Path $run 'S2-after-close.png'
    $shadeClosedOk=$false
    for($closeAttempt=1;$closeAttempt -le 4;$closeAttempt++) {
        if($closeAttempt -gt 1) {
            # LG's drawer sometimes scrolls notifications on the first
            # inverse gesture instead of collapsing the entire panel.
            Qt-Swipe 0.5 0.85 0.015
        }
        Start-Sleep -Milliseconds 550
        $null = Save-QscFrame $script:qt.Id $shadeClosed
        $topBrightness=Image-TopBrightness $shadeClosed
        Emit ('P2_SHADE_CLOSE_TOP_BRIGHTNESS attempt={0} value={1:F1} baseline={2:F1}' -f $closeAttempt,$topBrightness,$baseBrightness)
        if($topBrightness -ge 0.70*$baseBrightness) {
            $shadeClosedOk=$true
            break
        }
    }
    if (-not $shadeClosedOk) {
        # The required inverse swipes have been delivered. Android's BACK
        # global action is a Qt-side fallback to dismiss LG's sticky drawer.
        Emit 'P2_SHADE_CLOSE_FALLBACK=qt_ctrl_b'
        $backs=Device-Count 'global_action=BACK'
        Qt-Focus
        [QscWinInput]::Shortcut('b')
        Wait-KeyLog 'global_action=BACK' $backs
        Start-Sleep -Milliseconds 750
        $null = Save-QscFrame $script:qt.Id $shadeClosed
        $topBrightness=Image-TopBrightness $shadeClosed
        Emit ('P2_SHADE_CLOSE_BACK_TOP_BRIGHTNESS={0:F1}' -f $topBrightness)
        $shadeClosedOk=($topBrightness -ge 0.70*$baseBrightness)
    }
    if (-not $shadeClosedOk) { throw 'NOTIFICATION_SHADE_DID_NOT_CLOSE_FROM_QT' }
    Remove-Item -LiteralPath $shadeClosed -Force -ErrorAction SilentlyContinue
    End-Phase 'tap coordinates, notification swipe, image change and wheel'

    Begin-Phase 'P3'
    # Open a known, editable Settings search field before testing Qt typing.
    # Explicitly restart Settings: plain am start may return an already
    # running deep page from P2, where the search box is absent.
    Cmd-Adb @('shell','am','force-stop','com.android.settings') | Out-Null
    Cmd-Adb @('shell','am','start','-a','android.settings.SETTINGS') | Out-Null
    Start-Sleep -Seconds 2
    $keyboardReady = $false
    for ($searchAttempt=1;$searchAttempt -le 3;$searchAttempt++) {
        # LG SettingsHomepageActivity search is y≈350 of the 1560px display.
        Qt-Tap 0.5 0.225
        Start-Sleep -Milliseconds 650
        $ime=Cmd-Adb @('shell','dumpsys','input_method')
        if ($ime -match 'mInputShown=true') {
            $keyboardReady=$true
            break
        }
        Emit ('P3_SEARCH_FOCUS_RETRY attempt='+$searchAttempt)
        if($searchAttempt -lt 3) {
            # A lingering notification panel must be dismissed through Qt
            # before the Android Settings search input can receive letters.
            Qt-Swipe 0.5 0.80 0.015
            Cmd-Adb @('shell','am','force-stop','com.android.settings') | Out-Null
            Cmd-Adb @('shell','am','start','-a','android.settings.SETTINGS') | Out-Null
        }
    }
    if (-not $keyboardReady) { throw 'P3_ANDROID_EDITABLE_FIELD_NOT_FOCUSED' }
    $textStart=Device-Count 'text_injected len=1 ok=true'
    Qt-Focus
    foreach($char in @('a','b','c')) {
        [QscWinInput]::UnicodeChar([char]$char)
        Start-Sleep -Milliseconds 200
    }
    Wait-For { (Device-Count 'text_injected len=1 ok=true') -ge $textStart + 3 } 7 'TEXT_INJECTION_NOT_CONFIRMED_THREE_CHARS'
    Emit 'P3_TEXT_INJECTED_ABC=true'
    Cmd-Adb @('shell','media','volume','--stream','3','--set','12') | Out-Null
    $beforeVolume=Music-Level
    Emit "P3_AUDIO_BEFORE=$beforeVolume"
    if ($beforeVolume -ne 12) { throw 'MUSIC_VOLUME_RESET_FAILED' }
    $vBefore=Device-Count 'volume dir=up'
    Invoke-VolumeButton
    Wait-KeyLog 'volume dir=up' $vBefore
    Start-Sleep -Milliseconds 350
    $afterVolume=Music-Level
    Emit "P3_AUDIO_AFTER=$afterVolume DELTA=$($afterVolume-$beforeVolume)"
    if ($afterVolume -ne $beforeVolume + 1) { throw 'VOLUME_DELTA_NOT_ONE' }
    Qt-Focus
    $homes=Device-Count 'global_action=HOME'
    [QscWinInput]::Shortcut('h')
    Wait-KeyLog 'global_action=HOME' $homes
    $backs=Device-Count 'global_action=BACK'
    [QscWinInput]::Shortcut('b')
    Wait-KeyLog 'global_action=BACK' $backs
    $final=Join-Path $run 'S3.png'
    $ratio=Save-QscFrame $script:qt.Id $final
    Emit ('S3_NONBLACK={0:F4}' -f $ratio)
    if ($ratio -lt 0.5) { throw 'P3_VIDEO_NOT_VISIBLE' }
    End-Phase 'text injection, exact volume +1, HOME/BACK, video alive'

    Begin-Phase 'P4'
    Close-QscVideo $script:qt.Id
    Wait-Closed 5
    Wait-For { (Device-Count 'service_stopped sent_frames=\d+') -ge 1 } 14 'AGENT_DID_NOT_STOP_CLEANLY'
    Test-Counts
    if ($script:qt.HasExited) { throw 'QT_PROCESS_CRASHED' }
    End-Phase 'clean terminal 1/1/1 and Qt alive'
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
    try { Stop-Relay } catch { Emit 'RELAY_CLOSE_FAILED' }
    Emit ('TASK007_HARNESS_EXIT='+$script:exitCode)
}
exit $script:exitCode
