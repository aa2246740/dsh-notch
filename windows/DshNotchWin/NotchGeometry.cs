namespace DshNotchWin;

/// <summary>
/// Pure geometry and animation maths — no window, no P/Invoke, no UI.
///
/// Everything in here is ported from the macOS sources and is deliberately
/// callable from <c>--selftest-core</c> without creating a window, so the
/// numbers that decide the capsule's size and shape are assertable on any
/// machine (including a headless one).
/// </summary>
internal static class NotchGeometry
{
    // ---- Panel.swift:4-11 ---------------------------------------------------
    // macOS 15+ animates with Animation.spring(duration: 0.4, bounce: 0.08);
    // macOS 14 runs this hand-written quintic fallback at 60 fps. The Windows
    // build uses the fallback curve for every frame so its motion is exactly
    // reproducible (PLAN.md §8.2).
    internal const double AnimationSeconds = 0.4;

    /// <summary>smootherstep: x³(x(6x−15)+10), the identical polynomial as
    /// Panel.swift:7-10 and IdleRobot.swift:58-60.</summary>
    internal static double Smootherstep(double t)
    {
        double x = Math.Clamp(t, 0.0, 1.0);
        return x * x * x * (x * (6 * x - 15) + 10);
    }

    // ---- Main.swift / RootView.swift constants ------------------------------

    /// <summary>Expanded panel width (main.swift:33).</summary>
    internal const int PanelWidth = 480;

    /// <summary>Collapsed width while the pointer is away
    /// (RootView.swift:562-567: <c>isPillHovered ? 42 : 38</c>).</summary>
    internal const int RestWidth = 38;

    /// <summary>Collapsed width while the pointer is over the capsule. Upstream
    /// grows the pill to 42 and shortens it by 2; the same happens here, which is
    /// safe because the capsule hangs off the screen edge: growing it outward
    /// cannot put the pointer outside the window it is already inside.</summary>
    internal const int RestWidthHover = 42;

    /// <summary>Inset of the capsule below the top of the work area
    /// (main.swift:36).</summary>
    internal const int TopInset = 100;

    /// <summary>Corner radius, free side only (Panel.swift:123).</summary>
    internal const int CornerRadius = 16;

    /// <summary>Expanded height floor (RootView.swift:579).</summary>
    internal const int MinExpandedHeight = 120;

    /// <summary>Lamp diameter (STATUS-MOTION.md:29 / StatusOrbit.swift).</summary>
    internal const int LampDiameter = 19;

    /// <summary>Vertical pitch between lamp slots (StatusOrbit.swift:11).</summary>
    internal const int LampPitch = 28;

    /// <summary>
    /// Compact capsule height for a number of populated status lamps.
    ///
    /// Ports <c>restCapsuleHeight = orbitLayout.height + 24</c> with
    /// <c>OrbitLayout.height = 20 + 28·max(0, total−1)</c>
    /// (RootView.swift:557-560, StatusOrbit.swift:10-11). <c>total</c> is the sum
    /// of the four 0/1 slot weights, so 0 and 1 populated lamps both give 20 —
    /// hence the 44 pt floor. Yields the documented 44 / 72 / 100 for one / two /
    /// three lamps, and 128 for the fourth (all four states present at once).
    /// </summary>
    internal static int RestHeight(int lampCount)
    {
        int lamps = Math.Max(0, lampCount);
        int orbit = 20 + LampPitch * Math.Max(0, lamps - 1);
        return orbit + 24;
    }

    /// <summary>Hovering shortens the pill by 2 pt (RootView.swift:559).</summary>
    internal static int RestHeightHover(int lampCount) => Math.Max(1, RestHeight(lampCount) - 2);

    /// <summary>
    /// Expanded height for a measured content height: the content is hugged,
    /// floored at 120 and capped by what the work area can show
    /// (RootView.swift:576-583 + main.swift:93-94/147-152).
    /// </summary>
    internal static int ExpandedHeight(int measuredContentHeight, int maximumHeight)
    {
        int cap = Math.Max(1, maximumHeight);
        int floor = Math.Min(MinExpandedHeight, cap);
        return Math.Clamp(measuredContentHeight, floor, cap);
    }

    /// <summary>
    /// Screen geometry cap, mirroring NotchScreenLayout (Panel.swift:144-152):
    /// the inset is halved on a display too short for it, and never eats the
    /// whole work area.
    /// </summary>
    internal static (int Inset, int MaximumHeight) ScreenLayout(int availableHeight, int preferredInset)
    {
        int height = Math.Max(1, availableHeight);
        int inset = Math.Min(preferredInset, Math.Max(0, (height - 1) / 2));
        return (inset, height - 2 * inset);
    }

    /// <summary>
    /// Builds the window region for a capsule of the given size attached to the
    /// given edge, as GDI rectangles.
    ///
    /// The region is the capsule silhouette for two reasons at once: it clips the
    /// window (that is what draws the shape, since chroma-key transparency is
    /// unusable — see NotchWindow.ApplyRegion) and it defines hit-testing, so the
    /// pixels outside the capsule pass clicks through to whatever is behind.
    ///
    /// Row spans are used rather than a <c>GraphicsPath</c> because the region is
    /// rebuilt on every animation frame; a path plus <c>GetHrgn</c> per frame is
    /// far more expensive than integer arithmetic, and the span form is exact.
    /// Adjacent rows that share a span are merged, so the result is a handful of
    /// rectangles instead of one per scanline.
    /// </summary>
    internal static List<NotchRect> CapsuleRegion(int width, int height, int radius, bool attachedRight)
    {
        int w = Math.Max(1, width);
        int h = Math.Max(1, height);
        int r = Math.Clamp(radius, 0, Math.Min(w / 2, h / 2));

        var spans = new NotchRect[h];
        for (int y = 0; y < h; y++)
        {
            int left = 0;
            int right = w;

            // Two rounded corners on the free side: radii from the top and from
            // the bottom (they are the same value, so a row in the middle of a
            // tall capsule takes the smaller inset, i.e. zero).
            int outward;
            if (attachedRight)
            {
                // Corners are on the left: the arc centre sits at x = r and the
                // visible part of the row starts where the circle ends.
                outward = Math.Max(LeftCornerInset(y, r, h), 0);
                left = outward;
            }
            else
            {
                // Corners on the right: the arc centre sits at x = w − r.
                outward = Math.Max(CornerInsetFromTop(y, r), CornerInsetFromBottom(y, r, h));
                right = w - outward;
            }

            if (right < left) right = left;
            spans[y] = new NotchRect(left, y, right, y + 1);
        }

        // Merge vertically adjacent rows with identical extents.
        var rects = new List<NotchRect>(h / 4 + 4);
        int start = 0;
        for (int y = 1; y <= h; y++)
        {
            bool same = y < h && spans[y].Left == spans[start].Left && spans[y].Right == spans[start].Right;
            if (same) continue;

            rects.Add(new NotchRect(spans[start].Left, spans[start].Top, spans[start].Right, y));
            start = y;
        }

        return rects;
    }

    private static int LeftCornerInset(int y, int r, int h) =>
        Math.Max(CornerInsetFromTop(y, r), CornerInsetFromBottom(y, r, h));

    /// <summary>
    /// How far the corner arc cuts into a row measured from the top of the
    /// capsule. The arc's centre is at (r, r); for a row at distance dy from the
    /// top of the corner (dy in [0, r]) the circle occupies the columns within
    /// sqrt(r² − (r − dy)²) of it, so the row starts that many pixels in.
    /// Rows are pixel centres at y + 0.5, which is also what makes the rounded
    /// outline match GDI+'s rendering of the same radius.
    /// </summary>
    private static int CornerInsetFromTop(int y, int r)
    {
        if (r <= 0) return 0;
        double dy = r - (y + 0.5);
        if (dy <= 0) return 0; // past the corner: full width
        double inside = Math.Sqrt(Math.Max(0.0, (double)r * r - dy * dy));
        return (int)Math.Ceiling(r - inside);
    }

    private static int CornerInsetFromBottom(int y, int r, int h)
    {
        return CornerInsetFromTop(h - 1 - y, r);
    }
}

/// <summary>A rectangle in the same shape as the Win32 RECT, kept free of
/// interop types so the geometry layer stays testable.</summary>
internal readonly struct NotchRect
{
    internal NotchRect(int left, int top, int right, int bottom)
    {
        Left = left;
        Top = top;
        Right = right;
        Bottom = bottom;
    }

    internal int Left { get; }
    internal int Top { get; }
    internal int Right { get; }
    internal int Bottom { get; }

    internal int Width => Right - Left;
    internal int Height => Bottom - Top;

    public override string ToString() => $"({Left},{Top})-({Right},{Bottom})";
}

/// <summary>
/// The frame-by-frame geometry of one expand or collapse, ported from
/// <c>NotchPanel.resizeAnchored</c> (Panel.swift:26-55).
///
/// Invariants, asserted frame by frame by the self-test:
///   * the attached screen edge never moves;
///   * the top edge never moves (upstream pins the target frame's maxX/maxY,
///     which on a top-left-origin desktop is exactly x-of-edge and top-y);
///   * width and height move monotonically and land exactly on the target;
///   * retargeting mid-flight restarts the 400 ms clock from the CURRENT frame,
///     so an interrupted animation never jumps (Panel.swift:19-31 bumps a
///     generation; here the old start frame is simply replaced).
/// </summary>
internal sealed class GeometryAnimation
{
    private bool _active;
    private bool _attachedRight;
    private double _startedAt;
    private int _fromWidth;
    private int _fromHeight;
    private int _targetWidth;
    private int _targetHeight;
    private int _edgeX;
    private int _top;

    internal bool Active => _active;

    /// <summary>Frames produced since the last start — the self-test's evidence
    /// that the animation actually ran at a usable rate rather than snapping.</summary>
    internal int FrameCount { get; private set; }

    internal double LastProgress { get; private set; }

    internal int TargetWidth => _targetWidth;
    internal int TargetHeight => _targetHeight;

    internal void Start(int fromWidth, int fromHeight, int targetWidth, int targetHeight, int edgeX, int top, double now)
    {
        _fromWidth = Math.Max(1, fromWidth);
        _fromHeight = Math.Max(1, fromHeight);
        _targetWidth = Math.Max(1, targetWidth);
        _targetHeight = Math.Max(1, targetHeight);
        _edgeX = edgeX;
        _top = top;
        _startedAt = now;
        _active = true;
        LastProgress = 0;
        FrameCount = 1;
    }

    /// <summary>The animation's current frame, whether or not it is still
    /// running. After completion this is the target frame.</summary>
    internal (int X, int Y, int Width, int Height) Frame(double now)
    {
        double progress = 1.0;
        if (_active)
        {
            progress = NotchGeometry.Smootherstep((now - _startedAt) / NotchGeometry.AnimationSeconds);
            LastProgress = progress;
            FrameCount++;
            if (progress >= 1.0) _active = false;
        }

        int width = (int)Math.Round(_fromWidth + (_targetWidth - _fromWidth) * progress);
        int height = (int)Math.Round(_fromHeight + (_targetHeight - _fromHeight) * progress);
        width = Math.Max(1, width);
        height = Math.Max(1, height);

        // The outer edge is pinned; growing always goes away from the edge.
        int x = _attachedRight ? _edgeX - width : _edgeX;
        return (x, _top, width, height);
    }

    internal void SetEdge(bool attachedRight) => _attachedRight = attachedRight;

    /// <summary>Drops the animation without touching the window, keeping the
    /// last computed frame as the new resting geometry. Used when a drag takes
    /// over: the pointer must be authoritative, not the easing curve.</summary>
    internal void Abort()
    {
        _active = false;
    }

    internal bool HasSameTarget(int width, int height) => _targetWidth == width && _targetHeight == height;
}
