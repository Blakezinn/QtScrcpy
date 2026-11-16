# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0 (the "License").
# You may obtain a copy of the License at https://www.apache.org/licenses/LICENSE-2.0
# Distributed on an "AS IS" basis, without warranties or conditions.
# Window enumeration and UIAutomation shared by the TASK-006 laboratory.
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class QscUiLab {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left,Top,Right,Bottom; }
  public sealed class Entry {
    public IntPtr Handle;
    public string Title;
    public int Left,Top,Right,Bottom;
  }
  public delegate bool EnumFn(IntPtr h,IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumFn f,IntPtr p);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint msg,IntPtr w,IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public static List<Entry> Windows(uint target) {
    var all=new List<Entry>();
    EnumFn cb=(h,p)=>{
      uint actual;
      GetWindowThreadProcessId(h,out actual);
      if(actual!=target || !IsWindowVisible(h))return true;
      var s=new StringBuilder(512);
      GetWindowTextW(h,s,s.Capacity);
      RECT r;
      if(!GetWindowRect(h,out r))return true;
      if(r.Right-r.Left<80 || r.Bottom-r.Top<80)return true;
      all.Add(new Entry{Handle=h,Title=s.ToString(),Left=r.Left,Top=r.Top,
                        Right=r.Right,Bottom=r.Bottom});
      return true;
    };
    EnumWindows(cb,IntPtr.Zero);
    GC.KeepAlive(cb);
    return all;
  }
}
'@

function Get-QscWindows([int]$id) {
    return @([QscUiLab]::Windows([uint32]$id))
}
function Get-QscVideo([int]$id) {
    return @(Get-QscWindows $id | Where-Object { $_.Title -like '*relay/phone-01*' })
}
function Get-QscMain([int]$id) {
    return @(Get-QscWindows $id | Where-Object { $_.Title -notlike '*relay/phone-01*' } | Sort-Object {($_.Right-$_.Left)*($_.Bottom-$_.Top)} -Descending | Select-Object -First 1)
}
function Find-QscElement($parent, [string]$name, [string]$kind) {
    $type = switch ($kind) {
        'Button' { [System.Windows.Automation.ControlType]::Button }
        'Edit' { [System.Windows.Automation.ControlType]::Edit }
        'Group' { [System.Windows.Automation.ControlType]::Group }
        default { throw 'Unsupported automation control' }
    }
    $parts = @(
        (New-Object System.Windows.Automation.PropertyCondition -ArgumentList ([System.Windows.Automation.AutomationElement]::ControlTypeProperty,$type)),
        (New-Object System.Windows.Automation.OrCondition -ArgumentList @(
            (New-Object System.Windows.Automation.PropertyCondition -ArgumentList ([System.Windows.Automation.AutomationElement]::NameProperty,$name)),
            (New-Object System.Windows.Automation.PropertyCondition -ArgumentList ([System.Windows.Automation.AutomationElement]::AutomationIdProperty,$name))
        ))
    )
    $filter=New-Object System.Windows.Automation.AndCondition -ArgumentList $parts
    return $parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$filter)
}
function Get-QscAutomation([int]$id) {
    $win=@(Get-QscMain $id | Select-Object -First 1)
    if($win.Count -ne 1) {throw 'QtScrcpy main window not found'}
    return [System.Windows.Automation.AutomationElement]::FromHandle($win[0].Handle)
}
function Set-QscInput($element, [string]$value) {
    if($null -eq $element){throw 'Token input missing'}
    $element.SetFocus()
    try {
        $pattern=$element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $pattern.SetValue($value)
    } catch {
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        foreach($ch in $value.ToCharArray()) {
            $c=[string]$ch
            if('+^%~(){}[]'.Contains($c)){$c='{'+$c+'}'}
            [System.Windows.Forms.SendKeys]::SendWait($c)
        }
    }
}
function Invoke-QscConnect([int]$id) {
    $root=Get-QscAutomation $id
    $button=Find-QscElement $root 'relayConnectButton' 'Button'
    if($null -eq $button){$button=Find-QscElement $root 'Conectar remoto' 'Button'}
    if($null -eq $button){throw 'Conectar remoto button missing from UI Automation'}
    $pattern=$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
}
function Set-QscToken([int]$id, [string]$token) {
    $root=Get-QscAutomation $id
    $input=Find-QscElement $root 'relayTokenEdit' 'Edit'
    if($null -eq $input) {
        $group=Find-QscElement $root 'Conectar remoto' 'Group'
        if($null -ne $group) {
            $filter=New-Object System.Windows.Automation.PropertyCondition -ArgumentList ([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Edit)
            $items=$group.FindAll([System.Windows.Automation.TreeScope]::Descendants,$filter)
            if($items.Count -ge 3) {$input=$items.Item($items.Count-1)}
        }
    }
    Set-QscInput $input $token
}
function Close-QscVideo([int]$id) {
    $wins=@(Get-QscVideo $id)
    if($wins.Count -ne 1){throw "Expected exactly one video window; got $($wins.Count)"}
    if(-not [QscUiLab]::PostMessage($wins[0].Handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)) {
        throw 'WM_CLOSE could not be posted'
    }
}
function Save-QscFrame([int]$id, [string]$dest) {
    $wins=@(Get-QscVideo $id)
    if($wins.Count -ne 1){throw "Expected one window during capture, got $($wins.Count)"}
    $w=$wins[0]
    $width=$w.Right-$w.Left
    $height=$w.Bottom-$w.Top
    if($width -lt 100 -or $height -lt 150){throw 'Video bounds too small'}
    [void][QscUiLab]::SetForegroundWindow($w.Handle)
    Start-Sleep -Milliseconds 200
    $bitmap=New-Object System.Drawing.Bitmap($width,$height)
    $graphics=[System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($w.Left,$w.Top,0,0,$bitmap.Size)
        $bitmap.Save($dest,[System.Drawing.Imaging.ImageFormat]::Png)
        $total=0; $active=0
        # Exclude window decorations; sample an inner video rectangle.
        for($y=42;$y -lt $height-35;$y+=10) {
            for($x=20;$x -lt $width-20;$x+=10) {
                $color=$bitmap.GetPixel($x,$y)
                $total++
                if($color.R -gt 30 -or $color.G -gt 30 -or $color.B -gt 30){$active++}
            }
        }
        return [math]::Round($active/[math]::Max(1,$total),4)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}
