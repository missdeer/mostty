using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PaneAcceptance {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct KI { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct MI { public int x, y; public uint data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] public struct U { [FieldOffset(0)] public KI key; [FieldOffset(0)] public MI mouse; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public U u; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr root, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int cap);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint msg, UIntPtr wp, IntPtr lp);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x,y; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
    [StructLayout(LayoutKind.Sequential)] public struct GUIINFO { public uint size,flags; public IntPtr active,focus,capture,menu,movesize,caret; public RECT caretRect; }
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread,ref GUIINFO info);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeoutW(IntPtr hwnd,uint msg,UIntPtr wp,IntPtr lp,uint flags,uint timeout,out UIntPtr result);
    public static RECT Box(IntPtr hwnd) { RECT r; if(!GetWindowRect(hwnd,out r))throw new Exception("Missing window");return r; }
    public static IntPtr Focus(IntPtr root) {uint pid;var thread=GetWindowThreadProcessId(root,out pid);var info=new GUIINFO{size=(uint)Marshal.SizeOf<GUIINFO>()};if(!GetGUIThreadInfo(thread,ref info))throw new Exception("No GUI thread state");return info.focus;}
    public static void Responsive(IntPtr root) { UIntPtr result; if(SendMessageTimeoutW(root,0,UIntPtr.Zero,IntPtr.Zero,2,500,out result)==IntPtr.Zero)throw new Exception("UI did not respond within 500 ms"); }
    public delegate bool MonitorProc(IntPtr monitor,IntPtr dc,ref RECT rect,IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr dc,IntPtr clip,MonitorProc callback,IntPtr data);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor,int type,out uint x,out uint y);
    public sealed class MonitorInfo {public int Left,Top,Right,Bottom;public uint Dpi;}
    public static MonitorInfo[] Monitors(){var result=new List<MonitorInfo>();EnumDisplayMonitors(IntPtr.Zero,IntPtr.Zero,(IntPtr h,IntPtr dc,ref RECT r,IntPtr d)=>{uint x,y;GetDpiForMonitor(h,0,out x,out y);result.Add(new MonitorInfo{Left=r.Left,Top=r.Top,Right=r.Right,Bottom=r.Bottom,Dpi=x});return true;},IntPtr.Zero);return result.ToArray();}
    public static void Wheel(IntPtr root,int pid,IntPtr pane,int delta) {
        var box=Box(pane);var point=new POINT{x=box.Left+35,y=box.Top+60};uint actual;
        GetWindowThreadProcessId(WindowFromPoint(point),out actual);if(actual!=pid)throw new Exception("Wheel target is outside test process");
        SetCursorPos(point.x,point.y);var input=new INPUT[1];input[0].u.mouse.flags=0x800;input[0].u.mouse.data=unchecked((uint)delta);
        if(SendInput(1,input,Marshal.SizeOf<INPUT>())!=1)throw new Exception("Wheel injection failed");
        System.Threading.Thread.Sleep(200);Responsive(root);
    }
    public static void CapturedTabSwitch(IntPtr root,int pid,IntPtr pane) {
        var box=Box(pane);var point=new POINT{x=box.Left+25,y=box.Top+30};uint actual;
        GetWindowThreadProcessId(WindowFromPoint(point),out actual);if(actual!=pid)throw new Exception("Capture target is outside test process");
        SetCursorPos(point.x,point.y);var input=new INPUT[1];input[0].u.mouse.flags=2;
        if(SendInput(1,input,Marshal.SizeOf<INPUT>())!=1)throw new Exception("Capture press failed");
        System.Threading.Thread.Sleep(150);
        try{Chord(root,pid,new int[]{0x11,0x09});System.Threading.Thread.Sleep(300);}
        finally{input[0].u.mouse.flags=4;SendInput(1,input,Marshal.SizeOf<INPUT>());}
        System.Threading.Thread.Sleep(150);
    }
    public static void Drag(IntPtr root,int pid,int x,int y,int destX,int destY) {
        uint actual; GetWindowThreadProcessId(WindowFromPoint(new POINT{x=x,y=y}),out actual);
        if(actual!=pid)throw new Exception("Refusing drag outside test window");
        SetCursorPos(x,y);System.Threading.Thread.Sleep(50);
        var input=new INPUT[1];input[0].u.mouse.flags=2;
        if(SendInput(1,input,Marshal.SizeOf<INPUT>())!=1)throw new Exception("Mouse down failed");
        try {for(int i=1;i<=12;i++){SetCursorPos(x+(destX-x)*i/12,y+(destY-y)*i/12);System.Threading.Thread.Sleep(20);Responsive(root);}}
        finally {input[0].u.mouse.flags=4;SendInput(1,input,Marshal.SizeOf<INPUT>());}
        System.Threading.Thread.Sleep(150);
    }
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    public static string Class(IntPtr hwnd) { var s = new StringBuilder(128); GetClassName(hwnd,s,s.Capacity); return s.ToString(); }
    public static IntPtr Root(int pid) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((h,d)=> { uint p; GetWindowThreadProcessId(h,out p); if(p==pid && Class(h)=="MosttyWindow") { result=h; return false; } return true; },IntPtr.Zero);
        return result;
    }
    public static IntPtr[] Panes(IntPtr root) {
        var result = new List<IntPtr>();
        EnumChildWindows(root,(h,d)=> { if(Class(h)=="MosttyPane" && IsWindowVisible(h)) result.Add(h); return true; },IntPtr.Zero);
        result.Sort((a,b)=> {RECT x,y; GetWindowRect(a,out x);GetWindowRect(b,out y);int c=x.Left.CompareTo(y.Left);return c!=0?c:x.Top.CompareTo(y.Top);});
        return result.ToArray();
    }
    [DllImport("imm32.dll")] public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hwnd);
    public static long ImeControl(IntPtr pane,int command,long value) {
        var ime=ImmGetDefaultIMEWnd(pane);if(ime==IntPtr.Zero)throw new Exception("No default IME window");
        UIntPtr result;
        if(SendMessageTimeoutW(ime,0x283,(UIntPtr)command,new IntPtr(value),2,2000,out result)==IntPtr.Zero)throw new Exception("IME control timed out");
        return (long)result.ToUInt64();
    }
    [DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int n,[Out]IntPtr[] layouts);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint thread);
    public static IntPtr ChineseLayout() {
        var layouts=new IntPtr[GetKeyboardLayoutList(0,null)];GetKeyboardLayoutList(layouts.Length,layouts);
        foreach(var layout in layouts)if((layout.ToInt64()&0xffff)==0x804)return layout;
        return IntPtr.Zero;
    }
    public static IntPtr Layout(IntPtr root) {uint pid;return GetKeyboardLayout(GetWindowThreadProcessId(root,out pid));}
    public static void ClickPane(IntPtr root,int pid,IntPtr pane,int localX,int localY) {
        var r=Box(pane);int x=r.Left+localX,y=r.Top+localY;
        uint actual;GetWindowThreadProcessId(WindowFromPoint(new POINT{x=x,y=y}),out actual);
        if(actual!=pid)throw new Exception("Refusing click outside test process");
        SetCursorPos(x,y);var input=new INPUT[2];input[0].u.mouse.flags=2;input[1].u.mouse.flags=4;
        if(SendInput(2,input,Marshal.SizeOf<INPUT>())!=2)throw new Exception("Click failed");
        System.Threading.Thread.Sleep(150);
        if(Focus(root)!=pane)throw new Exception("Pane click did not focus its HWND");
    }
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd,StringBuilder text,int capacity);
    public static string Text(IntPtr hwnd){var text=new StringBuilder(2048);GetWindowText(hwnd,text,text.Capacity);return text.ToString();}
    public static IntPtr Dialog(int pid){IntPtr found=IntPtr.Zero;EnumWindows((h,d)=>{uint p;GetWindowThreadProcessId(h,out p);if(p==pid&&Class(h)=="#32770"&&IsWindowVisible(h)){found=h;return false;}return true;},IntPtr.Zero);return found;}
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetSystemMenu(IntPtr window,bool revert);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr menu,int position);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu,uint item,StringBuilder text,int capacity,uint flags);
    public static void MenuCommand(IntPtr window,string label){
        var menu=GetSystemMenu(window,false);for(int i=0;i<GetMenuItemCount(menu);i++){
            var text=new StringBuilder(256);GetMenuString(menu,(uint)i,text,text.Capacity,0x400);
            if(text.ToString().Split('\t')[0]==label){if(!PostMessageW(window,0x112,(UIntPtr)GetMenuItemID(menu,i),IntPtr.Zero))throw new Exception("System menu command failed");return;}
        }throw new Exception("System menu entry missing: "+label);
    }
    public static void ClickDialogButton(IntPtr dialog,int wanted) {
        IntPtr button=IntPtr.Zero;EnumChildWindows(dialog,(h,d)=>{if(Class(h)=="Button"&&GetDlgCtrlID(h)==wanted){button=h;return false;}return true;},IntPtr.Zero);
        if(button==IntPtr.Zero)throw new Exception("Requested dialog button was not found");
        if(!PostMessageW(button,0xf5,UIntPtr.Zero,IntPtr.Zero))throw new Exception("Dialog button click failed");
    }
    public static string DialogText(IntPtr hwnd){var text=new StringBuilder();text.AppendLine(Text(hwnd));EnumChildWindows(hwnd,(h,d)=>{text.AppendLine(Class(h)+" #"+GetDlgCtrlID(h)+" "+Text(h));return true;},IntPtr.Zero);return text.ToString();}
    public static void Activate(IntPtr root, int pid) {
        SetForegroundWindow(root);
        System.Threading.Thread.Sleep(100);
        uint current; GetWindowThreadProcessId(GetForegroundWindow(),out current);
        if(current==pid) return;
        RECT r; GetWindowRect(root,out r);
        var p=new POINT{x=r.Left+100,y=r.Top+16};
        uint under; GetWindowThreadProcessId(WindowFromPoint(p),out under);
        if(under!=pid) throw new Exception("Test window title bar is occluded; refusing activation click");
        SetCursorPos(p.x,p.y);
        var clicks=new INPUT[2];clicks[0].u.mouse.flags=2;clicks[1].u.mouse.flags=4;
        if(SendInput(2,clicks,Marshal.SizeOf<INPUT>())!=2) throw new Exception("Activation click failed");
        System.Threading.Thread.Sleep(200);
    }
    public static void Chord(IntPtr root, int pid, int[] keys) {
        uint actual; GetWindowThreadProcessId(GetForegroundWindow(),out actual);
        if(actual!=pid) throw new Exception("Refusing keyboard input outside the test process");
        var inputs = new INPUT[keys.Length*2];
        for(int i=0;i<keys.Length;i++) {
            inputs[i].type=1;inputs[i].u.key.vk=(ushort)keys[i];
            inputs[keys.Length+i].type=1;inputs[keys.Length+i].u.key.vk=(ushort)keys[keys.Length-1-i];inputs[keys.Length+i].u.key.flags=2;
        }
        if(SendInput((uint)inputs.Length,inputs,Marshal.SizeOf<INPUT>())!=inputs.Length) throw new Exception("SendInput failed");
    }
}
