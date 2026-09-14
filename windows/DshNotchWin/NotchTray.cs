using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace DshNotchWin;

/// <summary>
/// The capsule's presence in the notification area.
///
/// Why this exists: the capsule deliberately has no taskbar button
/// (<c>WS_EX_TOOLWINDOW</c>, <c>ShowInTaskbar = false</c>) and no title bar, so
/// there is no window chrome to right-click and no Alt-Tab entry to close from.
/// Without a tray icon the only way out of a running capsule was Task Manager.
/// Upstream macOS has the same "no window to close" shape; on Windows the
/// notification area is the counterpart affordance.
///
/// The icon is drawn here rather than shipped as a binary asset: it is the same
/// capsule silhouette the window paints (dark pill, light rim, status disks),
/// drawn at whatever size the current DPI asks for, so the tray entry stays
/// crisp at 100%/150%/200% without a multi-size .ico in the repository.
/// </summary>
internal sealed class NotchTray : IDisposable
{
    /// <summary>Tooltip text. Windows truncates the notification-area tip at 127
    /// characters; these strings stay far below that on purpose.</summary>
    private const string AppName = "dsh-notch-win";

    private readonly NotifyIcon _tray = new();
    private readonly ContextMenuStrip _menu = new();
    private readonly ToolStripMenuItem _toggleItem = new();
    private readonly ToolStripMenuItem _exitItem = new();

    private bool _disposed;
    private string _lastTooltip = string.Empty;
    private string _lastToggleLabel = string.Empty;

    /// <summary>Raised by the menu's toggle item and by a double-click on the
    /// icon: the capsule is the thing that knows how to expand or collapse.</summary>
    internal event Action? ToggleRequested;

    /// <summary>Raised by the menu's exit item. The owner closes the window; the
    /// tray never ends the process itself, so the window's teardown (animation
    /// thread, keyboard borrow, transport) still runs.</summary>
    internal event Action? ExitRequested;

    internal NotchTray()
    {
        _toggleItem.Text = "展开胶囊";
        _exitItem.Text = "退出 dsh-notch-win";

        _toggleItem.Click += (_, _) => ToggleRequested?.Invoke();
        _exitItem.Click += (_, _) => ExitRequested?.Invoke();

        _menu.Items.Add(_toggleItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_exitItem);
        _menu.ShowImageMargin = false;

        _tray.ContextMenuStrip = _menu;
        _tray.Text = AppName;
        _tray.DoubleClick += (_, _) => ToggleRequested?.Invoke();
        _tray.Icon = TrayGlyph.CreateIcon(IconSizes());

        // Not visible yet: the owner shows it once the window is really up, so a
        // failed start cannot leave a ghost icon behind.
        _tray.Visible = false;

        Sync(false, 0);
    }

    internal bool Visible => _tray.Visible;

    /// <summary>Tooltip currently shown; asserted by the self-test, and the
    /// reason "the tray is there but says the wrong thing" is visible in the log.</summary>
    internal string Tooltip => _tray.Text ?? string.Empty;

    internal bool HasIcon => _tray.Icon is not null;

    /// <summary>Pixel width of the icon the tray is holding, in the size the
    /// current DPI asked for.</summary>
    internal int IconWidth => _tray.Icon?.Width ?? 0;

    internal string ToggleLabel => _toggleItem.Text ?? string.Empty;

    internal string ExitLabel => _exitItem.Text ?? string.Empty;

    /// <summary>The menu as the user sees it: separators included, so the layout
    /// itself (toggle / separator / exit) is assertable.</summary>
    internal List<string> MenuLabels()
    {
        var labels = new List<string>();
        foreach (ToolStripItem item in _menu.Items)
        {
            labels.Add(item is ToolStripSeparator ? "-" : item.Text ?? string.Empty);
        }

        return labels;
    }

    internal void Show() => _tray.Visible = true;

    /// <summary>Mirrors the capsule's state into the tooltip and the toggle
    /// label, so the tray says what the capsule is doing.
    ///
    /// Both writes are skipped when the value is unchanged, and that is not a
    /// micro-optimisation: assigning <c>NotifyIcon.Text</c> calls
    /// Shell_NotifyIcon, a synchronous call into explorer.exe, and this method is
    /// reachable from the per-snapshot UI path. Paying it on every frame measurably
    /// delayed the renderer's own frame loop, which is exactly what the orbit
    /// self-test's pinned-phase samples measure (see PLAN.md §16).</summary>
    internal void Sync(bool expanded, int lampCount)
    {
        if (_disposed) return;

        string toggle = expanded ? "收起胶囊" : "展开胶囊";
        if (!string.Equals(toggle, _lastToggleLabel, StringComparison.Ordinal))
        {
            _lastToggleLabel = toggle;
            _toggleItem.Text = toggle;
        }

        string sessions = lampCount > 0 ? $" · {lampCount} 个会话" : string.Empty;
        string tooltip = $"{AppName} · {(expanded ? "已展开" : "已收起")}{sessions}（右键退出）";
        if (string.Equals(tooltip, _lastTooltip, StringComparison.Ordinal)) return;

        _lastTooltip = tooltip;
        _tray.Text = tooltip;
    }

    /// <summary>Self-test hook: clicks the exit item for real, so the assertion
    /// covers the whole chain (menu item → event → window handler) instead of
    /// only that a handler was registered.</summary>
    internal void ClickExitForTest() => _exitItem.PerformClick();

    /// <summary>Self-test hook: clicks the toggle item.</summary>
    internal void ClickToggleForTest() => _toggleItem.PerformClick();

    internal static int[] IconSizes()
    {
        int small = Math.Max(16, SystemInformation.SmallIconSize.Width);
        var sizes = new SortedSet<int> { small };
        if (small < 20) sizes.Add(32);
        if (small < 40) sizes.Add(48);
        return sizes.ToArray();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        // Hide before disposing: an icon whose owner is gone lingers in the
        // notification area until the user hovers it.
        _tray.Visible = false;
        _tray.Dispose();
        _menu.Dispose();
    }
}

/// <summary>
/// Draws the tray icon: the same shape the capsule paints — a dark pill with a
/// light rim and one status disk per state that is actually on screen.
///
/// The icon has to read on both the default dark taskbar and a light one, which
/// is why it is not simply a black pill (invisible on dark) nor a white one
/// (invisible on light): a dark body carries the light rim and the coloured
/// disks. Everything is expressed as a fraction of a 16-unit design grid, so the
/// same code paints 16 px and 48 px.
/// </summary>
internal static class TrayGlyph
{
    private const float Grid = 16f;

    /// <summary>A rendered icon image, kept public to the assembly so the
    /// self-test can count its pixels the way it counts the page canvas.</summary>
    internal static Bitmap Render(int size)
    {
        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.Clear(Color.Transparent);

        float s = size / Grid;

        // The pill: 13 x 8 units, inset far enough that the rim is not clipped at
        // 16 px and the tray does not look like it is touching the icon's edge.
        var body = new RectangleF(1.5f * s, 3.5f * s, 13f * s, 8f * s);
        using (var path = RoundedRect(body, body.Height / 2f))
        {
            using var fill = new LinearGradientBrush(
                body,
                Color.FromArgb(255, 0x2C, 0x2C, 0x33),
                Color.FromArgb(255, 0x0B, 0x0B, 0x0D),
                LinearGradientMode.Vertical);
            g.FillPath(fill, path);

            using var rim = new Pen(Color.FromArgb(165, 0xFF, 0xFF, 0xFF), Math.Max(1f, 0.9f * s));
            g.DrawPath(rim, path);
        }

        // Two of the four status disks, in the upstream palette and left-to-right
        // order (running, then completed): at 16 px a third disk turns to mush,
        // and these two are the pair a live capsule shows most often.
        DrawDisk(g, 6.6f * s, 7.5f * s, 1.25f * s, Color.FromArgb(255, 0x36, 0x8A, 0xFF));
        DrawDisk(g, 9.4f * s, 7.5f * s, 1.25f * s, Color.FromArgb(255, 0x35, 0xD0, 0x5A));

        return bitmap;
    }

    /// <summary>Builds a multi-size icon. The bytes are assembled in memory as a
    /// real ICO rather than taken from <c>Bitmap.GetHicon</c>, because a GDI
    /// handle would have to outlive the icon and be destroyed by hand; an Icon
    /// built from a stream owns its own data.</summary>
    internal static Icon CreateIcon(int[] sizes)
    {
        var ordered = sizes.Where(size => size > 0).Distinct().OrderBy(size => size).ToArray();
        if (ordered.Length == 0) ordered = new[] { 16 };

        var images = new List<byte[]>();
        foreach (int size in ordered)
        {
            using Bitmap bitmap = Render(size);
            images.Add(IcoImage(bitmap));
        }

        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);

        writer.Write((ushort)0);               // reserved
        writer.Write((ushort)1);               // type: icon
        writer.Write((ushort)ordered.Length);

        int offset = 6 + ordered.Length * 16;
        for (int i = 0; i < ordered.Length; i++)
        {
            int size = ordered[i];
            writer.Write((byte)(size >= 256 ? 0 : size));
            writer.Write((byte)(size >= 256 ? 0 : size));
            writer.Write((byte)0);             // palette colours
            writer.Write((byte)0);             // reserved
            writer.Write((ushort)1);           // colour planes
            writer.Write((ushort)32);          // bits per pixel
            writer.Write(images[i].Length);
            writer.Write(offset);
            offset += images[i].Length;
        }

        foreach (byte[] image in images) writer.Write(image);

        writer.Flush();
        stream.Position = 0;
        return new Icon(stream);
    }

    /// <summary>One ICO image entry: a bottom-up 32-bit DIB plus the (all-zero)
    /// AND mask that the format still requires.</summary>
    private static byte[] IcoImage(Bitmap bitmap)
    {
        int width = bitmap.Width;
        int height = bitmap.Height;
        var pixels = new byte[width * height * 4];

        for (int y = 0; y < height; y++)
        {
            // DIB rows run bottom-up.
            int sourceY = height - 1 - y;
            for (int x = 0; x < width; x++)
            {
                Color c = bitmap.GetPixel(x, sourceY);
                int i = (y * width + x) * 4;
                pixels[i] = c.B;      // BGRA, straight (non-premultiplied) alpha
                pixels[i + 1] = c.G;
                pixels[i + 2] = c.R;
                pixels[i + 3] = c.A;
            }
        }

        int maskStride = ((width + 31) / 32) * 4;
        int maskBytes = maskStride * height;

        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);

        writer.Write(40);                      // BITMAPINFOHEADER size
        writer.Write(width);
        writer.Write(height * 2);              // XOR + AND halves
        writer.Write((ushort)1);               // planes
        writer.Write((ushort)32);              // bit count
        writer.Write(0);                       // BI_RGB
        writer.Write(pixels.Length + maskBytes);
        writer.Write(0);                       // x pixels per metre
        writer.Write(0);                       // y pixels per metre
        writer.Write(0);                       // palette colours used
        writer.Write(0);                       // important colours
        writer.Write(pixels);
        writer.Write(new byte[maskBytes]);

        writer.Flush();
        return stream.ToArray();
    }

    private static void DrawDisk(Graphics g, float cx, float cy, float r, Color color)
    {
        using var brush = new SolidBrush(color);
        g.FillEllipse(brush, cx - r, cy - r, r * 2, r * 2);
    }

    private static GraphicsPath RoundedRect(RectangleF rect, float radius)
    {
        float d = Math.Max(0.5f, radius * 2);
        var path = new GraphicsPath();

        path.AddArc(rect.Left, rect.Top, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Top, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();

        return path;
    }
}
