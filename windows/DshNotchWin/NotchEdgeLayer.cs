using System.Drawing;

namespace DshNotchWin;

/// <summary>
/// The capsule's antialiased free edge, painted by a second, click-through,
/// layered window that lives directly under the capsule.
///
/// WHY THIS EXISTS: the capsule's shape comes from a window region
/// (<see cref="NotchWindow.ApplyRegion"/>), and a region is a binary mask —
/// SetWindowRgn has no partial coverage, so the rounded corners it cuts are
/// stair-stepped against the desktop (measured: a corner row moves outward in
/// whole pixels, and every boundary pixel is either the capsule's own fill or the
/// desktop, never a blend). Windows offers per-pixel alpha for a top-level window
/// only through WS_EX_LAYERED + UpdateLayeredWindow, which needs the content as a
/// bitmap the process supplies; a WebView2 child window paints its own pixels and
/// cannot contribute to a layered surface, so the capsule itself can never be
/// layered. Nor can the shape simply be handed to the page: WebView2's
/// "transparent" background composites against the window's own surface, so a CSS
/// border-radius there produces black fringes, not coverage against the desktop.
///
/// So the work is split in two. The capsule window keeps its region — which is
/// what shapes it AND what decides hit-testing — and this band supplies exactly
/// the pixels the region must not claim: the region is built from whole pixels
/// (a partially covered pixel is never inside it), and the band paints those
/// pixels with their real coverage. Composited, the two are the ideal silhouette.
///
/// The band covers the FREE side only. The attached side is flush with the screen
/// edge and the top and bottom edges are axis-aligned, and an axis-aligned edge
/// has nothing to antialias; only the two quarter-circle corners do.
/// </summary>
internal sealed class NotchEdgeLayer : IDisposable
{
    private const string ClassName = "DshNotchWinEdgeBand";

    /// <summary>Supersampling per axis inside one pixel. 8 gives 65 alpha levels,
    /// which is far finer than the eye can resolve on a 1 px black-to-desktop
    /// ramp, and costs ~1 ms for a whole band even when every corner pixel is
    /// resampled.</summary>
    private const int Samples = 8;

    private static bool _classRegistered;
    private static NativeMethods.WndProcDelegate? _procKeepAlive;

    private IntPtr _hwnd;
    private IntPtr _memDc;
    private IntPtr _dib;
    private IntPtr _oldBitmap = IntPtr.Zero;
    private IntPtr _bits = IntPtr.Zero;
    private int _bufW;
    private int _bufH;

    /// <summary>What the current bitmap was rasterised for. A pure move (a drag)
    /// must not re-rasterise: the band's pixels only depend on the capsule's
    /// size, radius and edge, none of which a drag changes.</summary>
    private (int Width, int Height, int Radius, bool AttachedRight) _raster;

    private readonly Color _fill;

    /// <summary>The band is placed from the UI thread (a resize, a collapse, the
    /// self-test) and moved from the geometry animation's own thread (every frame
    /// of one), so the bitmap and the window are serialised behind one gate
    /// instead of being assumed single-writer.</summary>
    private readonly object _gate = new();

    private bool _disposed;

    internal NotchEdgeLayer(Color fill)
    {
        _fill = fill;
        RegisterClass();

        // WS_EX_TRANSPARENT makes the band invisible to the mouse; the WndProc
        // answers WM_NCHITTEST with HTTRANSPARENT as well, because the capsule
        // must never lose a click to a decorative window sitting on top of the
        // desktop next to it.
        _hwnd = NativeMethods.CreateWindowEx(
            NativeMethods.WS_EX_LAYERED | NativeMethods.WS_EX_TRANSPARENT
                | NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_NOACTIVATE
                | NativeMethods.WS_EX_TOPMOST,
            ClassName, "dsh-notch-win-edge", NativeMethods.WS_POPUP,
            0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero,
            NativeMethods.GetModuleHandle(null), IntPtr.Zero);

        if (_hwnd != IntPtr.Zero)
        {
            NativeMethods.ShowWindow(_hwnd, NativeMethods.SW_SHOWNOACTIVATE);
        }

        _memDc = NativeMethods.CreateCompatibleDC(IntPtr.Zero);
    }

    internal IntPtr Handle => _hwnd;

    internal bool Created => _hwnd != IntPtr.Zero;

    internal int BandWidth => _bufW;

    internal int BandHeight => _bufH;

    internal int Radius => _raster.Radius;

    internal bool AttachedRight => _raster.AttachedRight;

    /// <summary>The screen rectangle the band currently occupies, for the
    /// self-test's "the band tracks the capsule" assertion.</summary>
    internal Rectangle Bounds
    {
        get
        {
            if (_hwnd == IntPtr.Zero || !NativeMethods.GetWindowRect(_hwnd, out NativeMethods.RECT rect))
            {
                return Rectangle.Empty;
            }

            return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
        }
    }

    /// <summary>
    /// Puts the band against the capsule's free side and (re)rasterises it.
    ///
    /// `capsule` is the capsule window's rectangle in screen coordinates and
    /// `radius` the corner radius in PHYSICAL pixels — the same value the region
    /// is cut with, so the two can never disagree about where the corner is.
    /// </summary>
    internal void Place(Rectangle capsule, int radius, bool attachedRight)
    {
        lock (_gate)
        {
            PlaceCore(capsule, radius, attachedRight);
        }
    }

    private void PlaceCore(Rectangle capsule, int radius, bool attachedRight)
    {
        if (_disposed || _hwnd == IntPtr.Zero) return;

        int w = Math.Max(1, capsule.Width);
        int h = Math.Max(1, capsule.Height);
        int r = Math.Clamp(radius, 0, Math.Min(w / 2, h / 2));

        // Two extra columns: the coverage of the pixel that straddles the arc's
        // outermost point is computed from the ideal edge, which reaches x = w.
        int bandW = Math.Max(1, Math.Min(w, r + 2));
        int bandX = attachedRight ? capsule.Left : capsule.Right - bandW;
        int bandY = capsule.Top;

        bool sameRaster = _bufW == bandW && _bufH == h && _raster.Radius == r
            && _raster.AttachedRight == attachedRight && _raster.Width == w && _raster.Height == h;

        if (!sameRaster)
        {
            if (!ResizeBitmap(bandW, h)) return;
            Rasterise(w, h, r, attachedRight);
            _raster = (w, h, r, attachedRight);
        }

        MoveTo(capsule);
        Upload(bandX, bandY, bandW, h);
    }

    /// <summary>Follows the capsule without touching the pixels — for a move that
    /// cannot change the shape (a drag, or a re-assertion after the window manager
    /// moved the capsule). Uses the placement the last rasterisation was made
    /// for, so a follower can never drift from the placer.</summary>
    internal void MoveTo(Rectangle capsule)
    {
        lock (_gate)
        {
            MoveToCore(capsule);
        }
    }

    private void MoveToCore(Rectangle capsule)
    {
        if (_disposed || _hwnd == IntPtr.Zero || _bufW <= 0) return;

        int bandX = _raster.AttachedRight ? capsule.Left : capsule.Right - Math.Max(1, _bufW);
        Move(bandX, capsule.Top);
    }

    /// <summary>Repositions the band without touching its pixels (a drag).</summary>
    internal void Move(int x, int y)
    {
        if (_disposed || _hwnd == IntPtr.Zero) return;

        NativeMethods.SetWindowPos(
            _hwnd, IntPtr.Zero, x, y, 0, 0,
            NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOZORDER | NativeMethods.SWP_NOACTIVATE);
    }

    /// <summary>Keeps the band immediately BELOW the capsule in the z-order.
    ///
    /// Both windows are topmost, and the band has to stay under the capsule
    /// through every move; nothing else reorders them, so asserting this once
    /// after each change to the capsule's own styles is enough — and doing it
    /// per frame would make the capsule climb above whatever topmost window the
    /// user has open in front of it.</summary>
    internal void SyncOrder(IntPtr capsule)
    {
        lock (_gate)
        {
            if (_disposed || _hwnd == IntPtr.Zero || capsule == IntPtr.Zero) return;

            NativeMethods.SetWindowPos(
                _hwnd, capsule, 0, 0, 0, 0,
                NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE);
        }
    }

    /// <summary>One pixel of the raster's alpha, in WINDOW coordinates relative to
    /// the band (`0,0` = the band's top-left). Read back from the very bitmap that
    /// was handed to the compositor, so an assertion is about the pixels that were
    /// uploaded rather than about the arithmetic that produced them.</summary>
    internal int AlphaAt(int x, int y)
    {
        lock (_gate)
        {
            if (_bits == IntPtr.Zero || x < 0 || y < 0 || x >= _bufW || y >= _bufH) return -1;

            return unchecked((byte)System.Runtime.InteropServices.Marshal.ReadInt32(
                _bits, (y * _bufW + x) * 4 + 3));
        }
    }

    // ------------------------------------------------------------------
    // the bitmap
    // ------------------------------------------------------------------

    private bool ResizeBitmap(int width, int height)
    {
        if (_memDc == IntPtr.Zero) return false;
        if (_dib != IntPtr.Zero && _bufW == width && _bufH == height) return true;

        if (_oldBitmap != IntPtr.Zero)
        {
            NativeMethods.SelectObject(_memDc, _oldBitmap);
            _oldBitmap = IntPtr.Zero;
        }

        if (_dib != IntPtr.Zero)
        {
            NativeMethods.DeleteObject(_dib);
            _dib = IntPtr.Zero;
            _bits = IntPtr.Zero;
        }

        var header = new NativeMethods.BITMAPINFOHEADER
        {
            biSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.BITMAPINFOHEADER>(),
            biWidth = width,
            // Negative: a TOP-DOWN DIB, so row 0 of the buffer is the band's top
            // row and the coverage rasteriser can walk it in window order.
            biHeight = -height,
            biPlanes = 1,
            biBitCount = 32,
            biCompression = NativeMethods.BI_RGB,
        };

        _dib = NativeMethods.CreateDIBSection(
            _memDc, ref header, NativeMethods.DIB_RGB_COLORS, out _bits, IntPtr.Zero, 0);

        if (_dib == IntPtr.Zero)
        {
            _bits = IntPtr.Zero;
            return false;
        }

        _oldBitmap = NativeMethods.SelectObject(_memDc, _dib);
        _bufW = width;
        _bufH = height;
        return true;
    }

    /// <summary>
    /// Fills the bitmap: premultiplied BGRA, alpha = how much of the pixel the
    /// ideal silhouette covers. The fill is black (the page's own `--bg` and the
    /// form's backdrop are both black), so premultiplied colour is 0 for every
    /// pixel and only the alpha channel carries information.
    /// </summary>
    private void Rasterise(int width, int height, int radius, bool attachedRight)
    {
        if (_bits == IntPtr.Zero) return;

        byte r = _fill.R;
        byte g = _fill.G;
        byte b = _fill.B;
        int bandW = _bufW;

        for (int y = 0; y < height; y++)
        {
            int offset = y * bandW * 4;
            for (int i = 0; i < bandW; i++)
            {
                int windowX = attachedRight ? i : width - bandW + i;

                // The silhouette is described with its free side on the right, so
                // a right-attached capsule asks about the mirrored pixel.
                int probeX = attachedRight ? width - 1 - windowX : windowX;
                int alpha = NotchGeometry.CapsuleCoverage(probeX, y, width, height, radius, Samples);

                if (alpha <= 0)
                {
                    System.Runtime.InteropServices.Marshal.WriteInt32(_bits, offset + i * 4, 0);
                    continue;
                }

                // Premultiplied: colour * alpha / 255.
                int value = (alpha << 24)
                    | (((b * alpha) / 255) << 16)
                    | (((g * alpha) / 255) << 8)
                    | ((r * alpha) / 255);
                System.Runtime.InteropServices.Marshal.WriteInt32(_bits, offset + i * 4, value);
            }
        }
    }

    private void Upload(int x, int y, int width, int height)
    {
        if (_memDc == IntPtr.Zero) return;

        IntPtr screenDc = NativeMethods.GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero) return;

        try
        {
            var destination = new NativeMethods.POINT { X = x, Y = y };
            var size = new NativeMethods.SIZE(width, height);
            var source = new NativeMethods.POINT { X = 0, Y = 0 };
            var blend = new NativeMethods.BLENDFUNCTION
            {
                BlendOp = NativeMethods.AC_SRC_OVER,
                BlendFlags = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = NativeMethods.AC_SRC_ALPHA,
            };

            NativeMethods.UpdateLayeredWindow(
                _hwnd, screenDc, ref destination, ref size, _memDc, ref source, 0,
                ref blend, NativeMethods.ULW_ALPHA);
        }
        finally
        {
            NativeMethods.ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    // ------------------------------------------------------------------
    // the window
    // ------------------------------------------------------------------

    private static void RegisterClass()
    {
        if (_classRegistered) return;

        _procKeepAlive = EdgeProc;
        var wc = new NativeMethods.WNDCLASSEX
        {
            cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.WNDCLASSEX>(),
            style = 0,
            lpfnWndProc = _procKeepAlive,
            hInstance = NativeMethods.GetModuleHandle(null),
            // No background brush: the window's pixels come from
            // UpdateLayeredWindow, and a class brush would only give the
            // compositor something to flash before the first upload.
            hbrBackground = IntPtr.Zero,
            lpszClassName = ClassName,
        };

        NativeMethods.RegisterClassEx(ref wc);
        _classRegistered = true;
    }

    private static IntPtr EdgeProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        switch (msg)
        {
            // Decorative pixels only: the mouse must reach the capsule or the
            // desktop behind, never this band.
            case NativeMethods.WM_NCHITTEST:
                return new IntPtr(NativeMethods.HTTRANSPARENT);

            case NativeMethods.WM_MOUSEACTIVATE:
                return new IntPtr(NativeMethods.MA_NOACTIVATE);

            case NativeMethods.WM_ERASEBKGND:
                return new IntPtr(1);

            case NativeMethods.WM_PAINT:
                return IntPtr.Zero;

            default:
                return NativeMethods.DefWindowProc(hWnd, msg, wParam, lParam);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            DisposeCore();
        }
    }

    private void DisposeCore()
    {
        if (_disposed) return;
        _disposed = true;

        if (_memDc != IntPtr.Zero && _oldBitmap != IntPtr.Zero)
        {
            NativeMethods.SelectObject(_memDc, _oldBitmap);
            _oldBitmap = IntPtr.Zero;
        }

        if (_dib != IntPtr.Zero)
        {
            NativeMethods.DeleteObject(_dib);
            _dib = IntPtr.Zero;
        }

        if (_memDc != IntPtr.Zero)
        {
            NativeMethods.DeleteDC(_memDc);
            _memDc = IntPtr.Zero;
        }

        if (_hwnd != IntPtr.Zero)
        {
            NativeMethods.DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }
    }
}
