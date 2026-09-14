using System.Runtime.InteropServices;

namespace DshNotchWin;

/// <summary>
/// Win32 surface needed by the capsule window. See PLAN.md §7.2 for the
/// mapping against the macOS APIs it replaces (NSPanel / NSScreen / NSEvent).
/// </summary>
internal static class NativeMethods
{
    // ---- window styles -------------------------------------------------
    internal const int GWL_EXSTYLE = -20;

    internal const int WS_EX_TOPMOST = 0x00000008;
    internal const int WS_EX_TRANSPARENT = 0x00000020;
    internal const int WS_EX_TOOLWINDOW = 0x00000080;
    internal const int WS_EX_LAYERED = 0x00080000;
    internal const int WS_EX_NOACTIVATE = 0x08000000;

    internal static readonly IntPtr HWND_TOPMOST = new(-1);
    internal static readonly IntPtr HWND_NOTOPMOST = new(-2);

    internal const uint SWP_NOSIZE = 0x0001;
    internal const uint SWP_NOMOVE = 0x0002;
    internal const uint SWP_NOZORDER = 0x0004;
    internal const uint SWP_NOACTIVATE = 0x0010;
    internal const uint SWP_FRAMECHANGED = 0x0020;
    internal const uint SWP_SHOWWINDOW = 0x0040;

    // ---- monitors ------------------------------------------------------
    internal const uint MONITOR_DEFAULTTONEAREST = 2;

    // ---- accessibility -------------------------------------------------
    internal const uint SPI_GETCLIENTAREAANIMATION = 0x1042;

    // ---- DWM -----------------------------------------------------------
    internal const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    internal const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    internal const int DWMWCP_ROUND = 2;
    internal const int DWMSBT_MAINWINDOW = 2;      // Mica
    internal const int DWMSBT_TRANSIENTWINDOW = 3; // Acrylic

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    internal static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    internal static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    internal static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    internal static extern IntPtr SetCapture(IntPtr hWnd);

    [DllImport("user32.dll")]
    internal static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    internal static extern IntPtr GetCapture();

    [DllImport("user32.dll")]
    internal static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    [DllImport("user32.dll")]
    internal static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    internal static extern bool SetForegroundWindow(IntPtr hWnd);

    // ---- keyboard focus borrowing --------------------------------------
    // The capsule is WS_EX_NOACTIVATE, so a click never makes it the foreground
    // window and keystrokes keep going to the app the user was in. Answering a
    // question by typing therefore needs a temporary activation: the answer field
    // asks for the keyboard, gets it, and gives it back on blur (PLAN.md §7.2).
    [DllImport("user32.dll")]
    internal static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll")]
    internal static extern IntPtr GetFocus();

    [DllImport("user32.dll")]
    internal static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    internal static extern uint GetCurrentThreadId();

    // ---- window enumeration (bringing DSH forward on a row click) -------
    internal const uint GW_OWNER = 4;

    internal delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    internal static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    internal static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    internal static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    /// <summary>Posts a message. Used instead of Control.BeginInvoke by the
    /// animation thread: the message loop is already running, and this needs no
    /// managed state on the UI thread to be in a particular state to be safe.</summary>
    [DllImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    internal static extern bool PostMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    internal static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern bool SystemParametersInfo(
        uint uiAction, uint uiParam, out bool pvParam, uint fWinIni);

    [DllImport("gdi32.dll")]
    internal static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);

    // ---- window regions -------------------------------------------------
    // The capsule silhouette is assembled from plain rectangles rather than a
    // path: the region is rebuilt on every animation frame, and CreateRectRgn +
    // CombineRgn is far cheaper than a GraphicsPath plus GetHrgn per frame.
    internal const int RGN_OR = 2;

    [DllImport("gdi32.dll")]
    internal static extern IntPtr CreateRectRgn(int x1, int y1, int x2, int y2);

    [DllImport("gdi32.dll")]
    internal static extern int CombineRgn(IntPtr hrgnDst, IntPtr hrgnSrc1, IntPtr hrgnSrc2, int iMode);

    [DllImport("gdi32.dll")]
    internal static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll")]
    internal static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);

    [DllImport("user32.dll")]
    internal static extern int GetWindowRgnBox(IntPtr hWnd, out RECT lprc);

    [DllImport("user32.dll")]
    internal static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    internal static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

    [DllImport("user32.dll")]
    internal static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    internal const uint GA_ROOT = 2;

    // ---- window class style -------------------------------------------
    internal const int GCL_STYLE = -26;
    internal const int CS_DROPSHADOW = 0x00020000;

    [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW", SetLastError = true)]
    internal static extern IntPtr GetClassLongPtr(IntPtr hWnd, int nIndex);

    // ---- timer resolution ---------------------------------------------
    // SetTimer (which WinForms' Timer uses) is quantised to the system timer
    // tick, so a 50 ms hover poll also caps any drag at ~20 updates/second.
    // Raising the resolution for the duration of a drag makes pointer tracking
    // feel attached to the cursor; it is restored immediately afterwards.
    [DllImport("winmm.dll", EntryPoint = "timeBeginPeriod")]
    internal static extern uint TimeBeginPeriod(uint uMilliseconds);

    [DllImport("winmm.dll", EntryPoint = "timeEndPeriod")]
    internal static extern uint TimeEndPeriod(uint uMilliseconds);

    [DllImport("dwmapi.dll")]
    internal static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [DllImport("kernel32.dll")]
    internal static extern bool AttachConsole(int dwProcessId);

    internal const int VK_LBUTTON = 0x01;

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    /// <summary>Physical left-button state. Polling this instead of relying on a
    /// mouse-up message means a drag still ends correctly when the button is
    /// released outside the capsule (the window holds no capture, since it is
    /// deliberately non-activating).</summary>
    internal static bool LeftButtonDown() => (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;

    [DllImport("shcore.dll")]
    private static extern int GetProcessDpiAwareness(IntPtr hProcess, out uint value);

    /// <summary>PROCESS_DPI_AWARENESS: 0 = unaware, 1 = system aware,
    /// 2 = per-monitor aware. 98/99 are the probe's own failure codes.</summary>
    internal static uint ProcessDpiAwareness()
    {
        try
        {
            return GetProcessDpiAwareness(IntPtr.Zero, out uint value) == 0 ? value : 99;
        }
        catch
        {
            return 98; // shcore unavailable
        }
    }

    /// <summary>Reads "Show animations in Windows" (Settings → Accessibility → Visual effects).
    /// The macOS equivalent upstream reads is <c>accessibilityDisplayShouldReduceMotion</c>.</summary>
    internal static bool ClientAreaAnimationEnabled()
    {
        return !SystemParametersInfo(SPI_GETCLIENTAREAANIMATION, 0, out bool enabled, 0) || enabled;
    }
}
