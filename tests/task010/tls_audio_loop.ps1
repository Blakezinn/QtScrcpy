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
# TASK-010: TASK-007 helper functions are inserted above this block.
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
    # Use the freshly built TASK-010 binary without replacing the existing
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
    if($registered -ne 2 -or $captures -ne 1 -or $stopped -ne 1 -or
        $audioStopped -ne 1 -or $audioStarted -ne 1 -or
        $attempts -lt 1 -or $attempts -gt 6 -or $repaired -ne 1){
        throw 'P4_COUNTS_MISMATCH'
    }
}

$script:tlsMode=$true
$script:relayBinary=Join-Path $project 'relay/qtscrcpy-relay-task010.exe'
$script:certPath=Join-Path $project 'relay/test-cert/cert.pem'
$script:keyPath=Join-Path $project 'relay/test-cert/key.pem'

function Start-Relay {
    $script:relayRun++
    if(-not(Test-Path $script:relayBinary)){throw 'TASK010_RELAY_NOT_BUILT'}
    $dir=Join-Path $project 'relay'
    $argsList=@('-ctl','8443','-data','9000','-tokens','tokens.json')
    if($script:tlsMode){$argsList+=@('-cert','test-cert/cert.pem','-key','test-cert/key.pem')}
    $script:relay=Start-Process -FilePath $script:relayBinary -WorkingDirectory $dir -PassThru -WindowStyle Hidden -ArgumentList $argsList -RedirectStandardError (Join-Path $run ('relay-'+$script:relayRun+'-stderr.txt')) -RedirectStandardOutput (Join-Path $run ('relay-'+$script:relayRun+'-stdout.txt'))
    Wait-For {
        @((Get-NetTCPConnection -LocalPort 8443,9000 -State Listen -ErrorAction SilentlyContinue |
            Where-Object OwningProcess -eq $script:relay.Id)).Count -eq 2
    } 8 'RELAY_LISTEN_FAILED'
    Emit ('RELAY_STARTED round='+$script:relayRun+' tls='+$script:tlsMode)
}
function Provision-AgentCert {
    $package='br.net.qtscrcpy.agent'
    $remote='/sdcard/Download/qscnet-task010-cert.pem'
    Cmd-Adb @('push',$script:certPath,$remote)|Out-Null
    Cmd-Adb @('shell','run-as',$package,'mkdir','-p','files')|Out-Null
    Cmd-Adb @('shell','run-as',$package,'cp',$remote,'files/cert.pem')|Out-Null
    Cmd-Adb @('shell','run-as',$package,'chmod','600','files/cert.pem')|Out-Null
    if((Cmd-Adb @('shell','run-as',$package,'ls','-l','files/cert.pem')) -notmatch 'cert.pem'){throw 'AGENT_CERT_MISSING'}
    Emit 'P0_CERT_INSTALLED_TO_APP_PRIVATE_FILES=true'
}
function Qt-Tls-Count([string]$pattern){
    $f=Join-Path $run 'qt-process-stderr.txt'
    if(-not(Test-Path $f)){return 0}
    return @((Get-Content $f -ErrorAction SilentlyContinue)|Where-Object{$_ -match $pattern}).Count
}
function Relay-Log-Count([string]$pattern){
    $n=0
    foreach($f in @(Get-ChildItem $run -Filter 'relay-*-stdout.txt' -File -ErrorAction SilentlyContinue)){
        $n+=@((Get-Content $f.FullName -ErrorAction SilentlyContinue)|Where-Object{$_ -match $pattern}).Count
    }
    return $n
}
function Tls-Counts {
    $registered=Device-Count 'agent_registered device_id=phone-01'
    $captured=Device-Count 'capture_initialized width='
    $repaired=Qt-Tls-Count '^relay_reconnect ok$'
    $agentTls=Device-Count 'tls_enabled'
    $jitter=Qt-Tls-Count '^jitter_buffer_init capacity_ms=200$'
    Emit "P7_COUNTS agent_registered=$registered capture_initialized=$captured relay_reconnect_ok=$repaired tls_enabled=$agentTls jitter_init=$jitter"
    if($registered -ne 2 -or $captured -ne 1 -or $repaired -ne 1 -or $agentTls -lt 1 -or $jitter -lt 1){
        throw 'P7_COUNTS_MISMATCH'
    }
}

try {
    $deploy=Join-Path $client 'out/deploy'
    $binary=Join-Path $deploy 'QtScrcpy.exe'
    $tokensPath=Join-Path $project 'relay/tokens.json'
    if(-not(Test-Path $binary) -or -not(Test-Path $tokensPath)){throw 'LAB_ARTIFACT_MISSING'}
    $script:token=([IO.File]::ReadAllText($tokensPath)|ConvertFrom-Json).'phone-01'
    if($script:token -notmatch '^[A-Za-z0-9_-]+$'){throw 'TOKEN_FORMAT_INVALID'}
    if(@(Get-Process QtScrcpy -ErrorAction SilentlyContinue).Count){throw 'PREEXISTING_QT_INSTANCE'}
    if((Cmd-Adb @('get-state')) -ne 'device'){throw 'DEVICE_NOT_CONNECTED'}
    Begin-Phase 'P0'
    if((Cmd-Adb @('shell','dumpsys','activity','services','br.net.qtscrcpy.agent')) -match 'ServiceRecord\{[^\r\n]*MirrorService'){
        throw 'AGENT_ALREADY_ACTIVE'
    }
    Clear-StaleRelay
    if(@(Get-NetTCPConnection -LocalPort 8443,9000 -State Listen -ErrorAction SilentlyContinue).Count){throw 'RELAY_PORTS_PREEXISTING'}
    $generate=Start-Process -FilePath $script:relayBinary -WorkingDirectory (Join-Path $project 'relay') -ArgumentList '-gen-cert','test-cert' -RedirectStandardOutput (Join-Path $run 'cert-generate-stdout.txt') -RedirectStandardError (Join-Path $run 'cert-generate-stderr.txt') -WindowStyle Hidden -PassThru
    if(-not $generate.WaitForExit(20000)){throw 'CERT_GENERATION_TIMED_OUT'}
    $genExit=$generate.ExitCode
    if($null -eq $genExit){
        $genExit=if(@(Get-Content (Join-Path $run 'cert-generate-stdout.txt') -ErrorAction SilentlyContinue|Where-Object{$_ -match '^development TLS certificate created$'}).Count){0}else{1}
    }
    if($genExit -ne 0){throw 'CERT_GENERATION_FAILED'}
    if(-not(Test-Path $script:certPath) -or -not(Test-Path $script:keyPath)){throw 'CERT_FILES_MISSING'}
    Emit 'P0_CERT_GEN_EXIT=0'
    Provision-AgentCert
    Cmd-Adb @('logcat','-c')|Out-Null
    $script:logStartLocal=Get-Date
    $script:logcat=Start-Process -FilePath (Get-Command adb).Source -ArgumentList @(
        '-s',$Serial,'logcat','-T','1','-v','threadtime','-s','QscnetAgent:I'
    ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $androidLog
    Start-Sleep -Seconds 1
    Enable-Bridge
    Start-Relay
    Wait-For{(Relay-Log-Count 'tls=on') -ge 1} 8 'RELAY_TLS_NOT_ENABLED'
    Cmd-Adb @('reverse','tcp:8443','tcp:8443')|Out-Null
    Cmd-Adb @('reverse','tcp:9000','tcp:9000')|Out-Null
    End-Phase 'certificate generated; both TLS listeners active'

    Begin-Phase 'P1'
    Request-ApprovedSession
    Cmd-Adb @('shell','am','broadcast','-p','br.net.qtscrcpy.agent','-a','br.net.qtscrcpy.agent.PLAY_TONE','--ei','ms','30000')|Out-Null
    Wait-For{(Device-Count 'tone_play ms=30000') -ge 1} 5 'TONE_NOT_STARTED'
    $oldCert=$env:QSC_RELAY_CERT
    $oldDump=$env:QSC_AUDIO_DUMP
    try {
        $env:QSC_RELAY_CERT=$script:certPath
        $env:QSC_AUDIO_DUMP=Join-Path $run 'audio_tls.wav'
        $script:qt=Start-Process -FilePath $binary -WorkingDirectory $deploy -PassThru -RedirectStandardError (Join-Path $run 'qt-process-stderr.txt')
    } finally {
        $env:QSC_RELAY_CERT=$oldCert
        $env:QSC_AUDIO_DUMP=$oldDump
    }
    Wait-For{@(Get-QscMain $script:qt.Id).Count -eq 1} 12 'QT_MAIN_NOT_FOUND'
    Wait-For{try{Set-QscToken $script:qt.Id $script:token;$true}catch{$false}} 12 'QT_TOKEN_FIELD_NOT_READY'
    Invoke-QscConnect $script:qt.Id
    Wait-Video 20
    Wait-For{
        (Device-Count 'agent_registered device_id=phone-01') -ge 1 -and
        (Device-Count 'agent_paired width=') -ge 1 -and
        (Device-Count 'tls_enabled') -ge 1 -and
        (Device-Count 'audio_capturing sdk=29') -ge 1 -and
        (Qt-Tls-Count '^relay_tls_enabled$') -ge 1 -and
        (Qt-Tls-Count '^relay_tls_handshake_ok$') -ge 1 -and
        (Qt-Tls-Count '^audio_stream_open rate=') -ge 1 -and
        (Qt-Tls-Count '^jitter_buffer_init capacity_ms=200$') -ge 1 -and
        (Relay-Log-Count 'data connected session=') -ge 2
    } 30 'TLS_PAIR_AUDIO_MARKERS_INCOMPLETE'
    End-Phase 'agent and Qt paired over validated TLS with audio'

    Begin-Phase 'P2'
    Ensure-Awake
    Cmd-Adb @('shell','am','start','-a','android.settings.SETTINGS','-f','0x10008000')|Out-Null
    Wait-For{(Device-Count 'stream_frames=[1-9]\d*') -ge 1} 10 'VIDEO_FRAMES_NOT_FLOWING'
    End-Phase 'video frames over encrypted relay'

    Begin-Phase 'P3'
    Start-Sleep -Seconds 6
    $wav=Join-Path $run 'audio_tls.wav'
    if(-not(Test-Path $wav)){throw 'TLS_AUDIO_DUMP_MISSING'}
    # AudioStream reopens the same dump on TLS reconnection. Preserve the
    # successfully tested first connection as a separate, finalized WAV.
    $evidenceWav=Join-Path $run 'audio_tls_p3.wav'
    $reader=New-Object IO.FileStream ($wav,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $buffer=New-Object IO.MemoryStream
    try {
        $reader.CopyTo($buffer)
        $pcmBytes=$buffer.ToArray()
    } finally {
        $buffer.Dispose()
        $reader.Dispose()
    }
    if($pcmBytes.Length -lt 44){throw 'P3_DUMP_TOO_SHORT'}
    $sampleBytes=[uint32]($pcmBytes.Length-44)
    [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]($sampleBytes+36)),0,$pcmBytes,4,4)
    [Buffer]::BlockCopy([BitConverter]::GetBytes($sampleBytes),0,$pcmBytes,40,4)
    [IO.File]::WriteAllBytes($evidenceWav,$pcmBytes)
    Emit ('P3_EVIDENCE_WAV_BYTES='+$pcmBytes.Length)
    $analysis=@(& python (Join-Path $PSScriptRoot 'analyze_audio_tls.py') $evidenceWav 2>&1)
    $analysisExit=$LASTEXITCODE
    $analysis|Set-Content -Encoding UTF8 (Join-Path $run 'analysis.txt')
    foreach($line in $analysis){Emit ('RMS '+$line)}
    if($analysisExit -ne 0){throw 'RMS_CONTINUITY_FAILED'}
    Cmd-Adb @('shell','am','broadcast','-p','br.net.qtscrcpy.agent','-a','br.net.qtscrcpy.agent.STOP_TONE')|Out-Null
    End-Phase '200ms jitter buffer and uninterrupted 500ms RMS windows'

    Begin-Phase 'P4'
    $firstKilled=[DateTime]::UtcNow
    Stop-Relay
    Wait-For{(Device-Count 'stream_retry=1|stream_reregister=1') -ge 1 -and
        (Qt-Tls-Count '^relay_reconnect attempt=') -ge 1} 10 'TLS_DROP_NOT_DETECTED'
    Emit ('P4_DETECTED_SECONDS={0:F3}' -f ([DateTime]::UtcNow-$firstKilled).TotalSeconds)
    $restart=[DateTime]::UtcNow
    Start-Relay
    Wait-For{
        (Device-Count 'agent_registered device_id=phone-01') -ge 2 -and
        (Device-Count 'agent_paired width=') -ge 2 -and
        (Device-Count 'stream_repair_ok session=[0-9a-f]{8}') -ge 1 -and
        (Qt-Tls-Count '^relay_reconnect ok$') -eq 1 -and
        (Qt-Tls-Count '^audio_stream_open rate=') -ge 2 -and
        (Qt-Tls-Count '^relay_tls_handshake_ok$') -ge 2
    } 30 'TLS_REPAIR_MARKERS_MISSING'
    Emit ('P4_RECOVERED_SECONDS={0:F3}' -f ([DateTime]::UtcNow-$restart).TotalSeconds)
    Wait-Video 6
    Start-Sleep -Milliseconds 800
    $nonblack=Save-QscFrame $script:qt.Id (Join-Path $run 'S_rec.png')
    Emit ('P4_S_REC_NONBLACK={0:F4}' -f $nonblack)
    if($nonblack -lt 0.5){throw 'TLS_REPAIRED_VIDEO_BLACK'}
    End-Phase 'agent and Qt reconnected over TLS'

    Begin-Phase 'P5'
    $secondKilled=[DateTime]::UtcNow
    Stop-Relay
    Wait-For{Qt-Log-Has 'Remote stream disconnected for relay/phone-01' $secondKilled} 60 'PERMANENT_RELAY_FAILURE_NOT_HANDLED'
    Emit ('P5_CLIENT_TIMEOUT_SECONDS={0:F3}' -f ([DateTime]::UtcNow-$secondKilled).TotalSeconds)
    Wait-For{(Device-Count 'service_stopped sent_frames=\d+|Conexão perdida após reconexão de registro') -ge 1} 45 'AGENT_NOT_STOPPED'
    Wait-Closed 8
    End-Phase 'permanent relay loss terminal'

    Begin-Phase 'P6'
    $script:tlsMode=$false
    Start-Relay
    Wait-For{(Relay-Log-Count 'tls=off') -ge 1} 8 'PLAINTEXT_COMPAT_RELAY_FAILED'
    $smoke=Join-Path $deploy 'transport-smoke.exe'
    $smokeOutput=Join-Path $run 'adb-forward.txt'
    $smokeError=Join-Path $run 'adb-forward-stderr.txt'
    $argsText='"'+$deploy+'" '+$Serial+' forward'
    $smokeProcess=Start-Process -FilePath $smoke -ArgumentList $argsText -WorkingDirectory $deploy -PassThru -WindowStyle Hidden -RedirectStandardOutput $smokeOutput -RedirectStandardError $smokeError
    if(-not $smokeProcess.WaitForExit(30000)){Stop-Process -Id $smokeProcess.Id -Force -ErrorAction SilentlyContinue;throw 'ADB_SMOKE_TIMEOUT'}
    $smokeExit=$smokeProcess.ExitCode
    if($null -eq $smokeExit){
        $smokeExit=if(@(Get-Content $smokeOutput,$smokeError -ErrorAction SilentlyContinue|Where-Object{$_ -match '^SMOKE_EXIT 0$'}).Count){0}else{5}
    }
    Emit ('P6_ADB_FORWARD_EXIT='+$smokeExit)
    if($smokeExit -eq 5){
        # Previous physical runs established that a first forward attempt can
        # transiently fail on this LG while the next awake attempt succeeds.
        Ensure-Awake
        $retryOut=Join-Path $run 'adb-forward-retry.txt'
        $retryErr=Join-Path $run 'adb-forward-retry-stderr.txt'
        $p=Start-Process -FilePath $smoke -ArgumentList $argsText -WorkingDirectory $deploy -PassThru -WindowStyle Hidden -RedirectStandardOutput $retryOut -RedirectStandardError $retryErr
        if(-not $p.WaitForExit(30000)){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;throw 'ADB_SMOKE_RETRY_TIMEOUT'}
        $smokeExit=$p.ExitCode
        if($null -eq $smokeExit){
            $smokeExit=if(@(Get-Content $retryOut,$retryErr -ErrorAction SilentlyContinue|Where-Object{$_ -match '^SMOKE_EXIT 0$'}).Count){0}else{5}
        }
        Emit ('P6_ADB_FORWARD_RETRY_EXIT='+$smokeExit)
    }
    if($smokeExit -ne 0){throw 'ADB_PLAINTEXT_PARITY_FAILED'}
    Stop-Relay
    End-Phase 'plain relay backward compatible and ADB exit 0'

    Begin-Phase 'P7'
    Tls-Counts
    End-Phase 'TLS and jitter markers and counts'
    $script:exitCode=0
} catch {
    $reason=$_.Exception.Message -replace '[\r\n]+',' '
    if($reason -match 'OWNER_TAP_REQUIRED'){$script:exitCode=4}
    Emit ($script:phase+'_FAIL '+$reason)
} finally {
    try{Cmd-Adb @('shell','am','broadcast','-p','br.net.qtscrcpy.agent','-a','br.net.qtscrcpy.agent.STOP_TONE')|Out-Null}catch{}
    if($script:logcat -and -not $script:logcat.HasExited){
        Stop-Process -Id $script:logcat.Id -Force -ErrorAction SilentlyContinue
    }
    if($script:qt -and -not $script:qt.HasExited){
        try{
            foreach($w in (Get-QscWindows $script:qt.Id)){
                [void][QscUiLab]::PostMessage($w.Handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)
            }
            if(-not $script:qt.WaitForExit(2500)){Stop-Process -Id $script:qt.Id -Force -ErrorAction SilentlyContinue}
        }catch{Emit 'QT_SHUTDOWN_FAILED'}
    }
    try{Stop-Relay}catch{Emit 'RELAY_SHUTDOWN_FAILED'}
    try{Cmd-Adb @('shell','run-as','br.net.qtscrcpy.agent','rm','-f','files/cert.pem')|Out-Null}catch{}
    try{Cmd-Adb @('shell','rm','-f','/sdcard/Download/qscnet-task010-cert.pem')|Out-Null}catch{}
    foreach($f in @(Get-ChildItem $run -Filter 'relay-*-stdout.txt' -File -ErrorAction SilentlyContinue)){
        $rawText=[IO.File]::ReadAllText($f.FullName)
        $safe=[regex]::Replace($rawText,'(?i)\b[a-f0-9]{64}\b','<session-redacted>')
        [IO.File]::WriteAllText($f.FullName,$safe,(New-Object Text.UTF8Encoding($false)))
    }
    Emit ('TASK010_HARNESS_EXIT='+$script:exitCode)
}
exit $script:exitCode
