# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0.
# Windows SendInput helpers for the physical Qt video window.
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class QscWinInput {
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT {
        public uint type;
        public BODY body;
    }
    [StructLayout(LayoutKind.Explicit)]
    struct BODY {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT key;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT {
        public ushort vk;
        public ushort scan;
        public uint flags;
        public uint time;
        public IntPtr extra;
    }
    [DllImport("user32.dll",SetLastError=true)]
    static extern uint SendInput(uint count, INPUT[] input, int byteSize);
    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll",SetLastError=true)]
    static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,
        int x,int y,int width,int height,uint flags);
    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int x, y; }
    [DllImport("user32.dll")]
    static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")]
    static extern IntPtr GetAncestor(IntPtr hwnd,uint flags);
    const uint MOUSE = 0, KEYBOARD = 1;
    const uint MOVE = 1, DOWN = 2, UP = 4, WHEEL = 0x800, ABS = 0x8000, VIRTUAL = 0x4000;
    const uint KEY_UP = 2, UNICODE = 4;
    public static void BringToFront(IntPtr hwnd) {
        // Avoid screenshots and pointer events landing in another visible
        // tool window that overlaps the upper half of the device video.
        if (!SetWindowPos(hwnd, new IntPtr(-1), 0,0,0,0,
                0x0001 | 0x0002 | 0x0040)) {
            throw new InvalidOperationException("Cannot expose video window");
        }
        SetForegroundWindow(hwnd);
    }
    public static bool AcceptsInput(IntPtr hwnd,int x,int y) {
        POINT p=new POINT { x=x, y=y };
        IntPtr at=WindowFromPoint(p);
        return at!=IntPtr.Zero
            && GetAncestor(at,2)==hwnd
            && GetForegroundWindow()==hwnd;
    }

    static void Submit(INPUT input) {
        if (SendInput(1, new INPUT[]{input}, Marshal.SizeOf(typeof(INPUT))) != 1) {
            throw new InvalidOperationException("SendInput rejected event");
        }
    }
    static INPUT Mouse(uint flags, int x=0, int y=0, uint data=0) {
        INPUT i = new INPUT();
        i.type = MOUSE;
        i.body.mouse.dx = x; i.body.mouse.dy = y;
        i.body.mouse.flags = flags; i.body.mouse.mouseData = data;
        return i;
    }
    public static void MoveCursor(int x, int y) {
        int left=GetSystemMetrics(76), top=GetSystemMetrics(77);
        int width=Math.Max(1,GetSystemMetrics(78)), height=Math.Max(1,GetSystemMetrics(79));
        int nx=(int)Math.Round((x-left)*65535.0/(width-1));
        int ny=(int)Math.Round((y-top)*65535.0/(height-1));
        Submit(Mouse(MOVE | ABS | VIRTUAL,nx,ny));
    }
    public static void Tap(int x,int y,int holdMs=50) {
        MoveCursor(x,y);
        Thread.Sleep(60);
        Submit(Mouse(DOWN));
        Thread.Sleep(holdMs);
        Submit(Mouse(UP));
    }
    public static void Drag(int x1,int y1,int x2,int y2,int durationMs=700) {
        MoveCursor(x1,y1);
        Thread.Sleep(50);
        Submit(Mouse(DOWN));
        const int steps=14;
        for (int i=1;i<=steps;i++) {
            int x=(int)Math.Round(x1+(x2-x1)*(i/(double)steps));
            int y=(int)Math.Round(y1+(y2-y1)*(i/(double)steps));
            MoveCursor(x,y);
            Thread.Sleep(Math.Max(1,durationMs/steps));
        }
        Submit(Mouse(UP));
    }
    public static void WheelDown(int amount=5) {
        for (int i=0;i<amount;i++) {
            Submit(Mouse(WHEEL,0,0,unchecked((uint)-120)));
            Thread.Sleep(120);
        }
    }
    static void Key(ushort vk,uint flags) {
        INPUT i=new INPUT();
        i.type=KEYBOARD;
        i.body.key.vk=vk;
        i.body.key.flags=flags;
        Submit(i);
    }
    public static void UnicodeChar(char value) {
        INPUT down=new INPUT(), up=new INPUT();
        down.type=KEYBOARD;
        down.body.key.scan=value;
        down.body.key.flags=UNICODE;
        up=down;
        up.body.key.flags=UNICODE | KEY_UP;
        Submit(down);
        Thread.Sleep(70);
        Submit(up);
    }
    public static void Shortcut(char letter) {
        Key(0x11,0); // Ctrl down
        ushort value=(ushort)Char.ToUpperInvariant(letter);
        Key(value,0);
        Thread.Sleep(65);
        Key(value,KEY_UP);
        Key(0x11,KEY_UP);
    }
}
'@
