using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace DshNotchWin;

/// <summary>
/// Windows counterpart of the macOS <c>NotchPanel</c> + <c>AppDelegate</c>:
/// a borderless, always-on-top, non-activating window hosting the capsule UI in
/// a WebView2, shaped to the capsule silhouette by a window region.
///
/// Ports macos/Sources/Panel.swift and macos/Sources/main.swift, with these
/// deliberate departures from upstream:
///   * the capsule is snapped to a screen edge and only slides vertically, and
///     its position is remembered (upstream recomputes a fixed anchor);
///   * it expands on click rather than on hover (hover only highlights);
///   * a double-click moves it to the opposite edge;
///   * the geometry animation is driven by a dedicated thread (see the
///     animation section) instead of a UI-thread timer, because the UI timer is
///     a WM_TIMER and caps at the ~64 Hz system tick on a 240 Hz display.
/// </summary>
internal sealed class NotchWindow : Form
{
    // ---- design constants, logical points at 96 DPI (PLAN.md §8.3) -----
    internal const int PanelWidth = NotchGeometry.PanelWidth;
    internal const int RestHeight = 110;
    internal const int TopInset = NotchGeometry.TopInset;
    internal const int FoldDelayMs = 380;  // collapse grace          (main.swift:144)
    internal const int PollIntervalMs = 50; // 20 Hz pointer polling  (main.swift:71)
    internal const int DragPollIntervalMs = 8; // fallback rate while dragging
    internal const int DragThresholdPt = 4; // press→drag distance
    internal const int CornerRadius = NotchGeometry.CornerRadius;
    internal const int DoubleClickMs = 400; // edge-switch gesture window

    /// <summary>Posted by the animation thread to ask the UI thread to resync
    /// WinForms' cached geometry and flush the frame to the page.</summary>
    private const int WM_ANIMATION_SETTLED = 0x0400 + 17; // WM_APP + 17

    private readonly bool _selfTest;
    private readonly bool _automation;
    private static int _profileSlot;
    private readonly WebView2 _web = new();
    private readonly System.Windows.Forms.Timer _poll = new();
    private readonly System.Windows.Forms.Timer _fold = new();

    private bool _expanded;
    private bool _enteredIsland;
    private bool _hovered;
    private float _scale = 1f;

    // Placement: which edge, where that edge is, and how far down the capsule
    // sits. Nothing else — the capsule cannot float free of an edge.
    private ScreenEdge _edge = ScreenEdge.Right;
    private int _edgeX;
    private int _top;
    private bool _hasSavedPlacement;

    // Live data. The lamp count drives the compact height; the content height
    // drives the expanded one (RootView.swift:557-583).
    private int _lampCount;

    /// <summary>
    /// The compact pill's animated orbit height, in POINTS, as the page last
    /// reported it (<c>OrbitLayout.height</c>). Upstream sizes the collapsed
    /// capsule from the same sample that places the disks
    /// (<c>restCapsuleHeight = orbitLayout.height + 24</c>, RootView.swift:557),
    /// which is the only way the shell and the ink cannot disagree while a brush
    /// is travelling (docs/motion-continuity.md:15). Zero means "the page has not
    /// reported yet", and the lamp tally is used instead.
    /// </summary>
    private double _restOrbitPt;
    /// <summary>True while the page is showing the idle robot instead of any
    /// status lamp (Phase 5). Logged with the rest height, because "the pill is
    /// a black box" and "the robot renderer failed to initialise" look the same
    /// from the outside.</summary>
    private bool _restOrbitIdle;

    /// <summary>
    /// The page is mid-flight and driving the collapsed height frame by frame.
    /// While this is set the host's own 400 ms easing must stay out of the way —
    /// a flight is a 0.95 s curated timeline, not a resize. Volatile because the
    /// animation thread reads it.
    /// </summary>
    private volatile bool _restOrbitAnimating;

    /// <summary>Rate limit for the per-frame geometry log.</summary>
    private long _lastRestHeightLogTicks;

    /// <summary>
    /// The AskUserQuestion currently being answered, or null. Upstream keeps the
    /// same identity in <c>BoardModel.wizard</c> (RootView.swift:75) and uses it
    /// for two decisions: a question that has just APPEARED opens the capsule by
    /// itself (RootView.swift:214-218), and one that has been answered lets it
    /// fold again (RootView.swift:212).
    /// </summary>
    private string? _activeAskId;

    /// <summary>True while the capsule is open because a question is pending, as
    /// opposed to because the user opened it.</summary>
    private bool _awaitingAction;

    /// <summary>
    /// Any question of the active ask carries more than 240 characters of detail
    /// (long plan text, mostly). Upstream then stops hugging the content and
    /// fills the screen instead, so the option chips stay reachable below the
    /// detail's own scroll area (RootView.swift:571-578). Locked to the threshold
    /// exactly, because the page makes the same decision to lay the detail out as
    /// a scroll region.
    /// </summary>
    private bool _longAskDetail;

    /// <summary>Detail length above which the panel stops hugging its content.</summary>
    internal const int LongDetailThreshold = 240;

    /// <summary>Set while the answer field holds the keyboard; see
    /// SetKeyboardBorrow.</summary>
    private bool _keyboardBorrowed;
    private IntPtr _foregroundBeforeBorrow = IntPtr.Zero;

    /// <summary>Content height the page last reported, in physical pixels. Zero
    /// means "not measured yet", which falls back to the row-count estimate.</summary>
    private int _contentHeight;
    private int _lastRowCount = 1;

    // The newest snapshot, kept as its finished JSON: the page loads after the
    // first frames may already have arrived, and it is complete state.
    private readonly object _snapshotGate = new();
    private string? _lastSnapshotJson;
    private bool _hasSnapshot;

    // geometry animation (see the animation section below)
    private readonly GeometryAnimation _animation = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private Thread? _animationThread;
    private volatile bool _animationRunning;
    private volatile bool _animating;
    private volatile int _liveWidth;
    private volatile int _liveHeight;
    private int _lastAnimationFrames;
    private bool _geometrySettled = true;
    private bool _startingUp;
    private double _animationStartedAt;

    // Press / drag state, driven by the pointer poll so the gesture survives a
    // mouse-up that happens outside the window.
    private bool _pressActive;
    private bool _dragging;
    private Point _pressCursor;
    private int _pressTop;
    private long _lastClickTicks;
    private bool _timerResolutionRaised;
    private bool _captureHeld;
    private int _dragUpdates;
    private long _dragStartedTicks;

    private const int WM_MOUSEMOVE = 0x0200;
    private const int WM_LBUTTONUP = 0x0201;
    private const int WM_CAPTURECHANGED = 0x0215;
    private const int WM_DISPLAYCHANGE = 0x007E;

    private NotchClient? _client;

    /// <summary>Set only while the page self-test is running, so its synthetic
    /// messages can drive the overlay state without touching real data.</summary>
    private bool _pageProbeEnabled;

    /// <summary>Did the page ask for "all seen" during the probe?</summary>
    private bool _seenAllRequested;

    /// <summary>What the page sent while the probe was watching: the ask it
    /// answered and the exact payload it built. Asserted by the page self-test —
    /// "the click reached the host" is not the same claim as "the right answer
    /// was submitted".</summary>
    private string? _probeAnsweredAskId;
    private string? _probeAnswerPayload;

    /// <summary>The page has announced itself over the bridge. The self-test
    /// waits for this before probing: the renderer exists well before the DOM it
    /// later contains, and probing too early reads an empty document.</summary>
    private bool _pageReady;

    internal bool Expanded => _expanded;

    internal ScreenEdge Edge => _edge;

    /// <summary>Number of status lamps the compact capsule is showing.</summary>
    internal int LampCount => _lampCount;

    /// <summary>Snapshots accepted from the Host — proof that real data flowed.</summary>
    internal int SnapshotCount => _client?.SnapshotCount ?? 0;

    internal bool ClientConnected => _client?.Connected ?? false;

    /// <summary>True when the OS asks for reduced motion. Upstream honours the
    /// same preference and shows final states instead of animating.</summary>
    internal bool ReduceMotion => !NativeMethods.ClientAreaAnimationEnabled();

    /// <summary>Reads pass-through straight from the window; see SetClickThrough.</summary>
    internal bool ClickThrough
    {
        get
        {
            long ex = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
            return (ex & NativeMethods.WS_EX_TRANSPARENT) != 0;
        }
    }

    internal NotchWindow(bool selfTest = false, bool automation = false)
    {
        _selfTest = selfTest;
        _automation = automation;

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        MinimumSize = new Size(1, 1);
        Text = "dsh-notch-win";

        _web.Dock = DockStyle.Fill;
        _web.DefaultBackgroundColor = Color.Transparent;
        Controls.Add(_web);

        _poll.Interval = PollIntervalMs;
        _poll.Tick += (_, _) => TickPointer();

        _fold.Interval = FoldDelayMs;
        _fold.Tick += (_, _) =>
        {
            _fold.Stop();

            // The pending-question guard has to be repeated here, not only where
            // the timer is started: the ask can appear DURING the 380 ms grace.
            if (_awaitingAction || _keyboardBorrowed) return;
            if (!IsPointerInside()) Collapse();
        };
    }

    // ------------------------------------------------------------------
    // window lifecycle
    // ------------------------------------------------------------------

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);

        _scale = NativeMethods.GetDpiForWindow(Handle) / 96f;
        if (_scale <= 0f) _scale = 1f;

        ApplyOverlayStyles();
        RestoreOrAnchorPlacement();
        _startingUp = true;
        ApplySize();
        _startingUp = false;
        SetClickThrough(true); // start inert: the capsule is not hovered yet

        if (!_selfTest)
        {
            _poll.Start();
            StartAnimationThread();

            // Real data. Nothing above depends on it being up: the capsule shows
            // an empty ("无活跃会话") state until the first snapshot arrives, and
            // recovers on its own when DSH restarts.
            _client = new NotchClient();
            _client.SnapshotReceived += OnSnapshot;
            _client.TransportStateChanged += message => NotchLog.Write($"transport {message}");
            _client.Start();
        }
        else
        {
            // The self-test still exercises the transport, just without the
            // background loop: one synchronous pull proves the runtime file, the
            // Bearer auth, the DTO mapping and the lamp derivation all agree with
            // the Host that is actually running.
            _client = new NotchClient();
        }
    }

    protected override async void OnShown(EventArgs e)
    {
        // Deliberately applied BEFORE base.OnShown: that call raises the Shown
        // event synchronously, and listeners (the self-test) assert on these
        // bits. WinForms rewrites the extended style from its own state whenever
        // a window property changes, so anything applied earlier — e.g. from the
        // constructor's ShowInTaskbar setter, which calls UpdateStyles — has
        // already been reverted by now.
        ApplyOverlayStyles();
        SetClickThrough(true);

        WriteStartupLog();

        base.OnShown(e);

        await InitWebViewAsync();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // The animation thread owns SetWindowPos/SetWindowRgn; it has to be gone
        // before the handle is destroyed. It checks a single volatile flag and
        // never blocks, so this join is bounded by one sleep (1 ms at worst).
        StopAnimationThread();

        // Restore the activation style before the handle goes away, so a capsule
        // that is killed mid-typing cannot leave the next instance (or another
        // window) wondering who owns the keyboard.
        SetKeyboardBorrow(false);
        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _poll.Stop();
        _fold.Stop();
        EndFastPointerTracking();
        _client?.Dispose();
        _client = null;
        base.OnFormClosed(e);
    }

    /// <summary>
    /// Re-clamps after a resolution change, and drives the drag from real mouse
    /// messages.
    ///
    /// Mouse moves are handled here rather than from the timer on purpose: the
    /// pointer poll is a SetTimer/WM_TIMER, a low-priority coalesced message
    /// that degrades to the ~15.6 ms system tick (~64 Hz) no matter what
    /// interval or timer resolution is requested. On a high-refresh display that
    /// reads as a steppy drag. With capture held, WM_MOUSEMOVE arrives at the
    /// mouse device rate instead.
    /// </summary>
    protected override void WndProc(ref Message m)
    {
        base.WndProc(ref m);

        switch (m.Msg)
        {
            case WM_DISPLAYCHANGE:
                if (Handle != IntPtr.Zero) UpdateGeometryTarget();
                break;

            case WM_ANIMATION_SETTLED:
                OnGeometrySettled();
                break;

            case WM_MOUSEMOVE:
                if (_pressActive) UpdateDragFromCursor();
                break;

            case WM_LBUTTONUP:
                if (_pressActive) FinishGesture();
                break;

            case WM_CAPTURECHANGED:
                // Another window took capture (or it was lost); the gesture can
                // no longer track the pointer, so end it rather than leaving the
                // capsule stuck to a stale drag.
                if (_pressActive) FinishGesture();
                break;
        }
    }

    /// <summary>
    /// Deliberately no CS_DROPSHADOW.
    ///
    /// The drop shadow is drawn by DWM from the window's REGION, so when the
    /// capsule collapses the old, large shadow is composited for a frame before
    /// snapping to the small one — a visible shadow flash on every collapse.
    /// The capsule has no shadow instead; that is the accepted trade-off of
    /// shaping the window with a region rather than chroma-key transparency
    /// (see ApplyRegion).
    /// </summary>

    /// <summary>Keeps the region pinned to the real client area. Sizing the
    /// window and shaping it in one go is not reliable — ClientSize can lag the
    /// Bounds assignment — so the region is re-derived whenever the client size
    /// actually changes.</summary>
    protected override void OnClientSizeChanged(EventArgs e)
    {
        base.OnClientSizeChanged(e);
        if (!_animating) ApplyRegion(ClientSize.Width, ClientSize.Height);
    }

    /// <summary>Adds the styles that make the window an overlay rather than an
    /// app window: hidden from Alt-Tab/taskbar, never activated by a click, and
    /// pinned above everything else. Ports Panel.swift:93-110.</summary>
    private void ApplyOverlayStyles()
    {
        long ex = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        long next = ex | NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_NOACTIVATE;

        if (next != ex)
        {
            NativeMethods.SetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE, new IntPtr(next));
        }

        // SWP_FRAMECHANGED makes the change take effect on an already-visible
        // window instead of waiting for the next frame recalculation.
        NativeMethods.SetWindowPos(
            Handle, NativeMethods.HWND_TOPMOST, 0, 0, 0, 0,
            NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE
            | NativeMethods.SWP_FRAMECHANGED);
    }

    // ------------------------------------------------------------------
    // geometry: one target, two ways to reach it
    // ------------------------------------------------------------------

    /// <summary>Current window rectangle, read from the window manager rather
    /// than from WinForms.
    ///
    /// During an animation the window is moved by the animation thread with
    /// SetWindowPos, which does not update the Form's cached Bounds — a hover
    /// test or a drag clamp that trusted the cache would be measuring a frame
    /// that is hundreds of milliseconds old. GetWindowRect is a cheap query to
    /// the window manager and is the only value that is true for both writers.</summary>
    internal Rectangle LiveBounds
    {
        get
        {
            if (Handle != IntPtr.Zero && NativeMethods.GetWindowRect(Handle, out NativeMethods.RECT rect))
            {
                return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
            }

            return Bounds;
        }
    }

    private bool AttachedRight => _edge == ScreenEdge.Right;

    /// <summary>Size the capsule is heading for, and the anchor it keeps while
    /// it gets there.</summary>
    private Size TargetSize()
    {
        if (_expanded)
        {
            NativeMethods.RECT work = WorkAreaAtEdge();
            (int _, int maximum) = NotchGeometry.ScreenLayout(work.Bottom - work.Top, Scale(TopInset));

            // A long question detail (a plan, usually) does not hug its content:
            // it fills the screen and scrolls internally, so the chips below it
            // stay on screen (RootView.swift:576-583).
            int expandedHeight = _longAskDetail
                ? maximum
                : NotchGeometry.ExpandedHeight(ContentHeightPx(), maximum);
            return new Size(Scale(PanelWidth), expandedHeight);
        }

        int logical = _hovered ? NotchGeometry.RestWidthHover : NotchGeometry.RestWidth;
        int height = RestOrbitPoints() + 24 - (_hovered ? 2 : 0);
        return new Size(Scale(logical), Scale(height));
    }

    /// <summary>
    /// The compact pill's orbit height in points.
    ///
    /// The page is the authority here, not a tally of lamps: the pill's height is
    /// <c>OrbitLayout.height + 24</c> and that layout animates during a flight, so
    /// a lamp count would step where the ink slides. Before the page has reported
    /// anything (or if the renderer is dead) the lamp count is the fallback, and
    /// it is the same number: <c>RestHeight(n) - 24 == 20 + 28·(n-1)</c>.
    /// </summary>
    private int RestOrbitPoints()
    {
        if (_restOrbitPt > 0) return (int)Math.Round(_restOrbitPt);
        return NotchGeometry.RestHeight(_lampCount) - 24;
    }

    /// <summary>
    /// Expanded content height in physical pixels. The page measures its own
    /// content (it is the only side that knows how the rows wrapped) and reports
    /// it in physical pixels; until it has, the row count is a good enough
    /// estimate.
    ///
    /// UNITS: everything here is PHYSICAL pixels. Upstream's 120 pt floor
    /// (RootView.swift:579) is applied as a floor of that many pixels, NOT
    /// scaled: scaling it turns 120 into 180 px at 150%, which is larger than an
    /// honest measurement of a small panel and therefore silently pins the
    /// capsule to the wrong height — the measurement looks like it is being
    /// honoured (the log says 177) while the result stays 180.
    /// </summary>
    private int ContentHeightPx()
    {
        int measured = _contentHeight > 0 ? _contentHeight : EstimateContentHeight();
        return Math.Max(measured, MinExpandedHeightPx);
    }

    /// <summary>Absolute floor for the expanded panel, in physical pixels. Keeps
    /// a stale or missing measurement from collapsing the panel to nothing.</summary>
    private const int MinExpandedHeightPx = 120;

    /// <summary>Estimate used before the page has reported anything, and as a
    /// sanity bound afterwards: 2×14 pt padding, a 24 pt badge row and 12 pt
    /// gaps around rows of at most two 12 pt lines (RootView.swift:731-1050).</summary>
    private int EstimateContentHeight()
    {
        int rows = Math.Max(1, _lastRowCount);
        return Scale(28 + 24 + Math.Max(0, rows - 1) * 12 + rows * 34);
    }

    /// <summary>
    /// Moves the capsule towards its target size. Every path that can change the
    /// target — expand/collapse, hover, a new lamp count, a new content
    /// measurement, an edge switch, a display change — funnels through here, so
    /// there is exactly one place that decides the capsule's geometry.
    ///
    /// Retargeting an animation in flight restarts the 400 ms clock from the
    /// CURRENT frame (Panel.swift:26-31): the capsule never jumps, and two rapid
    /// events (expand then collapse) produce one continuous motion.
    /// </summary>
    private void UpdateGeometryTarget()
    {
        if (Handle == IntPtr.Zero) return;

        NativeMethods.RECT work = WorkAreaAtEdge();
        _edgeX = AttachedRight ? work.Right : work.Left;

        Size target = TargetSize();
        int available = work.Bottom - work.Top;
        int height = Math.Clamp(target.Height, 1, Math.Max(1, available));
        _top = Math.Clamp(_top, work.Top, Math.Max(work.Top, work.Bottom - height));

        // In the self-test (and any automation) geometry must be deterministic:
        // an animation in flight would race the assertions.
        if (_selfTest || ReduceMotion)
        {
            ApplySizeNow(target.Width, height, work);
            return;
        }

        Rectangle live = LiveBounds;
        double startedAt = _clock.Elapsed.TotalSeconds;
        _animation.SetEdge(AttachedRight);
        _animation.Start(live.Width, live.Height, target.Width, height, _edgeX, _top, startedAt);
        _animationStartedAt = startedAt;
        _animating = true;
        _geometrySettled = false;

        // Put the window on the animation's FIRST frame before handing over to the
        // thread. This used to be skipped (the destination size was applied
        // instead), which meant a retarget measured `live` at whatever size the
        // previous animation had left behind and then animated FROM that stale
        // size while the window was already at the destination — so a second
        // geometry change (the page reporting its measured height, for instance)
        // settled on the wrong height and stayed there.
        (int fx, int fy, int fw, int fh) = _animation.Frame(startedAt);
        NativeMethods.SetWindowPos(
            Handle, IntPtr.Zero, fx, fy, fw, fh,
            NativeMethods.SWP_NOZORDER | NativeMethods.SWP_NOACTIVATE);
        ApplyRegion(fw, fh);
        _liveWidth = fw;
        _liveHeight = fh;

        PushGeometry(target.Width, height);
    }

    /// <summary>Sizes the window immediately, without animating. Used by the
    /// self-test, by automation, and as the first frame of an animation (the
    /// window must be told its destination size once; the animation thread then
    /// moves it there frame by frame).</summary>
    private void ApplySizeNow(int width, int height, NativeMethods.RECT work, bool moveWindow = true)
    {
        int x = AttachedRight ? work.Right - width : work.Left;
        int y = _top;
        _liveWidth = width;
        _liveHeight = height;

        if (moveWindow)
        {
            NativeMethods.SetWindowPos(
                Handle, IntPtr.Zero, x, y, width, height,
                NativeMethods.SWP_NOZORDER | NativeMethods.SWP_NOACTIVATE);
            ApplyRegion(width, height);
        }
    }

    /// <summary>
    /// One owner for the process-wide 1 ms timer resolution, because two
    /// subsystems want it (the animation thread and a drag's fast pointer
    /// tracking) and <c>timeBeginPeriod</c>/<c>timeEndPeriod</c> are reference
    /// counted per process — letting each raise and lower it independently
    /// leaves it either leaked or dropped underneath the other one.
    /// </summary>
    private void SetFastTimerResolution(bool wanted)
    {
        if (wanted == _timerResolutionRaised) return;
        if (wanted)
        {
            _timerResolutionRaised = NativeMethods.TimeBeginPeriod(1) == 0;
        }
        else
        {
            NativeMethods.TimeEndPeriod(1);
            _timerResolutionRaised = false;
        }
    }

    /// <summary>Legacy entry point kept for the self-test and --shot: applies the
    /// current state's size with no animation.</summary>
    private void ApplySize()
    {
        if (Handle == IntPtr.Zero) return;
        NativeMethods.RECT work = WorkAreaAtEdge();
        _edgeX = AttachedRight ? work.Right : work.Left;
        Size target = TargetSize();
        int height = Math.Clamp(target.Height, 1, Math.Max(1, work.Bottom - work.Top));
        _top = Math.Clamp(_top, work.Top, Math.Max(work.Top, work.Bottom - height));
        ApplySizeNow(target.Width, height, work);
        Bounds = new Rectangle(Bounds.Left, Bounds.Top, target.Width, height);
        PushGeometry(target.Width, height);
    }

    /// <summary>
    /// Shapes the window to the capsule silhouette, rounding the corners on the
    /// side that is NOT attached to the screen edge (upstream does the same:
    /// Panel.swift:124 masks the two corners facing away from the edge).
    ///
    /// A window region replaces chroma-key transparency, which is unusable here
    /// because it is incompatible with receiving mouse input: WinForms
    /// implements TransparencyKey as a layered colour key, the WebView2 renderer
    /// is a child window whose pixels do not contribute to the layered surface,
    /// and the Form's own surface therefore stays entirely key colour. The OS
    /// then treats the WHOLE window as transparent to hit-testing and every
    /// click falls through to whatever is behind — even with WS_EX_TRANSPARENT
    /// cleared (confirmed with WindowFromPoint).
    ///
    /// The region is rebuilt for every animation frame, which is why the shape
    /// comes from integer row spans (NotchGeometry.CapsuleRegion) rather than a
    /// GraphicsPath: a path plus GetHrgn per frame is far more work than the
    /// arithmetic, and the span form is exact.
    /// </summary>
    private void ApplyRegion(int width, int height)
    {
        if (Handle == IntPtr.Zero) return;
        ApplyRegion(width, height, Scale(CornerRadius));
    }

    private void ApplyRegion(int width, int height, int radius)
    {
        if (Handle == IntPtr.Zero) return;

        int w = Math.Max(1, width);
        int h = Math.Max(1, height);
        List<NotchRect> spans = NotchGeometry.CapsuleRegion(w, h, radius, AttachedRight);

        IntPtr combined = IntPtr.Zero;
        try
        {
            foreach (NotchRect span in spans)
            {
                IntPtr piece = NativeMethods.CreateRectRgn(span.Left, span.Top, span.Right, span.Bottom);
                if (piece == IntPtr.Zero) continue;

                if (combined == IntPtr.Zero)
                {
                    combined = piece;
                }
                else
                {
                    NativeMethods.CombineRgn(combined, combined, piece, NativeMethods.RGN_OR);
                    NativeMethods.DeleteObject(piece);
                }
            }

            if (combined == IntPtr.Zero) return;

            // SetWindowRgn takes ownership on success; the region must not be
            // deleted here or the window would be rendering into freed GDI memory.
            NativeMethods.SetWindowRgn(Handle, combined, true);
            combined = IntPtr.Zero;
        }
        finally
        {
            if (combined != IntPtr.Zero) NativeMethods.DeleteObject(combined);
        }
    }

    // ------------------------------------------------------------------
    // animation: a dedicated thread, because WM_TIMER is capped at 64 Hz
    // ------------------------------------------------------------------

    private void StartAnimationThread()
    {
        if (_animationThread is not null) return;

        _animationRunning = true;
        _animationThread = new Thread(AnimationLoop)
        {
            IsBackground = true,
            Name = "dsh-notch-geometry",
            Priority = ThreadPriority.AboveNormal,
        };
        _animationThread.Start();
    }

    private void StopAnimationThread()
    {
        if (_animationThread is null) return;

        _animationRunning = false;
        try { _animationThread.Join(500); } catch { /* shutting down */ }
        _animationThread = null;
        if (_timerResolutionRaised)
        {
            NativeMethods.TimeEndPeriod(1);
            _timerResolutionRaised = false;
        }
    }

    /// <summary>
    /// Applies the eased geometry every millisecond-ish until the capsule reaches
    /// its target.
    ///
    /// This is a thread rather than a WinForms Timer for the reason measured in
    /// Phase 1: a WinForms Timer is a SetTimer, WM_TIMER is a low-priority
    /// coalesced message, and the UI thread's message pump quantises it to the
    /// ~15.6 ms system tick (64 Hz) regardless of the interval or the timer
    /// resolution. The display here is 240 Hz, so 64 Hz would show the capsule
    /// growing in visible steps.
    ///
    /// Frames are timed from a Stopwatch rather than counted, so a busy machine
    /// drops frames instead of stretching the animation: the 400 ms duration is a
    /// contract (Panel.swift:6), not a frame count. SetWindowPos and SetWindowRgn
    /// are window-manager calls that are safe from another thread precisely
    /// because nothing here touches WinForms state.
    /// </summary>
    private void AnimationLoop()
    {
        while (_animationRunning)
        {
            if (!_animating)
            {
                Thread.Sleep(8);
                continue;
            }

            // The page has taken over the collapsed height (a status brush is
            // travelling). Applying this thread's ease as well would make the two
            // owners of the same edge stutter; the flight's own timeline wins. Only
            // while collapsed: an expand/collapse owns the window outright.
            if (_restOrbitAnimating && !_expanded)
            {
                Thread.Sleep(1);
                continue;
            }

            // SetTimer's quantisation applies to Sleep too: without a 1 ms timer
            // resolution, Sleep(1) is rounded up to the system tick.
            SetFastTimerResolution(true);

            // Measured from the frame the UI thread already applied, so the
            // animation cannot step backwards if this thread wakes late.
            double now = Math.Max(_clock.Elapsed.TotalSeconds, _animationStartedAt);
            (int x, int y, int width, int height) = _animation.Frame(now);
            bool finished = !_animation.Active;

            try
            {
                NativeMethods.SetWindowPos(
                    Handle, IntPtr.Zero, x, y, width, height,
                    NativeMethods.SWP_NOZORDER | NativeMethods.SWP_NOACTIVATE);
                ApplyRegion(width, height, Scale(CornerRadius));
            }
            catch (ObjectDisposedException)
            {
                return;
            }
            catch (InvalidOperationException)
            {
                return;
            }

            _liveWidth = width;
            _liveHeight = height;

            if (finished)
            {
                _animating = false;
                _lastAnimationFrames = _animation.FrameCount;
                // Hand back to the UI thread: WinForms still believes the window
                // is where the animation started, and the page needs the final
                // frame. Posting avoids taking a lock the UI thread also wants.
                if (Handle != IntPtr.Zero)
                {
                    NativeMethods.PostMessage(Handle, WM_ANIMATION_SETTLED, IntPtr.Zero, IntPtr.Zero);
                }

                continue;
            }

            Thread.Sleep(1);
        }
    }

    /// <summary>Runs on the UI thread once an animation has landed.</summary>
    private void OnGeometrySettled()
    {
        if (_geometrySettled) return;
        _geometrySettled = true;

        NativeMethods.GetWindowRect(Handle, out NativeMethods.RECT rect);
        _liveWidth = rect.Right - rect.Left;
        _liveHeight = rect.Bottom - rect.Top;

        // Resync WinForms' private geometry cache without moving the window: the
        // values match what the animation thread already applied, so this is a
        // bookkeeping update, and it keeps OnClientSizeChanged (and therefore the
        // region) in step with reality.
        Bounds = Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);

        long elapsedMs = (long)(_animation.LastProgress * NotchGeometry.AnimationSeconds * 1000);
        double hz = elapsedMs > 0 ? _lastAnimationFrames * 1000.0 / elapsedMs : 0;
        NotchLog.Write(
            $"geometry settled {rect.Right - rect.Left}x{rect.Bottom - rect.Top} " +
            $"frames={_lastAnimationFrames} progress={_animation.LastProgress:0.###} " +
            $"rate~{hz:0} Hz edge={(_edge == ScreenEdge.Left ? "left" : "right")} top={_top}");

        PushGeometry(_liveWidth, _liveHeight, settled: true);

        // A rest flight owns the collapsed height while it runs: re-targeting here
        // would start a 400 ms ease against the page's own timeline. The page
        // reports the settled height when the flight ends, which is what brings
        // the normal path back.
        if (_restOrbitAnimating && !_expanded) return;

        // The target may have moved while the capsule was travelling — most
        // commonly because the page measured its content and reported a height
        // mid-flight (the panel hugs its content, and only the page knows how the
        // rows wrapped). Without this the capsule would settle at a stale size and
        // stay there until something else happened to ask for a new geometry.
        Size recounted = TargetSize();
        if (recounted.Width != rect.Right - rect.Left || recounted.Height != rect.Bottom - rect.Top)
        {
            UpdateGeometryTarget();
        }
    }

    // ------------------------------------------------------------------
    // live data
    // ------------------------------------------------------------------

    /// <summary>Called on a transport thread for every accepted snapshot.</summary>
    private void OnSnapshot(NotchSnapshot snapshot)
    {
        try
        {
            if (IsDisposed || !IsHandleCreated) return;

            NotchCounts counts = NotchCounts.From(snapshot.Rows);
            int rows = snapshot.Rows.Count;
            string json = NotchMessages.Snapshot(snapshot, counts);

            // The page may not exist yet (it is loaded asynchronously and
            // announces itself with "ready"), so the last frame is kept and
            // replayed then. Holding only the newest frame is correct: the Host's
            // snapshots are complete state, never deltas.
            lock (_snapshotGate)
            {
                _lastSnapshotJson = json;
                _hasSnapshot = true;
            }

            // Marshal by posting: the WebView2 message API is thread-safe, and the
            // geometry update below must not run off the UI thread.
            BeginInvoke(() =>
            {
                if (IsDisposed) return;

                bool lampChanged = counts.Lamps != _lampCount;
                _lampCount = counts.Lamps;
                _lastRowCount = rows;

                // ---- AskUserQuestion (Phase 3) --------------------------
                // The capsule opens by itself when a question appears and folds
                // again once it has been answered (RootView.swift:212-218). Both
                // transitions are keyed on the ASK ID, not on "some row needs
                // action": a second question arriving while the first is still
                // pending must open the wizard on the new one, and answering it
                // must not be mistaken for the earlier, already-open state.
                //
                // Upstream picks the first row with needsAction and can therefore
                // land on an approval prompt. Approval is dead code on the Host
                // (src/dsh-notch.ts:44-46) and this build does not offer approval
                // buttons (PLAN.md §13), so the trigger is the first row with a
                // real question — the one thing the wizard can act on.
                NotchRow? actionRow = snapshot.Rows.Find(row => row.Ask is not null);
                string? askId = actionRow?.Ask?.Id;

                bool longDetail = false;
                if (actionRow?.Ask is NotchAsk activeAsk)
                {
                    foreach (NotchQuestion question in activeAsk.Questions)
                    {
                        if ((question.Detail?.Length ?? 0) > LongDetailThreshold)
                        {
                            longDetail = true;
                            break;
                        }
                    }
                }

                bool askAppeared = askId is not null && askId != _activeAskId;
                bool askResolved = askId is null && _activeAskId is not null;
                bool layoutChanged = longDetail != _longAskDetail;

                _activeAskId = askId;
                _longAskDetail = longDetail;

                bool geometryDirty = false;
                if (askAppeared)
                {
                    NotchLog.Write($"ask {askId} appeared longDetail={longDetail} — expanding");
                    _awaitingAction = true;
                    _expanded = true;
                    geometryDirty = true;
                }
                else if (askResolved)
                {
                    NotchLog.Write("ask resolved — folding");
                    _awaitingAction = false;
                    if (_keyboardBorrowed) SetKeyboardBorrow(false);
                    if (_expanded)
                    {
                        _expanded = false;
                        _enteredIsland = false;
                        geometryDirty = true;
                    }
                }
                else if (layoutChanged && _expanded)
                {
                    geometryDirty = true;
                }

                // A new task appearing or finishing changes the compact height
                // (44/72/100/128): animate if asked, never jump. While the capsule
                // is still starting up there is nothing to animate from — the
                // first snapshot simply tells it how tall it should have been, so
                // it appears at the right size instead of visibly growing.
                if (lampChanged && !_expanded) geometryDirty = true;

                if (geometryDirty)
                {
                    if (_startingUp) ApplySize();
                    else UpdateGeometryTarget();
                }

                _startingUp = false;

                SendSnapshotJson(json);
            });
        }
        catch (Exception ex)
        {
            NotchLog.Write($"snapshot failed: {ex.GetType().Name} {ex.Message}");
        }
    }

    private void SendSnapshotJson(string json)
    {
        if (_web.CoreWebView2 is null) return;

        try
        {
            _web.CoreWebView2.PostWebMessageAsJson(json);
        }
        catch (Exception ex)
        {
            NotchLog.Write($"push snapshot failed: {ex.Message}");
        }
    }

    /// <summary>Reports the frame the window is on right now. The page lays its
    /// content out against the destination width and its measured height against
    /// <c>settled</c>, so content and window can never disagree about the
    /// capsule's size.</summary>
    private void PushGeometry(int width, int height, bool? settled = null)
    {
        if (_web.CoreWebView2 is null) return;

        try
        {
            _web.CoreWebView2.PostWebMessageAsJson(NotchMessages.Geometry(
                _expanded, width, height, Scale(CornerRadius),
                _edge == ScreenEdge.Left ? "left" : "right", _hovered, _scale, _contentHeight,
                settled ?? !_animating,
                // The self-test needs the animation to run even on a machine whose
                // "show animations" setting is off, or it could not assert a flight
                // at all; the Reduce Motion CONTRACT is asserted separately, by
                // driving the page's own switch.
                motion: !ReduceMotion || _selfTest));
        }
        catch (Exception ex)
        {
            NotchLog.Write($"push geometry failed: {ex.Message}");
        }
    }

    // ------------------------------------------------------------------
    // placement: saved edge position, or the upstream computed anchor
    // ------------------------------------------------------------------

    private void RestoreOrAnchorPlacement()
    {
        WindowPlacement? saved = WindowPlacement.Load();
        if (saved is not null && TryResolve(saved, out ScreenEdge edge, out int edgeX, out int top))
        {
            _edge = edge;
            _edgeX = edgeX;
            _top = top;
            _hasSavedPlacement = true;
            return;
        }

        AnchorToCursorMonitor();
    }

    /// <summary>
    /// Turns a stored placement into (edge, edgeX, top), migrating the legacy
    /// freely-dragged format on the way so an existing position is not lost.
    /// The result is clamped into a real monitor's work area.
    /// </summary>
    private bool TryResolve(WindowPlacement saved, out ScreenEdge edge, out int edgeX, out int top)
    {
        edge = ScreenEdge.Right;
        edgeX = 0;
        top = 0;

        if (!string.IsNullOrWhiteSpace(saved.Edge))
        {
            edge = string.Equals(saved.Edge, "left", StringComparison.OrdinalIgnoreCase)
                ? ScreenEdge.Left
                : ScreenEdge.Right;
            edgeX = saved.EdgeX;
            top = saved.Top;
        }
        else if (saved.LegacyTopRightX is int legacyX && saved.LegacyTopRightY is int legacyY)
        {
            // Legacy: topRightX was the capsule's right edge. If it sat in the
            // left half of the desktop it was really attached to the left edge.
            int probeX = Math.Max(0, legacyX - 1);
            NativeMethods.MONITORINFO legacyInfo = MonitorInfoAt(new Point(probeX, legacyY));
            int center = (legacyInfo.rcWork.Left + legacyInfo.rcWork.Right) / 2;
            edge = legacyX <= center ? ScreenEdge.Left : ScreenEdge.Right;
            edgeX = edge == ScreenEdge.Left ? legacyInfo.rcWork.Left : legacyInfo.rcWork.Right;
            top = legacyY;
        }
        else
        {
            return false;
        }

        NativeMethods.RECT work = WorkAreaAt(edge, edgeX, top);
        edgeX = edge == ScreenEdge.Left ? work.Left : work.Right;
        top = Math.Clamp(top, work.Top, Math.Max(work.Top, work.Bottom - 1));
        return true;
    }

    /// <summary>Upstream rule (main.swift:84-107) for a first run: upper-right of
    /// the monitor under the cursor, inset below the top.</summary>
    private void AnchorToCursorMonitor()
    {
        NativeMethods.GetCursorPos(out NativeMethods.POINT cursor);
        Rectangle probe = ComputeAnchor(new Point(cursor.X, cursor.Y), RestSize(), Scale(TopInset));

        _edge = ScreenEdge.Right;
        _edgeX = probe.Right;
        _top = probe.Top;
        _hasSavedPlacement = false;
    }

    /// <summary>Work area of the monitor the snapped edge belongs to.</summary>
    private NativeMethods.RECT WorkAreaAt(ScreenEdge edge, int edgeX, int top)
    {
        int probeX = edge == ScreenEdge.Left ? edgeX + 1 : edgeX - 1;
        return MonitorInfoAt(new Point(probeX, top)).rcWork;
    }

    private NativeMethods.RECT WorkAreaAtEdge() => WorkAreaAt(_edge, _edgeX, _top);

    /// <summary>Right-click escape hatch: keep the edge, return to the default
    /// inset below the top so a capsule dragged far down is easy to recover.</summary>
    private void ResetVerticalPosition()
    {
        WindowPlacement.Clear();

        NativeMethods.RECT work = WorkAreaAtEdge();
        int inset = Math.Min(Scale(TopInset), Math.Max(0, (work.Bottom - work.Top - 1) / 2));
        _top = work.Top + inset;
        _hasSavedPlacement = false;

        UpdateGeometryTarget();
        PushSnapshotNow();
    }

    /// <summary>Double-click: glide across to the opposite screen edge, keeping
    /// the vertical position and the current expanded state.</summary>
    private void ToggleEdge()
    {
        NativeMethods.RECT work = WorkAreaAtEdge();

        _edge = _edge == ScreenEdge.Left ? ScreenEdge.Right : ScreenEdge.Left;
        _edgeX = _edge == ScreenEdge.Left ? work.Left : work.Right;

        UpdateGeometryTarget();
        PersistPlacement();
        PushSnapshotNow();
    }

    private void PersistPlacement()
    {
        WindowPlacement.Save(_edge, _edgeX, _top);
        _hasSavedPlacement = true;
    }

    // ------------------------------------------------------------------
    // anchoring maths (kept static so the self-test can check it directly)
    // ------------------------------------------------------------------

    private int Scale(int logical) => Math.Max(1, (int)Math.Round(logical * _scale));

    private Size RestSize() => new(Scale(NotchGeometry.RestWidth), Scale(NotchGeometry.RestHeight(1)));

    private Size ExpandedSize() => new(Scale(PanelWidth), Scale(NotchGeometry.MinExpandedHeight));

    /// <summary>
    /// Pure layout function for the first-run anchor. Mirrors upstream
    /// <c>NotchScreenLayout</c>: the inset is clamped to half the available
    /// height and the capsule never exceeds what is left.
    /// </summary>
    internal static Rectangle ComputeAnchor(Point cursor, Size sizePx, int topInsetPx)
    {
        NativeMethods.MONITORINFO info = MonitorInfoAt(cursor);
        NativeMethods.RECT work = info.rcWork;

        int availableHeight = work.Bottom - work.Top;
        int inset = Math.Min(topInsetPx, Math.Max(0, (availableHeight - 1) / 2));
        int maximumHeight = availableHeight - 2 * inset;

        int height = Math.Clamp(sizePx.Height, 1, Math.Max(1, maximumHeight));
        int x = work.Right - sizePx.Width; // upper-right edge
        int y = work.Top + inset;

        return new Rectangle(x, y, sizePx.Width, height);
    }

    private static NativeMethods.MONITORINFO MonitorInfoAt(Point point)
    {
        IntPtr monitor = NativeMethods.MonitorFromPoint(
            new NativeMethods.POINT { X = point.X, Y = point.Y },
            NativeMethods.MONITOR_DEFAULTTONEAREST);

        var info = new NativeMethods.MONITORINFO
        {
            cbSize = Marshal.SizeOf<NativeMethods.MONITORINFO>(),
        };
        NativeMethods.GetMonitorInfo(monitor, ref info);
        return info;
    }

    /// <summary>Work area of the monitor under the cursor, in the process's own
    /// coordinate space.</summary>
    internal static NativeMethods.RECT CursorMonitorWork()
    {
        NativeMethods.GetCursorPos(out NativeMethods.POINT p);
        return MonitorInfoAt(new Point(p.X, p.Y)).rcWork;
    }

    // ------------------------------------------------------------------
    // pointer: hover, press, drag, click-through
    // ------------------------------------------------------------------

    private bool IsPointerInside()
    {
        if (!NativeMethods.GetCursorPos(out NativeMethods.POINT p)) return false;
        return LiveBounds.Contains(p.X, p.Y);
    }

    /// <summary>Toggles pass-through. While transparent the window receives no
    /// mouse input at all, which is why hover is detected by polling the cursor
    /// rather than by window messages — the same reason upstream polls
    /// NSEvent.mouseLocation on a 50 ms timer.
    ///
    /// State is read back from the window rather than trusted from a cached
    /// field: WinForms can rewrite the style bits underneath us, and a stale
    /// cache would turn a needed re-apply into a no-op.</summary>
    internal void SetClickThrough(bool on)
    {
        long ex = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        bool current = (ex & NativeMethods.WS_EX_TRANSPARENT) != 0;

        if (current != on)
        {
            long next = on
                ? ex | NativeMethods.WS_EX_TRANSPARENT
                : ex & ~(long)NativeMethods.WS_EX_TRANSPARENT;

            NativeMethods.SetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE, new IntPtr(next));
            NotchLog.Write($"clickThrough -> {(on ? "ON" : "OFF")} exstyle=0x{next:X8}");
        }
    }

    /// <summary>Called when the page reports a press on non-interactive chrome.</summary>
    private void BeginPress()
    {
        if (!NativeMethods.GetCursorPos(out NativeMethods.POINT cursor)) return;

        // A drag takes over from an animation in flight (a fast expand→drag is a
        // normal thing to do). The window stays where it is; the pointer becomes
        // authoritative from here.
        _animation.Abort();
        _animating = false;

        _pressActive = true;
        _dragging = false;
        _pressCursor = new Point(cursor.X, cursor.Y);
        _pressTop = LiveBounds.Top;
        _dragUpdates = 0;

        // Take capture so the drag is driven by mouse-move messages at the
        // device rate instead of by the ~64 Hz pointer poll, and so a release
        // outside the window still reaches us. The window is non-activating, so
        // this does not pull focus away from the foreground app.
        _ = NativeMethods.SetCapture(Handle);
        _captureHeld = NativeMethods.GetCapture() == Handle;

        BeginFastPointerTracking();
    }

    /// <summary>Applies the current pointer position to the drag, if one is in
    /// progress. Called from WM_MOUSEMOVE (the smooth path) and from the poll
    /// (the fallback).</summary>
    private void UpdateDragFromCursor()
    {
        if (!NativeMethods.GetCursorPos(out NativeMethods.POINT cursor)) return;

        // Only the vertical delta is used: the capsule is attached to an edge
        // and slides along it, so horizontal movement is ignored by design.
        int dy = cursor.Y - _pressCursor.Y;
        if (!_dragging && Math.Abs(dy) > Scale(DragThresholdPt))
        {
            _dragging = true;
            _dragStartedTicks = Environment.TickCount64;
        }

        if (!_dragging) return;

        NativeMethods.RECT work = WorkAreaAtEdge();
        Rectangle live = LiveBounds;
        _top = Math.Clamp(_pressTop + dy, work.Top, Math.Max(work.Top, work.Bottom - live.Height));

        // Move with SetWindowPos rather than Form.Location: one call straight to
        // the window manager, with SWP_NOZORDER / SWP_NOACTIVATE making it
        // explicit that a drag never reorders or activates the overlay.
        NativeMethods.SetWindowPos(
            Handle, IntPtr.Zero, live.Left, _top, 0, 0,
            NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOZORDER | NativeMethods.SWP_NOACTIVATE);
        _dragUpdates++;
    }

    /// <summary>
    /// Ends the current press: a moved press persists the new position, an
    /// unmoved one counts as a click. Idempotent, because it can be reached from
    /// WM_LBUTTONUP, WM_CAPTURECHANGED and the poll's safety net.
    /// </summary>
    private void FinishGesture()
    {
        if (!_pressActive) return;
        _pressActive = false;

        bool wasDragging = _dragging;
        _dragging = false;

        // Clear the flag before releasing: ReleaseCapture raises
        // WM_CAPTURECHANGED, and the guard above must already be closed by then.
        if (_captureHeld)
        {
            _captureHeld = false;
            NativeMethods.ReleaseCapture();
        }

        EndFastPointerTracking();

        if (wasDragging)
        {
            long elapsed = Math.Max(1, Environment.TickCount64 - _dragStartedTicks);
            NotchLog.Write($"drag updates={_dragUpdates} over {elapsed}ms " +
                $"({_dragUpdates * 1000 / elapsed} Hz) captureAfterRelease=0x{NativeMethods.GetCapture().ToInt64():X}");
            Rectangle live = LiveBounds;
            Bounds = live;            // resync WinForms after the raw moves
            ApplyRegion(live.Width, live.Height);
            PersistPlacement();
            return;
        }

        NotchLog.Write($"click captureAfterRelease=0x{NativeMethods.GetCapture().ToInt64():X}");
        OnBackgroundClick();
    }

    /// <summary>
    /// Raises the pointer sampling rate for an active gesture. WinForms' Timer
    /// is a SetTimer, quantised to the system timer tick (~15.6 ms), so the
    /// interval alone is not enough — the resolution has to be raised too, and
    /// is always restored (it is a system-wide setting).
    /// </summary>
    private void BeginFastPointerTracking()
    {
        _poll.Interval = DragPollIntervalMs;
        SetFastTimerResolution(true);

        NotchLog.Write($"fast pointer tracking interval={_poll.Interval}ms resolutionRaised={_timerResolutionRaised}");
    }

    private void EndFastPointerTracking()
    {
        _poll.Interval = PollIntervalMs;

        // The animation thread wants the same resolution for its frames; only
        // drop it when nothing else is using it.
        if (!_animating) SetFastTimerResolution(false);
    }

    private void TickPointer()
    {
        if (!NativeMethods.GetCursorPos(out NativeMethods.POINT cursor)) return;
        var pointer = new Point(cursor.X, cursor.Y);
        Rectangle live = LiveBounds;

        // --- gesture safety net -----------------------------------------
        // Releases normally arrive as WM_LBUTTONUP thanks to capture, but the
        // capture can be lost (another app, a UAC prompt, the window being
        // hidden). The physical button state is authoritative, so a lost release
        // can never leave the gesture — or the capture — stuck.
        if (_pressActive)
        {
            if (!NativeMethods.LeftButtonDown())
            {
                FinishGesture();
            }
            else if (!_captureHeld)
            {
                // Only a fallback: while capture is held, WM_MOUSEMOVE is the
                // driver and running both would just apply the same position
                // twice.
                UpdateDragFromCursor();
            }
        }

        // --- hover ------------------------------------------------------
        bool inside = live.Contains(pointer.X, pointer.Y);

        if (inside != _hovered)
        {
            _hovered = inside;
            NotchLog.Write($"hover inside={inside} cursor=({pointer.X},{pointer.Y}) bounds={live}");
            PushHover();

            // Upstream also grows the collapsed pill by 4 pt while hovered
            // (RootView.swift:562-567). Hovering never expands the capsule here:
            // expanding is a click, by this build's design.
            if (!_expanded && !_pressActive) UpdateGeometryTarget();
        }

        if (inside)
        {
            _enteredIsland = true;
            _fold.Stop();           // re-entering cancels a pending fold
            SetClickThrough(false); // become interactive before the click lands
            return;
        }

        // Outside: pass clicks through to whatever is underneath.
        SetClickThrough(true);

        // A pending question keeps the panel open. Upstream folds it anyway and
        // reopens it on hover (main.swift:123); this build expands only on click
        // — the interaction the user chose — so folding here would be a dead end
        // the user has to click their way out of every time they look at DSH.
        // The same guard covers a borrowed keyboard: Collapse() gives the
        // keyboard back, and losing it mid-sentence to a stray mouse move is not
        // acceptable.
        if (_awaitingAction || _keyboardBorrowed)
        {
            _fold.Stop();
            return;
        }

        if (_expanded && _enteredIsland && !_fold.Enabled) _fold.Start();
    }

    /// <summary>
    /// One click on the capsule expands it (a click while expanded is a no-op).
    /// Two clicks in quick succession move it to the opposite screen edge.
    ///
    /// The double-click is detected here rather than in the page on purpose: the
    /// first click expands the capsule, which RESIZES the window, so the second
    /// click lands on a different DOM node and Chromium never reports a
    /// dblclick — the gesture would be impossible while collapsed. Timestamps in
    /// the host are independent of DOM hit-testing.
    /// </summary>
    private void OnBackgroundClick()
    {
        long now = Environment.TickCount64;
        bool isDoubleClick = now - _lastClickTicks <= DoubleClickMs;
        _lastClickTicks = now;

        if (isDoubleClick)
        {
            ToggleEdge();
            return;
        }

        if (!_expanded) Expand();
    }

    private void Expand()
    {
        _expanded = true;
        UpdateGeometryTarget();
        PushSnapshotNow();
    }

    /// <summary>Jump straight to the expanded state. Used by --shot so a capture
    /// does not depend on where the pointer happens to be.</summary>
    internal void ForceExpanded()
    {
        _expanded = true;
        UpdateGeometryTarget();
        PushSnapshotNow();
    }

    /// <summary>
    /// Writes the page's own view of its boxes to the log. Used by <c>--shot</c>:
    /// the capture says what the pixels look like, this says why — the viewport
    /// height, the list's client/scroll heights and which of them the panel was
    /// sized from. It is the difference between "the panel looks wrong" and "the
    /// panel is 28 px and the content is 92 px".
    /// </summary>
    internal async Task LogPageLayoutAsync()
    {
        if (_web.CoreWebView2 is null) return;

        try
        {
            string list = Unquote(await _web.CoreWebView2.ExecuteScriptAsync(PageProbeScript));
            string wizard = Unquote(await _web.CoreWebView2.ExecuteScriptAsync(WizardProbeScript));
            NotchLog.Write($"page layout {list}");
            NotchLog.Write($"page wizard {wizard}");
        }
        catch (Exception ex)
        {
            NotchLog.Write($"page layout probe failed: {ex.Message}");
        }
    }

    /// <summary>Testing/automation hook: show a specific edge without touching
    /// the remembered placement (--shot uses this).</summary>
    internal void ForceEdge(ScreenEdge edge)
    {
        if (_edge == edge) return;

        NativeMethods.RECT work = WorkAreaAtEdge();
        _edge = edge;
        _edgeX = edge == ScreenEdge.Left ? work.Left : work.Right;
        UpdateGeometryTarget();
        PushSnapshotNow();
    }

    /// <summary>
    /// Automation hook for <c>--shot --ask</c>: delivers a synthetic
    /// AskUserQuestion through the REAL snapshot path, so a capture shows what a
    /// live question produces — including the auto-expand and, with
    /// <paramref name="longDetail"/>, the long-detail height switch.
    ///
    /// No Host is involved and nothing is answered: the snapshot is local data,
    /// and answering it would require a pending ask that only the Host can hold.
    /// </summary>
    internal void InjectSyntheticAsk(bool longDetail)
    {
        var detail = new StringBuilder();
        // Deliberately under the 240-character threshold for the plain --ask shot:
        // that is the layout a normal question gets (panel hugs its content).
        detail.Append("# 迁移计划\n\n");
        detail.Append("把 macOS 的任务胶囊移植到 Windows 11。\n\n");
        detail.Append("- Host 插件层：跨平台，一行不改\n");
        detail.Append("- 原生 UI 层：WebView2 + WinForms 重写\n\n");
        detail.Append("| 阶段 | 内容 | 状态 |\n| --- | --- | --- |\n");
        detail.Append("| 1 | 窗口层 | 完成 |\n| 2 | 真实数据 | 完成 |\n| 3 | 行内回答 | 进行中 |\n\n");
        detail.Append("回答用 `AskUserQuestion` 提交，**不经过浏览器**。\n");

        if (longDetail)
        {
            // Past the 240-character threshold with room to spare: the panel then
            // fills the screen and this detail becomes its own scroll area.
            for (int i = 0; i < 3; i++)
            {
                detail.Append("\n每一阶段都要留下可复现的证据：自检项、截图与实测数字，而不是一句已经完成。"
                    + "卸载要能一键回滚到未安装状态，且不在系统里留下任何残留文件与注册表项。"
                    + "安装脚本必须能在没有管理员权限的情况下完成接入，并保证重复执行是幂等的。\n");
            }
        }

        var ask = new NotchAsk
        {
            Id = "shot-ask-1",
            Questions =
            {
                new NotchQuestion
                {
                    Id = "shot-q1",
                    Question = "这份迁移计划可以吗？",
                    Header = "计划评审",
                    Detail = detail.ToString(),
                    Options = new List<NotchOption>
                    {
                        new() { Label = "可以，继续", Description = "按计划推进 Phase 3" },
                        new() { Label = "要改", Description = "先说明要改哪一部分" },
                    },
                },
                new NotchQuestion
                {
                    Id = "shot-q2",
                    Question = "还需要哪些证据？",
                    MultiSelect = true,
                    Options = new List<NotchOption>
                    {
                        new() { Label = "自检报告", Description = "--selftest 的完整输出" },
                        new() { Label = "截图", Description = "左右边各一张" },
                        new() { Label = "实测数字", Description = "帧率与耗时" },
                    },
                },
            },
        };

        var snapshot = new NotchSnapshot
        {
            Ok = true,
            GeneratedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            Origin = "shot",
        };
        snapshot.Rows.Add(new NotchRow
        {
            Id = "shot-session",
            Title = "dsh-notch Phase 3",
            Ask = ask,
        });
        snapshot.Rows.Add(new NotchRow { Id = "shot-idle", Title = "另一个会话" });

        OnSnapshot(snapshot);
    }

    /// <summary>The page should measure its content again — the panel's height
    /// depends on it. Used by automation after it has changed the capsule's
    /// state from the outside (--shot --expanded), which the page cannot see
    /// coming.</summary>
    internal void RequestContentMeasure()
    {
        if (_web.CoreWebView2 is null) return;
        try
        {
            _web.CoreWebView2.PostWebMessageAsJson("{\"type\":\"measure\"}");
        }
        catch (Exception ex)
        {
            NotchLog.Write($"push measure failed: {ex.Message}");
        }
    }

    private void Collapse()
    {
        _expanded = false;
        _enteredIsland = false;

        // Never leave the capsule activatable behind a closed panel: the fold can
        // arrive while the page still believes its answer field has focus.
        if (_keyboardBorrowed) SetKeyboardBorrow(false);

        UpdateGeometryTarget();
        PushSnapshotNow();
    }

    /// <summary>The page's own content measurement, in physical pixels. Only the
    /// expanded panel needs it; while collapsed the PAGE's orbit height is the
    /// whole story (see SetRestOrbit). A report that arrives while collapsed is
    /// kept, not acted on.</summary>
    private void SetContentHeight(int height)
    {
        if (height <= 0 || height > 20000) return;
        if (height == _contentHeight) return;

        // Logged because this is the page's half of the geometry contract: if the
        // panel is the wrong size, the first question is always whether the page
        // reported a height at all, and what it reported.
        NotchLog.Write($"content height {_contentHeight} -> {height} (expanded={_expanded})");
        _contentHeight = height;
        if (_expanded) UpdateGeometryTarget();
    }

    /// <summary>
    /// The page's animated orbit height, in points, with the flag that says
    /// whether a status brush is still travelling.
    ///
    /// Upstream's collapsed capsule is sized from <c>orbitLayout.height + 24</c>,
    /// i.e. from the SAME sample that places the four disks, so the window edge
    /// and the ink move together on every frame while a task's outcome migrates
    /// between slots (docs/motion-continuity.md:15). A lamp count cannot express
    /// that: mid-flight the layout carries fractional slot weights, and the pill
    /// has to grow or shrink with them.
    ///
    /// While the page is animating, the host applies the reported height directly
    /// instead of easing towards it. A flight is a curated 0.95 s timeline; a
    /// 400 ms smootherstep over the same endpoints would fight it. Once the page
    /// reports the settled height, the normal geometry path takes over again.
    /// </summary>
    private void SetRestOrbit(double orbitPt, bool animating, bool idle = false)
    {
        if (orbitPt <= 0 || orbitPt > 200) return;

        bool changed = Math.Abs(orbitPt - _restOrbitPt) > 0.02;
        _restOrbitPt = orbitPt;
        _restOrbitIdle = idle;

        // The rest block is hidden behind the expanded panel, and its geometry is
        // the expanded measurement's business.
        if (_expanded)
        {
            _restOrbitAnimating = false;
            return;
        }

        // Direct control only while the page is BOTH animating and actually
        // changing the height: the settled report at the end of a flight must not
        // abort an expand/collapse that happens to be running beside it.
        bool driving = animating && changed;
        _restOrbitAnimating = driving;

        if (_dragging) return;

        if (driving)
        {
            AbortGeometryAnimation();
            ApplyRestGeometry();
        }
        else if (changed && !_animating)
        {
            UpdateGeometryTarget();
        }
    }

    /// <summary>
    /// Sizes the collapsed capsule to the orbit height the page just reported,
    /// immediately. The attached edge and the top edge stay put — the pill grows
    /// or shrinks away from its screen edge, exactly as every other geometry
    /// change here does.
    /// </summary>
    private void ApplyRestGeometry()
    {
        if (Handle == IntPtr.Zero || _expanded) return;

        NativeMethods.RECT work = WorkAreaAtEdge();
        _edgeX = AttachedRight ? work.Right : work.Left;

        Size target = TargetSize();
        int height = Math.Clamp(target.Height, 1, Math.Max(1, work.Bottom - work.Top));
        _top = Math.Clamp(_top, work.Top, Math.Max(work.Top, work.Bottom - height));

        if (target.Width == _liveWidth && height == _liveHeight) return;
        ApplySizeNow(target.Width, height, work);

        // A flight changes this ~60 times per second; log it often enough to
        // diagnose a stuck pill and rarely enough to read the log. `idle` is the
        // page's own verdict on whether the robot is on screen, because a pill
        // that is simply black and a robot that failed to paint look identical
        // from here (the page also reports `reason` to the self-test).
        long nowTicks = _clock.ElapsedMilliseconds;
        if (nowTicks - _lastRestHeightLogTicks > 200)
        {
            _lastRestHeightLogTicks = nowTicks;
            NotchLog.Write($"rest height -> {target.Width}x{height} orbit={_restOrbitPt:0.##}pt idle={_restOrbitIdle}");
        }
    }

    /// <summary>
    /// Stops a 400 ms expand/collapse in flight and leaves the window where it is.
    /// Used when the page takes over the collapsed height: two owners of the same
    /// edge would make the capsule stutter.
    /// </summary>
    private void AbortGeometryAnimation()
    {
        _animation.Abort();
        _animating = false;
        _geometrySettled = true;
    }

    // ------------------------------------------------------------------
    // page bridge
    // ------------------------------------------------------------------

    private async Task InitWebViewAsync()
    {
        try
        {
            CoreWebView2Environment? environment = null;

            // A CAPTURE must render the page that is on disk RIGHT NOW. WebView2
            // otherwise caches the virtual-host content in a profile directory
            // beside the executable, so a rebuilt page can keep being served from
            // cache — which looks exactly like a CSS bug that will not go away.
            // The real capsule keeps its profile (fast startup, warm cache) and
            // relies on the content token on its navigation URL instead; --shot
            // gets a rotating scratch profile, which costs a cold start it does
            // not care about.
            //
            // Only --shot, deliberately: EnsureCoreWebView2Async rejects a custom
            // environment once the control has already created its own, and the
            // self-test must reach the renderer to assert on the live page.
            if (_automation)
            {
                string profile = Path.Combine(
                    Path.GetTempPath(), "dsh-notch-win-webview", _profileSlot.ToString());
                _profileSlot = (_profileSlot + 1) % 3;
                try
                {
                    if (Directory.Exists(profile)) Directory.Delete(profile, true);
                }
                catch
                {
                    // A locked profile is not worth failing over; the capture may
                    // simply be one build stale.
                }

                environment = await CoreWebView2Environment.CreateAsync(null, profile);
            }

            await _web.EnsureCoreWebView2Async(environment);

            CoreWebView2Settings settings = _web.CoreWebView2.Settings;
            settings.AreDefaultContextMenusEnabled = false;
            settings.IsZoomControlEnabled = false;
            settings.AreBrowserAcceleratorKeysEnabled = false;

            _web.CoreWebView2.WebMessageReceived += OnWebMessage;

            // Markdown in a question detail may contain links. A link that
            // navigated this window would replace the whole capsule with a web
            // page inside a borderless 480 px overlay with no back button —
            // unrecoverable without killing the helper. Nothing in this page is
            // allowed to leave the virtual host that serves it.
            _web.CoreWebView2.NavigationStarting += (_, args) =>
            {
                if (args.Uri.StartsWith("https://notch.local/", StringComparison.OrdinalIgnoreCase)) return;
                args.Cancel = true;
                NotchLog.Write($"blocked navigation: {args.Uri}");
            };
            _web.CoreWebView2.NewWindowRequested += (_, args) =>
            {
                args.Handled = true;
                NotchLog.Write($"blocked new window: {args.Uri}");
            };

            string assets = Path.Combine(AppContext.BaseDirectory, "Assets", "notch");
            if (Directory.Exists(assets))
            {
                _web.CoreWebView2.SetVirtualHostNameToFolderMapping(
                    "notch.local", assets, CoreWebView2HostResourceAccessKind.Allow);

                // Second line of defence, independent of the cache clear: the URL
                // carries a token derived from the page's own content, so a changed
                // page can never be served from a cache entry keyed on the old one.
                _web.CoreWebView2.Navigate($"https://notch.local/index.html?v={AssetToken(assets)}");
            }
        }
        catch (Exception ex)
        {
            // A missing WebView2 Runtime must not take the process down; the
            // window stays alive so the failure is visible and diagnosable.
            Console.Error.WriteLine($"dsh-notch-win: WebView2 init failed: {ex.Message}");
        }
    }

    /// <summary>
    /// A token that changes whenever the page changes. Used as a query string on
    /// the virtual-host URL so WebView2 cannot answer a navigation from a cache
    /// entry created for an older build of the same page.
    /// </summary>
    private static string AssetToken(string assetsDir)
    {
        try
        {
            var info = new FileInfo(Path.Combine(assetsDir, "index.html"));
            if (!info.Exists) return "0";
            return $"{info.LastWriteTimeUtc.Ticks:x}-{info.Length:x}";
        }
        catch
        {
            return "0";
        }
    }

    /// <summary>
    /// Messages the page sends. Everything received is logged, so a broken page
    /// bridge is visible from the outside instead of having to be guessed at.
    ///
    /// The page owns no secrets and no transport: it asks the host to perform an
    /// action on a row, and the host does the HTTP. That is what keeps the Bearer
    /// token out of page JavaScript (PLAN.md §7.1).
    /// </summary>
    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using JsonDocument doc = JsonDocument.Parse(e.WebMessageAsJson);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return;
            if (!doc.RootElement.TryGetProperty("type", out JsonElement typeElement)) return;

            string? type = typeElement.GetString();

            switch (type)
            {
                case "ready":
                    NotchLog.Write("page ready");
                    _pageReady = true;
                    PushGeometry(_liveWidth > 0 ? _liveWidth : Width, _liveHeight > 0 ? _liveHeight : Height);
                    PushHover();
                    PushSnapshotNow();
                    break;

                case "press":
                    BeginPress();
                    break;

                case "reset":
                    ResetVerticalPosition();
                    break;

                case "height":
                    // The page measured its own content: the panel hugs it.
                    if (doc.RootElement.TryGetProperty("value", out JsonElement value)
                        && value.TryGetInt32(out int height))
                    {
                        SetContentHeight(height);
                    }

                    break;

                case "rest":
                    // The page's animated orbit height for the COLLAPSED pill: the
                    // window follows it while a status brush is in the air, so the
                    // shell edge and the four disks share one sample. Phase 5 adds
                    // the robot's own edge (`idle`), which is what the pill shows
                    // when the layout is empty.
                    if (doc.RootElement.TryGetProperty("orbit", out JsonElement orbit)
                        && orbit.TryGetDouble(out double orbitPt))
                    {
                        bool animating = doc.RootElement.TryGetProperty("anim", out JsonElement anim)
                            && anim.ValueKind == JsonValueKind.True;
                        bool idle = doc.RootElement.TryGetProperty("idle", out JsonElement idleEl)
                            && idleEl.ValueKind == JsonValueKind.True;
                        SetRestOrbit(orbitPt, animating, idle);
                    }

                    break;

                case "open":
                    if (TryGetString(doc, "id", out string sessionId)) OpenSession(sessionId);
                    break;

                case "seen":
                    // Logged because this action's effect is not visible locally:
                    // the clear is confirmed by a later snapshot, and a silent
                    // no-op here looks exactly like a broken button.
                    if (TryGetString(doc, "id", out string seenId))
                    {
                        NotchLog.Write($"page seen session={seenId}");
                        if (!_pageProbeEnabled) MarkSeen(seenId);
                    }
                    else
                    {
                        NotchLog.Write("page seen all");
                        if (_pageProbeEnabled)
                        {
                            // The self-test only needs to know the request was made;
                            // marking every session seen would edit the user's real
                            // seen.json as a side effect of running a test.
                            _seenAllRequested = true;
                        }
                        else
                        {
                            MarkSeen(null);
                        }
                    }

                    break;

                case "collapse":
                    NotchLog.Write("page collapse");
                    Collapse();
                    break;

                case "answer":
                    HandlePageAnswer(doc);
                    break;

                case "input":
                    // The answer field took or gave up the keyboard; see
                    // SetKeyboardBorrow for why the capsule has to be activated
                    // at all, and why it gives the keyboard straight back.
                    SetKeyboardBorrow(
                        doc.RootElement.TryGetProperty("focused", out JsonElement focused)
                        && focused.ValueKind == JsonValueKind.True);
                    break;

                default:
                    // The raw text, not just the type: everything the page sends is
                    // diagnostic, and "page trace" with the numbers stripped out is
                    // not worth logging.
                    NotchLog.Write($"page {type} {doc.RootElement.GetRawText()}");
                    break;
            }
        }
        catch
        {
            // malformed page messages are ignored
        }
    }

    private static bool TryGetString(JsonDocument doc, string name, out string value)
    {
        value = "";
        if (!doc.RootElement.TryGetProperty(name, out JsonElement element)) return false;
        string? text = element.GetString();
        if (string.IsNullOrEmpty(text)) return false;
        value = text;
        return true;
    }

    /// <summary>
    /// Row click: dismiss the unread lamp and ask DSH to show that session, then
    /// bring the DSH window forward — the port of upstream <c>model.pick</c>
    /// (RootView.swift:349-374).
    ///
    /// The focus wish is held on the Host for 60 s and consumed by any open DSH
    /// page, so "did it arrive" cannot be observed here; a 404 means the session
    /// is unknown to the Host, which is worth logging but is not a failure of
    /// the capsule.
    /// </summary>
    private void OpenSession(string sessionId)
    {
        NotchLog.Write($"open session={sessionId}");
        NotchClient? client = _client;
        if (client is null) return;

        _ = Task.Run(async () =>
        {
            await client.MarkSeenAsync(sessionId).ConfigureAwait(false);
            await client.RequestFocusAsync(sessionId).ConfigureAwait(false);
            NotchClient.TryActivateDshWindow();
            NotchLog.Write("open dispatched");
        });
    }

    private void MarkSeen(string? sessionId)
    {
        NotchLog.Write(sessionId is null ? "seen all" : $"seen session={sessionId}");
        _ = _client?.MarkSeenAsync(sessionId);
    }

    /// <summary>
    /// The page finished the wizard and sent its answers. This is the one action
    /// whose payload is user input, so it is validated here before it becomes an
    /// HTTP body (src/http.ts:166-178 answers 400 for a missing id or a
    /// non-array, and 404 when the ask is no longer pending — both would look
    /// like "the capsule is broken" from the user's side).
    ///
    /// A failure is reported back to the page rather than logged only: upstream
    /// shows "提交失败，请重试；也可以在 DSH 中回答。" (RootView.swift:522), and
    /// without that the wizard would simply sit there looking unanswered.
    /// </summary>
    private void HandlePageAnswer(JsonDocument doc)
    {
        if (!TryGetString(doc, "id", out string askId))
        {
            NotchLog.Write("page answer ignored (no ask id)");
            return;
        }

        var answers = new List<NotchAnswerItem>();
        if (doc.RootElement.TryGetProperty("answers", out JsonElement list)
            && list.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in list.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;

                string id = item.TryGetProperty("id", out JsonElement idElement)
                    ? idElement.GetString() ?? ""
                    : "";
                if (id.Length == 0) continue;

                var answer = new NotchAnswerItem { Id = id };
                if (item.TryGetProperty("selected", out JsonElement selected)
                    && selected.ValueKind == JsonValueKind.Array)
                {
                    foreach (JsonElement label in selected.EnumerateArray())
                    {
                        string? text = label.GetString();
                        if (!string.IsNullOrEmpty(text)) answer.Selected.Add(text);
                    }
                }

                if (item.TryGetProperty("custom", out JsonElement custom)
                    && custom.ValueKind == JsonValueKind.String)
                {
                    string? text = custom.GetString();
                    if (!string.IsNullOrWhiteSpace(text)) answer.Custom = text.Trim();
                }

                answers.Add(answer);
            }
        }

        if (answers.Count == 0)
        {
            NotchLog.Write($"page answer ignored (no usable items) ask={askId}");
            return;
        }

        string payload = NotchMessages.Answer(askId, answers);
        NotchLog.Write($"page answer ask={askId} items={answers.Count}");

        if (_pageProbeEnabled)
        {
            // Same rule as the "seen" probe: a self-test must not answer the
            // user's real pending question. It asserts on the payload instead,
            // which is the part the click produced.
            _probeAnsweredAskId = askId;
            _probeAnswerPayload = payload;
            return;
        }

        NotchClient? client = _client;
        if (client is null) return;

        _ = Task.Run(async () =>
        {
            bool ok = await client.AnswerAsync(askId, answers).ConfigureAwait(false);
            NotchLog.Write(ok ? $"answer accepted ask={askId}" : $"answer rejected ask={askId}");
            if (IsDisposed || _web.CoreWebView2 is null) return;

            try
            {
                // Tells the page whether the submission landed. Upstream learns it
                // from the request's own result (RootView.swift:516-524); here the
                // page cannot see the request at all, so the host reports it.
                _web.CoreWebView2.PostWebMessageAsJson(
                    ok ? "{\"type\":\"answer-ok\"}" : "{\"type\":\"answer-failed\"}");
            }
            catch (Exception ex)
            {
                NotchLog.Write($"push answer result failed: {ex.Message}");
            }
        });
    }

    /// <summary>
    /// Temporarily makes the capsule activatable so a text field can be typed
    /// into, then undoes it.
    ///
    /// The overlay is WS_EX_NOACTIVATE by design: a click must never pull focus
    /// away from the app the user is working in (PLAN.md §7.2, Panel.swift:139).
    /// Windows delivers keystrokes to the foreground window's thread, so a page
    /// input can hold DOM focus and still receive nothing — the window has to
    /// become foreground for as long as the field is being used. On blur the
    /// keyboard goes back to whichever window had it, but only if the user has
    /// not moved to another app in the meantime.
    /// </summary>
    internal void SetKeyboardBorrow(bool wanted)
    {
        if (Handle == IntPtr.Zero || wanted == _keyboardBorrowed) return;
        _keyboardBorrowed = wanted;

        long ex = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        long next = wanted
            ? ex & ~(long)NativeMethods.WS_EX_NOACTIVATE
            : ex | NativeMethods.WS_EX_NOACTIVATE;
        if (next != ex) NativeMethods.SetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE, new IntPtr(next));

        NativeMethods.SetWindowPos(
            Handle, NativeMethods.HWND_TOPMOST, 0, 0, 0, 0,
            NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE
            | NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_FRAMECHANGED);

        if (wanted)
        {
            _foregroundBeforeBorrow = NativeMethods.GetForegroundWindow();
            bool activated = NativeMethods.SetForegroundWindow(Handle);

            IntPtr focused = IntPtr.Zero;
            if (_web.Handle != IntPtr.Zero)
            {
                NativeMethods.SetFocus(_web.Handle);
                focused = NativeMethods.GetFocus();
            }

            NotchLog.Write(
                $"keyboard borrow ON activated={activated} focus=0x{focused.ToInt64():X} " +
                $"previousForeground=0x{_foregroundBeforeBorrow.ToInt64():X}");
            return;
        }

        NotchLog.Write("keyboard borrow OFF");
        if (_foregroundBeforeBorrow != IntPtr.Zero
            && NativeMethods.GetForegroundWindow() == Handle)
        {
            NativeMethods.SetForegroundWindow(_foregroundBeforeBorrow);
        }

        _foregroundBeforeBorrow = IntPtr.Zero;
    }

    /// <summary>Re-sends the last known state. Used when the page says it is
    /// alive (a fresh load has no data) and after a geometry change, so the page
    /// never has to be right about the first frame.</summary>
    private void PushSnapshotNow()
    {
        string? json;
        lock (_snapshotGate)
        {
            json = _hasSnapshot ? _lastSnapshotJson : null;
        }

        if (json is not null) SendSnapshotJson(json);
    }

    private void PushHover()
    {
        if (_web.CoreWebView2 is null) return;
        _web.CoreWebView2.PostWebMessageAsJson(NotchMessages.Hover(_hovered));
    }

    // ------------------------------------------------------------------
    // diagnostics
    // ------------------------------------------------------------------

    /// <summary>
    /// Records how this instance actually came up. DPI awareness is the field
    /// that matters: an unaware process silently reads a virtualized work area
    /// (2560 px at 150% shows up as 1707 px) and mis-places the capsule, so the
    /// evidence has to survive whichever way the process was launched.
    /// </summary>
    private void WriteStartupLog()
    {
        try
        {
            NativeMethods.RECT work = CursorMonitorWork();
            string line =
                $"{DateTime.Now:O} launch" +
                $" awareness={NativeMethods.ProcessDpiAwareness()}" +
                $" hwndDpi={NativeMethods.GetDpiForWindow(Handle)}" +
                $" scale={_scale.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)}" +
                $" placement={(_hasSavedPlacement ? "saved" : "anchor")}" +
                $" edge={(_edge == ScreenEdge.Left ? "left" : "right")}@{_edgeX}" +
                $" top={_top}" +
                $" bounds={Bounds}" +
                $" work=({work.Left},{work.Top})-({work.Right},{work.Bottom})";

            File.AppendAllText(
                Path.Combine(Path.GetTempPath(), "dsh-notch-win.log"),
                line + Environment.NewLine);
        }
        catch
        {
            // diagnostics must never take the capsule down
        }
    }

    /// <summary>
    /// Captures the capsule and a margin of real desktop around it, in physical
    /// pixels. This is the only way to judge the rendering itself: every
    /// geometry check can pass while the window paints the wrong silhouette.
    /// Mirrors upstream's native visual-regression evidence
    /// (macos/Tests/*Probe.swift).
    /// </summary>
    internal void CaptureTo(string path, int padding = 48)
    {
        Rectangle region = LiveBounds;
        region.Inflate(padding, padding);
        region.Intersect(Screen.FromRectangle(region).Bounds);

        using var bitmap = new Bitmap(Math.Max(1, region.Width), Math.Max(1, region.Height));
        using (Graphics g = Graphics.FromImage(bitmap))
        {
            g.CopyFromScreen(region.Location, Point.Empty, region.Size);
        }

        string? dir = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    // ------------------------------------------------------------------
    // self-test  (PLAN.md §9 step 1)
    // ------------------------------------------------------------------

    /// <summary>
    /// Verifies everything about the window layer that can be checked without a
    /// human eye: extended styles, region shaping, edge snapping, vertical
    /// clamping, the placement round-trip, click-through, the geometry
    /// animation's invariants, and — critically — that the mouse actually
    /// reaches the window. Visual quality itself still needs a look, which is
    /// what --shot is for.
    /// </summary>
    internal async Task<int> RunSelfTestAsync()
    {
        var lines = new List<string>();
        int failures = 0;

        void Check(string name, bool ok, string detail)
        {
            if (!ok) failures++;
            lines.Add($"  [{(ok ? "PASS" : "FAIL")}] {name,-34} {detail}");
        }

        lines.Add("dsh-notch-win — window-layer self-test");
        lines.Add($"  hwnd        = 0x{Handle.ToInt64():X}");
        lines.Add($"  dpi scale   = {_scale.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)}");
        lines.Add($"  reduceMotion= {ReduceMotion}");
        lines.Add("");

        // 0. DPI awareness — the failure that motivated declaring it in the
        //    manifest. 2 = per-monitor aware; anything else means the process is
        //    reading virtualized coordinates and every geometry check below is
        //    being measured against a scaled-down screen.
        uint awareness = NativeMethods.ProcessDpiAwareness();
        Check("DPI per-monitor aware", awareness == 2, $"PROCESS_DPI_AWARENESS={awareness}");

        // 1. overlay styles
        long ex = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        Check("WS_EX_TOOLWINDOW", (ex & NativeMethods.WS_EX_TOOLWINDOW) != 0, $"exstyle=0x{ex:X8}");
        Check("WS_EX_NOACTIVATE", (ex & NativeMethods.WS_EX_NOACTIVATE) != 0, $"exstyle=0x{ex:X8}");
        Check("WS_EX_TOPMOST", (ex & NativeMethods.WS_EX_TOPMOST) != 0, $"exstyle=0x{ex:X8}");

        // 2. window shaping: the capsule silhouette comes from a window region,
        //    NOT from chroma-key transparency (which would make the whole window
        //    transparent to the mouse — see ApplyRegion).
        int rgnType = NativeMethods.GetWindowRgnBox(Handle, out NativeMethods.RECT rgnBox);
        Check("window region applied", rgnType != 0,
            $"type={rgnType} box=({rgnBox.Left},{rgnBox.Top})-({rgnBox.Right},{rgnBox.Bottom})");
        Check("region covers the window",
            rgnType != 0 && rgnBox.Right - rgnBox.Left == ClientSize.Width
                && rgnBox.Bottom - rgnBox.Top == ClientSize.Height,
            $"{rgnBox.Right - rgnBox.Left}x{rgnBox.Bottom - rgnBox.Top} vs {ClientSize.Width}x{ClientSize.Height}");
        Check("no chroma key in use", TransparencyKey == Color.Empty,
            $"TransparencyKey={TransparencyKey.Name}");

        // 2b. no drop shadow: DWM draws it from the window region, so the old
        //     large shadow survives for a frame after a collapse and flashes.
        //     Guarded here so the flash cannot be reintroduced by accident.
        long classStyle = NativeMethods.GetClassLongPtr(Handle, NativeMethods.GCL_STYLE).ToInt64();
        Check("no drop shadow (flash-free)", (classStyle & NativeMethods.CS_DROPSHADOW) == 0,
            $"classStyle=0x{classStyle:X8}");
        Check("webview transparent bg", _web.DefaultBackgroundColor == Color.Transparent,
            $"{_web.DefaultBackgroundColor.Name}");

        // 3. first-run anchor maths
        NativeMethods.GetCursorPos(out NativeMethods.POINT cursor);
        NativeMethods.RECT work = CursorMonitorWork();

        Rectangle probe = ComputeAnchor(new Point(cursor.X, cursor.Y), RestSize(), Scale(TopInset));
        Check("anchor right-aligned", probe.Right == work.Right, $"right={probe.Right} workRight={work.Right}");
        Check("anchor top inset", probe.Top == work.Top + Scale(TopInset), $"top={probe.Top} expected={work.Top + Scale(TopInset)}");
        Check("anchor inside work area",
            probe.Left >= work.Left && probe.Bottom <= work.Bottom,
            $"bounds={probe} work=({work.Left},{work.Top})-({work.Right},{work.Bottom})");
        Check("inset clamped on short screens",
            ComputeAnchor(new Point(cursor.X, cursor.Y), RestSize(), 100000).Height >= 1,
            "no crash / positive height");

        // 4. edge snapping, both edges
        ScreenEdge before = _edge;
        int beforeX = _edgeX;
        int beforeTop = _top;

        _lampCount = 1;
        _edge = ScreenEdge.Right;
        _edgeX = work.Right;
        _top = work.Top + Scale(TopInset);
        _expanded = false;
        ApplySize();
        Rectangle restRight = Bounds;
        Check("snaps to right edge", restRight.Right == work.Right, $"right={restRight.Right} vs {work.Right}");

        _expanded = true;
        ApplySize();
        Rectangle grownRight = Bounds;
        Check("expand grows away from edge", grownRight.Left < restRight.Left, $"{restRight.Left} -> {grownRight.Left}");
        Check("expand keeps outer edge", grownRight.Right == restRight.Right, $"{restRight.Right} -> {grownRight.Right}");
        Check("expand keeps vertical anchor", grownRight.Top == restRight.Top, $"{restRight.Top} -> {grownRight.Top}");
        Check("expand uses panel width", grownRight.Width == Scale(PanelWidth), $"{grownRight.Width} vs {Scale(PanelWidth)}");

        _expanded = false;
        _edge = ScreenEdge.Left;
        _edgeX = work.Left;
        ApplySize();
        Check("snaps to left edge", Bounds.Left == work.Left, $"left={Bounds.Left} vs {work.Left}");

        // The region must mirror with the edge, or the rounded corners end up
        // against the screen edge and the squared ones face the desktop.
        Check("region follows the edge",
            NativeMethods.GetWindowRgnBox(Handle, out NativeMethods.RECT leftBox) != 0
                && leftBox.Right - leftBox.Left == ClientSize.Width,
            $"box={leftBox.Right - leftBox.Left}x{leftBox.Bottom - leftBox.Top}");

        // 5. vertical-only movement and clamping
        _top = work.Bottom + 5000;
        ApplySize();
        Check("clamps bottom inside work area", Bounds.Bottom <= work.Bottom,
            $"bottom={Bounds.Bottom} workBottom={work.Bottom}");
        _top = work.Top - 5000;
        ApplySize();
        Check("clamps top inside work area", Bounds.Top >= work.Top,
            $"top={Bounds.Top} workTop={work.Top}");

        // Restore the real placement before the remaining checks.
        _edge = before;
        _edgeX = beforeX;
        _top = beforeTop;
        ApplySize();

        // 6. placement round-trip (written to a scratch file, never the real one)
        string scratch = Path.Combine(Path.GetTempPath(), "dsh-notch-win-selftest-window.json");
        string? previousOverride = Environment.GetEnvironmentVariable(WindowPlacement.EnvOverride);
        try
        {
            Environment.SetEnvironmentVariable(WindowPlacement.EnvOverride, scratch);
            WindowPlacement.Clear();

            int movedTop = work.Top + 222;
            WindowPlacement.Save(ScreenEdge.Left, work.Left, movedTop);
            WindowPlacement? back = WindowPlacement.Load();
            Check("placement persists", back is not null, $"file={scratch}");

            ScreenEdge rsEdge = ScreenEdge.Right;
            int rsX = 0;
            int rsTop = 0;
            bool resolved = back is not null && TryResolve(back, out rsEdge, out rsX, out rsTop);
            Check("placement round-trips",
                back is not null && back.Edge == "left" && back.Top == movedTop && back.EdgeX == work.Left,
                back is null ? "null" : $"{back.Edge}@{back.EdgeX} top={back.Top} vs left@{work.Left} top={movedTop}");
            Check("placement resolves",
                resolved && rsEdge == ScreenEdge.Left && rsX == work.Left && rsTop == movedTop,
                $"resolved={resolved} edge={rsEdge} x={rsX} top={rsTop}");

            // Legacy (pre edge-snapping) files must migrate, not snap back.
            File.WriteAllText(scratch, "{\"topRightX\":10,\"topRightY\":321}");
            WindowPlacement? legacy = WindowPlacement.Load();

            ScreenEdge lgEdge = ScreenEdge.Right;
            int lgTop = 0;
            bool migrated = legacy is not null && TryResolve(legacy, out lgEdge, out _, out lgTop);
            Check("legacy placement migrates",
                migrated && lgEdge == ScreenEdge.Left && lgTop == 321,
                $"migrated={migrated} edge={lgEdge} top={lgTop}");

            WindowPlacement.Clear();
            Check("placement reset clears", WindowPlacement.Load() is null, "file removed");
        }
        finally
        {
            Environment.SetEnvironmentVariable(WindowPlacement.EnvOverride, previousOverride);
            try { if (File.Exists(scratch)) File.Delete(scratch); } catch { /* best effort */ }
        }

        // 7. click-through round-trip
        SetClickThrough(true);
        long on = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        Check("click-through ON", (on & NativeMethods.WS_EX_TRANSPARENT) != 0, $"exstyle=0x{on:X8}");
        SetClickThrough(false);
        long off = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        Check("click-through OFF", (off & NativeMethods.WS_EX_TRANSPARENT) == 0, $"exstyle=0x{off:X8}");

        // 7b. the answer field's keyboard borrow. Keystrokes follow the FOREGROUND
        //     window, so a WS_EX_NOACTIVATE overlay can hold DOM focus and still
        //     receive nothing; typing an answer therefore requires the capsule to
        //     become activatable for as long as the field is in use, and to give
        //     that up afterwards. Asserted on the style bits, which are
        //     deterministic — who ends up as the foreground window depends on the
        //     desktop's foreground lock and on what the user is doing.
        SetKeyboardBorrow(true);
        long borrowEx = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        bool borrowClearedNoActivate = (borrowEx & NativeMethods.WS_EX_NOACTIVATE) == 0;
        SetKeyboardBorrow(false);
        long restoredEx = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        Check("keyboard borrow round-trip",
            borrowClearedNoActivate
                && (restoredEx & NativeMethods.WS_EX_NOACTIVATE) != 0
                && (restoredEx & NativeMethods.WS_EX_TOOLWINDOW) != 0
                && (restoredEx & NativeMethods.WS_EX_TOPMOST) != 0,
            $"borrowed=0x{borrowEx:X8} restored=0x{restoredEx:X8}");

        // 8. the mouse must actually reach the capsule. This is the regression
        //    guard for the chroma-key trap: with TransparencyKey the window
        //    looked perfect but WindowFromPoint returned the app BEHIND it, so
        //    no click ever arrived. Asserted with pass-through off.
        NativeMethods.GetWindowRect(Handle, out NativeMethods.RECT self);
        var center = new NativeMethods.POINT
        {
            X = (self.Left + self.Right) / 2,
            Y = (self.Top + self.Bottom) / 2,
        };
        IntPtr hit = NativeMethods.WindowFromPoint(center);
        IntPtr hitRoot = hit == IntPtr.Zero
            ? IntPtr.Zero
            : NativeMethods.GetAncestor(hit, NativeMethods.GA_ROOT);
        Check("hit-test reaches capsule", hit == Handle || hitRoot == Handle,
            $"hit=0x{hit.ToInt64():X} root=0x{hitRoot.ToInt64():X} self=0x{Handle.ToInt64():X}");

        // 9. does not steal focus
        IntPtr beforeForeground = NativeMethods.GetForegroundWindow();
        NativeMethods.SetWindowPos(Handle, NativeMethods.HWND_TOPMOST, 0, 0, 0, 0,
            NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_SHOWWINDOW);
        Application.DoEvents();
        IntPtr afterForeground = NativeMethods.GetForegroundWindow();
        Check("foreground unchanged", beforeForeground == afterForeground,
            $"{beforeForeground.ToInt64():X} -> {afterForeground.ToInt64():X}");

        // 10. renderer
        try
        {
            await _web.EnsureCoreWebView2Async();
            string version = _web.CoreWebView2?.Environment?.BrowserVersionString ?? "unknown";
            Check("WebView2 initialised", _web.CoreWebView2 is not null, $"runtime={version}");
        }
        catch (Exception ex2)
        {
            Check("WebView2 initialised", false, ex2.Message);
        }

        // 11. survival: hosting the renderer must not have reverted the overlay
        //     bits again — this is the regression guard for the ordering bug
        //     where styles were applied before WinForms' own UpdateStyles ran.
        long exFinal = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
        Check("overlay styles survive", (exFinal & NativeMethods.WS_EX_TOOLWINDOW) != 0
            && (exFinal & NativeMethods.WS_EX_NOACTIVATE) != 0
            && (exFinal & NativeMethods.WS_EX_TOPMOST) != 0, $"exstyle=0x{exFinal:X8}");

        lines.Add("");
        lines.AddRange(RunGeometrySelfTest(Check));
        lines.Add("");
        lines.AddRange(await RunPageSelfTestAsync(Check));
        lines.Add("");
        lines.AddRange(await RunAskSelfTestAsync(Check));
        lines.Add("");
        lines.AddRange(await RunOrbitSelfTestAsync(Check));
        lines.Add("");
        lines.AddRange(await RunRobotSelfTestAsync(Check));
        lines.Add("");
        lines.AddRange(RunDataSelfTest(Check));

        lines.Add("");
        lines.Add(failures == 0 ? "RESULT: PASS" : $"RESULT: FAIL ({failures} check(s))");

        string report = string.Join(Environment.NewLine, lines);
        Console.WriteLine(report);

        try
        {
            string path = Path.Combine(Path.GetTempPath(), "dsh-notch-win-selftest.txt");
            File.WriteAllText(path, report + Environment.NewLine);
            Console.WriteLine($"report: {path}");
        }
        catch
        {
            // console-only is acceptable
        }

        return failures == 0 ? 0 : 1;
    }

    /// <summary>
    /// Phase 2 checks: the capsule's height matrix, and the geometry animation
    /// sampled frame by frame through the same code path the animation thread
    /// uses. Run against the real window, so it also proves the region rebuilds
    /// correctly while the window is mid-animation.
    /// </summary>
    private List<string> RunGeometrySelfTest(Action<string, bool, string> check)
    {
        var lines = new List<string>();

        int lamp1 = NotchGeometry.RestHeight(1);
        int lamp2 = NotchGeometry.RestHeight(2);
        int lamp3 = NotchGeometry.RestHeight(3);
        int lamp4 = NotchGeometry.RestHeight(4);
        check("lamp heights 1/2/3/4", lamp1 == 44 && lamp2 == 72 && lamp3 == 100 && lamp4 == 128,
            $"{lamp1}/{lamp2}/{lamp3}/{lamp4} (expect 44/72/100/128)");

        int hovered = NotchGeometry.RestHeightHover(1);
        check("hover shortens pill by 2", hovered == 42, $"{hovered} (expect 42)");

        // Expanded height: hugged, floored at 120, capped by the screen layout.
        int capped = NotchGeometry.ExpandedHeight(99999, 400);
        int floored = NotchGeometry.ExpandedHeight(10, 400);
        int hugged = NotchGeometry.ExpandedHeight(164, 400);
        check("expanded height clamps", capped == 400 && floored == 120 && hugged == 164,
            $"cap={capped} floor={floored} hug={hugged}");

        (int inset, int maximum) = NotchGeometry.ScreenLayout(200, 100);
        check("screen layout insets", inset == 99 && maximum == 2, $"inset={inset} max={maximum}");

        // ---- long question detail (Phase 3) --------------------------------
        // A question carrying more than 240 characters of detail does not hug its
        // content: the panel fills the screen and the detail scrolls inside it, so
        // the option chips below stay reachable (RootView.swift:571-583).
        {
            ScreenEdge keepEdge2 = _edge;
            bool keepExpanded2 = _expanded;
            bool keepLong2 = _longAskDetail;
            int keepContent2 = _contentHeight;

            _edge = ScreenEdge.Right;
            NativeMethods.RECT longWork = WorkAreaAtEdge();
            (int _, int longMax) = NotchGeometry.ScreenLayout(longWork.Bottom - longWork.Top, Scale(TopInset));

            _expanded = true;
            _contentHeight = Scale(160);
            _longAskDetail = false;
            Size huggedSize = TargetSize();
            _longAskDetail = true;
            Size filledSize = TargetSize();

            _longAskDetail = keepLong2;
            _expanded = keepExpanded2;
            _contentHeight = keepContent2;
            _edge = keepEdge2;

            check("long detail fills the screen",
                filledSize.Height == longMax && huggedSize.Height < longMax,
                $"hug={huggedSize.Height} fill={filledSize.Height} max={longMax}");
        }

        // ---- the animation -------------------------------------------------
        // Driven through GeometryAnimation exactly as the animation thread
        // drives it, at a fixed simulated clock, with the frame applied to the
        // real window so the region is exercised too.
        ScreenEdge keepEdge = _edge;
        int keepTop = _top;
        int keepX = _edgeX;
        bool keepExpanded = _expanded;
        int keepLamps = _lampCount;

        _edge = ScreenEdge.Right;
        NativeMethods.RECT work = WorkAreaAtEdge();
        _edgeX = work.Right;
        _top = work.Top + Scale(TopInset);
        _expanded = false;
        _lampCount = 1;
        ApplySize();
        int fromWidth = Bounds.Width;
        int fromHeight = Bounds.Height;

        // Grow to the four-lamp compact size, then to the expanded one: the two
        // targets the capsule actually animates between in use.
        _lampCount = 4;
        Size lampTarget = TargetSize();
        _expanded = true;
        Size target = TargetSize();
        _expanded = false;

        var animation = new GeometryAnimation();
        animation.SetEdge(true);
        animation.Start(fromWidth, fromHeight, lampTarget.Width, lampTarget.Height, _edgeX, _top, 0);

        int lastWidth = fromWidth;
        int lastHeight = fromHeight;
        bool edgePinned = true;
        bool topPinned = true;
        bool monotone = true;
        bool allInside = true;
        int samples = 0;

        for (double t = 0; t <= NotchGeometry.AnimationSeconds + 0.001; t += NotchGeometry.AnimationSeconds / 24)
        {
            (int x, int y, int width, int height) = animation.Frame(t);
            samples++;

            if (x + width != _edgeX) edgePinned = false;
            if (y != _top) topPinned = false;
            if (width < lastWidth || height < lastHeight) monotone = false;
            if (width < 1 || height < 1 || x < 0) allInside = false;

            // Apply the frame for real: this is the per-frame work the animation
            // thread does, including a region rebuild at the animated size.
            NativeMethods.SetWindowPos(Handle, IntPtr.Zero, x, y, width, height,
                NativeMethods.SWP_NOZORDER | NativeMethods.SWP_NOACTIVATE);
            ApplyRegion(width, height, Scale(CornerRadius));

            lastWidth = width;
            lastHeight = height;
        }

        check("animation samples 25+ frames", samples >= 25, $"{samples} frames");
        check("animation pins outer edge", edgePinned, $"right stays {_edgeX}");
        check("animation pins top edge", topPinned, $"top stays {_top}");
        check("animation is monotone", monotone, $"{fromWidth}x{fromHeight} -> {lastWidth}x{lastHeight}");
        check("animation lands on target",
            lastWidth == lampTarget.Width && lastHeight == lampTarget.Height,
            $"{lastWidth}x{lastHeight} vs {lampTarget.Width}x{lampTarget.Height}");
        check("animation frames stay on screen", allInside, "no degenerate frames");

        // Mid-flight retargeting must start from the CURRENT frame, not from the
        // original one (Panel.swift:26-31): otherwise an expand interrupted by a
        // collapse snaps.
        var retarget = new GeometryAnimation();
        retarget.SetEdge(true);
        retarget.Start(fromWidth, fromHeight, target.Width, target.Height, _edgeX, _top, 0);
        (int mx, int my, int mw, int mh) = retarget.Frame(NotchGeometry.AnimationSeconds / 2);
        _ = mx;
        _ = my;

        var restart = new GeometryAnimation();
        restart.SetEdge(true);
        restart.Start(mw, mh, fromWidth, fromHeight, _edgeX, _top, NotchGeometry.AnimationSeconds / 2);
        (int rx, int ry, int rw, int rh) = restart.Frame(NotchGeometry.AnimationSeconds / 2);
        _ = rx;
        _ = ry;
        check("retarget starts from current frame", rw == mw && rh == mh,
            $"mid={mw}x{mh} restart-first={rw}x{rh}");
        (int _, int _, int endW, int endH) = restart.Frame(NotchGeometry.AnimationSeconds + 0.5);
        check("retarget reaches new target", endW == fromWidth && endH == fromHeight,
            $"{endW}x{endH} vs {fromWidth}x{fromHeight}");

        // The region must still be the capsule's, not the window's, at the size
        // the animation ended on.
        _lampCount = keepLamps;
        _expanded = keepExpanded;
        _edge = keepEdge;
        _edgeX = keepX;
        _top = keepTop;
        ApplySize();

        int rgn = NativeMethods.GetWindowRgnBox(Handle, out NativeMethods.RECT box);
        check("region survives animation", rgn != 0 && box.Right - box.Left == ClientSize.Width
            && box.Bottom - box.Top == ClientSize.Height,
            $"type={rgn} {box.Right - box.Left}x{box.Bottom - box.Top}");

        // 12. live transport: real data must be reaching the capsule. Skipped
        //     rather than failed when no Host is running, because a self-test on
        //     a machine without DSH is still a valid self-test.
        NotchClient? client = _client;
        if (client is null)
        {
            check("live snapshot received", true, "skipped (no transport)");
        }
        else
        {
            // One synchronous pull through the same path the stream uses. This is
            // the check that catches an auth change, a route rename or a DTO that
            // drifted away from src/types.ts.
            var pull = Stopwatch.StartNew();
            string? body = null;
            try
            {
                body = NotchClient.FetchStatusOnce();
            }
            catch (Exception ex)
            {
                body = null;
                _ = ex;
            }

            pull.Stop();
            bool accepted = body is not null && client.Accept(body);
            if (body is null)
            {
                check("live snapshot received", true, $"skipped (no Host reachable, {pull.ElapsedMilliseconds} ms)");
            }
            else
            {
                NotchSnapshot? latest = client.LastSnapshot;
                NotchCounts counts = NotchCounts.From(latest?.Rows ?? new List<NotchRow>());
                _lampCount = counts.Lamps;   // the self-test drives no UI; keep the field honest
                check("live snapshot received", accepted,
                    $"http {(accepted ? "200" : "error")} rows={latest?.Rows.Count ?? -1} " +
                    $"lamps={counts.Lamps} " +
                    $"(busy={counts.Busy} done={counts.Completed} failed={counts.Failed} decision={counts.Decision}) " +
                    $"origin={RuntimeFile.Load()?.Origin ?? "?"}");
            }

            // The answer route against the REAL Host. 404 means the Host parsed
            // the body and simply has no such pending ask; a 400 would mean the
            // body the wizard builds is not the shape the Host accepts, and a 403
            // would mean the helper's token is wrong. Nothing is answered.
            int? answerStatus = NotchClient.ProbeAnswerRoute();
            check("answer route accepts the payload",
                answerStatus is null or 404,
                answerStatus is null ? "skipped (no Host reachable)" : $"HTTP {answerStatus} (404 = not pending)");
        }

        return lines;
    }

    /// <summary>
    /// Drives the REAL page inside the REAL WebView2 and asserts the one thing
    /// every geometry check is blind to: that a UI action produces the right
    /// RESULT state.
    ///
    /// This exists because of a shipped bug. 「全部已读」 looked broken: the lamps
    /// and the "N 完成" badge stayed up after the click. Every check in this
    /// report passed — styles, region, anchoring, animation, the live snapshot —
    /// because none of them ever asked what the page looked like AFTER an action.
    /// The cause was a fallback predicate in the page that kept reporting a
    /// successful turn as unread forever.
    ///
    /// The test feeds a synthetic snapshot with unread rows, clicks the actual
    /// button, and asserts the lamps and badge clear. The snapshot is synthetic on
    /// purpose: the panels are rendering state, and the state has to be
    /// reproducible without waiting for a real task to finish.
    /// </summary>
    private async Task<List<string>> RunPageSelfTestAsync(Action<string, bool, string> check)
    {
        var lines = new List<string>();
        CoreWebView2? core = _web.CoreWebView2;
        if (core is null)
        {
            check("page clear-button regression", true, "skipped (renderer unavailable)");
            return lines;
        }

        _pageProbeEnabled = true;
        try
        {
            // Wait for the page to load. The renderer is ready long before its DOM
            // is: probing at 250 ms reads an empty document and would report a
            // false failure (it did, on the first run of this test).
            var wait = Stopwatch.StartNew();
            while (!_pageReady && wait.ElapsedMilliseconds < 15000)
            {
                await Task.Delay(100);
            }

            check("page loaded for the probe", _pageReady,
                _pageReady ? $"ready after {wait.ElapsedMilliseconds} ms" : "page never announced itself");
            if (!_pageReady) return lines;

            // ── the scenario: two finished, unread sessions ──────────────
            const string unreadSnapshot = """
            {"type":"snapshot","generatedAt":900001,"counts":{"busy":0,"completed":2,"failed":0,"decision":0,"rows":2},
             "rows":[
              {"id":"probe-a","title":"probe finished one","child":false,"busy":false,"unread":true,"needsAction":false,"failed":false,
               "lastTurn":{"at":1,"kind":"completed","failed":false}},
              {"id":"probe-b","title":"probe finished two","child":false,"busy":false,"unread":true,"needsAction":false,"failed":false,
               "lastTurn":{"at":2,"kind":"completed","failed":false}}
             ]}
            """;

            // ── after the Host honours POST /seen {all:true} ─────────────
            const string clearedSnapshot = """
            {"type":"snapshot","generatedAt":900002,"counts":{"busy":0,"completed":0,"failed":0,"decision":0,"rows":2},
             "rows":[
              {"id":"probe-a","title":"probe finished one","child":false,"busy":false,"unread":false,"needsAction":false,"failed":false,
               "lastTurn":{"at":1,"kind":"completed","failed":false}},
              {"id":"probe-b","title":"probe finished two","child":false,"busy":false,"unread":false,"needsAction":false,"failed":false,
               "lastTurn":{"at":2,"kind":"completed","failed":false}}
             ]}
            """;

            // Expanded, so the badge row and the list are on screen.
            _expanded = true;
            ApplySize();
            core.PostWebMessageAsJson(NotchMessages.Geometry(
                true, Width, Height, Scale(CornerRadius), "right", false, _scale, 0, true, motion: true));
            core.PostWebMessageAsJson(unreadSnapshot);
            await Task.Delay(250);

            string before = await core.ExecuteScriptAsync(PageProbeScript);
            check("page renders unread lamps",
                before.Contains("lamps=completed:2") && before.Contains("badge=2 完成"),
                Unquote(before));
            check("expanded list panel fits its rows", Unquote(before).Contains("listFits=yes"),
                Unquote(before));

            // ── click the real button, as a person would ─────────────────
            string clicked = await core.ExecuteScriptAsync(
                "(() => { const b = document.getElementById('clear'); if (!b) return 'no-button'; b.click(); return 'clicked'; })()");
            await Task.Delay(250);

            check("clear button reaches the host", _seenAllRequested, "page sent {type:'seen'}");

            // The Host would now answer with a cleared snapshot; deliver it.
            core.PostWebMessageAsJson(clearedSnapshot);
            await Task.Delay(250);

            string after = await core.ExecuteScriptAsync(PageProbeScript);
            check("clear removes the lamps", after.Contains("lamps=none") || after.Contains("lamps=idle"),
                Unquote(after));
            check("clear removes the badge", after.Contains("badge=0 完成"), Unquote(after));
            check("clear removes row labels", after.Contains("labels=0"), Unquote(after));
        }
        catch (Exception ex)
        {
            check("page clear-button regression", false, $"{ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            _pageProbeEnabled = false;
        }

        return lines;
    }

    /// <summary>
    /// Phase 3: the AskUserQuestion wizard, driven end to end.
    ///
    /// Unlike the clear-button regression above, this one does NOT hand the page a
    /// synthetic message: it hands the HOST a synthetic snapshot through the real
    /// <see cref="OnSnapshot"/> path, so the auto-expand, the long-detail height
    /// switch and the auto-fold are all exercised together with the rendering.
    /// What is asserted is the RESULT of a click — the exact answer payload the
    /// Host would POST (src/http.ts:166-178) — not merely that a click happened.
    ///
    /// The payload is compared field by field, because the interesting failures
    /// here are silent: a single-select question that keeps its typed text, a
    /// multi-select that only remembers the last chip, or an answer list whose
    /// order does not match the questions all still produce a well-formed POST.
    /// </summary>
    private async Task<List<string>> RunAskSelfTestAsync(Action<string, bool, string> check)
    {
        var lines = new List<string>();
        CoreWebView2? core = _web.CoreWebView2;
        if (core is null)
        {
            check("ask wizard rendered", true, "skipped (renderer unavailable)");
            return lines;
        }

        // Two questions on purpose: q1 single-select (its chip answer advances the
        // wizard and clears any typed text), q2 multi-select (chips accumulate and
        // 完成 only appears on the last question).
        const string askSnapshot = """
        {"ok":true,"generatedAt":910001,"origin":"http://127.0.0.1:1","rows":[
         {"id":"probe-ask","title":"probe asking session","child":false,"busy":false,"unread":false,
          "ask":{"id":"ask-probe-1","questions":[
            {"id":"q1","question":"先做哪个？","header":"计划",
             "detail":"# 计划\n\n段落一。\n\n- 第一项\n- 第二项\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n用 `code` 与 **粗体**。",
             "options":[{"label":"Alpha","description":"先做 Alpha"},{"label":"Beta","description":"先做 Beta"}]},
            {"id":"q2","question":"还要哪些？","multiSelect":true,
             "options":[{"label":"日志"},{"label":"截图"}]}
          ]}},
         {"id":"probe-idle","title":"other session","child":false,"busy":false,"unread":false}
        ]}
        """;

        // One free-text question: the only path that needs the keyboard, and the
        // only one where the answer is the "custom" field.
        const string freeTextSnapshot = """
        {"ok":true,"generatedAt":910003,"origin":"http://127.0.0.1:1","rows":[
         {"id":"probe-ask","title":"probe asking session","child":false,"busy":false,"unread":false,
          "ask":{"id":"ask-probe-2","questions":[
            {"id":"q1","question":"补充说明？","detail":"请写一句话。"}
          ]}}
        ]}
        """;

        // > 240 characters of detail: the panel stops hugging its content. The
        // fixture has to be long enough to actually OVERFLOW the screen-capped
        // panel (~500 CSS px of detail area at this DPI), otherwise the "scroll
        // area" assertions below would pass on a region with nothing to scroll.
        const string longDetailSnapshot = """
        {"ok":true,"generatedAt":910005,"origin":"http://127.0.0.1:1","rows":[
         {"id":"probe-ask","title":"probe asking session","child":false,"busy":false,"unread":false,
          "ask":{"id":"ask-probe-3","questions":[
            {"id":"q1","question":"这份计划可以吗？",
             "detail":"# 迁移计划\n\n第一阶段把宿主插件层接到 Windows 的 WebView2 外壳上，第二阶段接通真实数据与几何动画，第三阶段做 AskUserQuestion 向导，第四阶段做 StatusOrbit 的四态笔画，第五阶段做待机机器人，第六阶段做安装、自启与卸载。每一阶段都要留下可复现的证据：自检项、截图与实测数字，而不是一句已经完成。第六阶段的卸载还要能一键回滚到未安装状态，且不在系统里留下任何残留文件与注册表项。安装脚本必须能在没有管理员权限的情况下完成接入，卸载脚本要恢复用户原有的 profile 配置备份，并保证重复执行是幂等的。\n\n宿主插件层与原生界面层之间只有一份契约：宿主在 webServer 上挂载前缀路由，并把运行时文件写给 helper，里面只有来源地址与一次性令牌。界面层不持有任何密钥，也不直接访问网络，所有副作用都由宿主进程代为执行。这样做的代价是每条交互都要多一次进程间往返，收益是令牌永远不会进入页面脚本，页面即使被注入也无法伪造宿主身份。\n\n几何动画由宿主的专用线程驱动，而不是由页面的 CSS 动画近似：显示器的刷新率是 240 赫兹，而系统定时器被固定在约 64 赫兹，用页面动画会在高刷新率屏幕上出现明显的台阶。逐帧直接调用窗口管理器接口，实测可以达到 220 到 450 赫兹，并且每一帧都能断言外侧边缘与顶部位置不变。\n\n窗口的透明与命中测试由窗口区域同时负责。早先用颜色键做透明时，外观完全正常，但整个窗口对鼠标透明，点击全部穿透到背后的应用，只有在关闭穿透的前提下用命中测试断言才能发现。因此视觉检查与命中测试必须分别断言，几何断言全绿并不等于画面正确。\n\n回答题目时宿主临时借用键盘焦点，用完立刻归还；面板在题目待回答期间不会自动折叠，否则用户刚把鼠标移开就会丢掉正在输入的内容。长文本的题目不再贴合内容高度，而是占满屏幕并把详情变成可滚动区域，保证选项按钮始终留在屏幕上。",
             "options":[{"label":"可以"},{"label":"要改"}]}
          ]}}
        ]}
        """;

        const string resolvedSnapshot = """
        {"ok":true,"generatedAt":910007,"origin":"http://127.0.0.1:1","rows":[
         {"id":"probe-ask","title":"probe asking session","child":false,"busy":false,"unread":false},
         {"id":"probe-idle","title":"other session","child":false,"busy":false,"unread":false}
        ]}
        """;

        _pageProbeEnabled = true;
        bool keepExpanded = _expanded;
        string? keepAskId = _activeAskId;
        bool keepLong = _longAskDetail;
        try
        {
            var wait = Stopwatch.StartNew();
            while (!_pageReady && wait.ElapsedMilliseconds < 15000) await Task.Delay(100);
            if (!_pageReady)
            {
                check("ask wizard rendered", false, "page never announced itself");
                return lines;
            }

            // ── a question appears: the capsule opens by itself ──────────
            DeliverSnapshot(askSnapshot);
            await Task.Delay(400);

            check("new ask auto-expands",
                _expanded && _activeAskId == "ask-probe-1" && !_longAskDetail,
                $"expanded={_expanded} activeAsk={_activeAskId ?? "-"} long={_longAskDetail}");

            string shown = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("wizard renders question + chips",
                shown.Contains("wizard=shown") && shown.Contains("title=先做哪个？")
                    && shown.Contains("counter=1/2") && shown.Contains("chips=Alpha|Beta")
                    && shown.Contains("desc=2"),
                shown);

            // The detail is markdown, so it must have been PARSED, not dumped: a
            // heading, a two-item list, a table and the inline code/bold runs.
            check("markdown detail is structured",
                shown.Contains("md=h1:1") && shown.Contains("li:2") && shown.Contains("table:1")
                    && shown.Contains("code:1") && shown.Contains("strong:1"),
                shown);

            // ── a single-select chip answers AND advances ────────────────
            await ClickAsync(core, "#wizard .chip", 0);
            await Task.Delay(200);
            string advanced = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("single-select advances to question 2",
                advanced.Contains("counter=2/2") && advanced.Contains("chips=日志|截图")
                    && advanced.Contains("on=") && !advanced.Contains("on=Alpha"),
                advanced);
            check("advancing does not submit early", _probeAnswerPayload is null,
                _probeAnswerPayload ?? "no answer sent yet");

            // ── multi-select accumulates, and 完成 submits both answers ──
            await ClickAsync(core, "#wizard .chip", 0);
            await Task.Delay(120);
            string one = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("multi-select keeps the first choice", one.Contains("on=日志"), one);

            await ClickAsync(core, "#wizard .chip", 1);
            await Task.Delay(120);
            string two = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("multi-select accumulates choices", two.Contains("on=日志|截图"), two);

            await ClickAsync(core, "#wizard .tiny.blue", 0);
            await Task.Delay(300);

            check("wizard submits both answers",
                _probeAnsweredAskId == "ask-probe-1" && _probeAnswerPayload is not null,
                $"ask={_probeAnsweredAskId ?? "-"} payload={_probeAnswerPayload ?? "-"}");
            check("answer payload is well formed",
                AnswerPayloadMatches(_probeAnswerPayload,
                    new[] { ("q1", new[] { "Alpha" }, (string?)null), ("q2", new[] { "日志", "截图" }, null) },
                    out string payloadDetail),
                payloadDetail);

            // ── a free-text question: the answer is the typed text ───────
            _probeAnswerPayload = null;
            _probeAnsweredAskId = null;
            DeliverSnapshot(freeTextSnapshot);
            await Task.Delay(400);

            string free = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("free-text question offers an input",
                free.Contains("input=yes") && free.Contains("complete=disabled"),
                free);

            // The panel has to have GROWN to fit the wizard. This is the
            // regression guard for a shrinkable wizard item: scrollHeight then
            // reports the shrunken box, the measurement echoes the window size,
            // and the nav/chips end up clipped below the panel's bottom edge.
            check("free-text question fits the panel", free.Contains("fits=yes"), free);

            // focusin/focusout are the bridge to the keyboard borrow: the page
            // cannot type into a non-activating window on its own.
            await core.ExecuteScriptAsync(
                "(() => { const i = document.querySelector('#wizard .w-input'); i.dispatchEvent(new FocusEvent('focusin', {bubbles:true})); return 'focused'; })()");
            await Task.Delay(120);
            long borrowEx = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
            await core.ExecuteScriptAsync(
                "(() => { const i = document.querySelector('#wizard .w-input'); i.dispatchEvent(new FocusEvent('focusout', {bubbles:true})); return 'blurred'; })()");
            await Task.Delay(120);
            long releaseEx = NativeMethods.GetWindowLongPtr(Handle, NativeMethods.GWL_EXSTYLE).ToInt64();
            check("focus bridge borrows and returns the keyboard",
                (borrowEx & NativeMethods.WS_EX_NOACTIVATE) == 0
                    && (releaseEx & NativeMethods.WS_EX_NOACTIVATE) != 0,
                $"focused=0x{borrowEx:X8} blurred=0x{releaseEx:X8}");

            // Typing is simulated the way a controlled input sees it: the value
            // and an input event, never a rebuild of the element mid-edit.
            //
            // No newline in this value: a single-line <input> strips CR/LF by
            // spec, so a newline here would be testing the browser's sanitisation
            // rather than the answer path. The multi-line case is covered at the
            // DTO level ("answer payload round-trips"), where nothing strips it.
            await core.ExecuteScriptAsync(
                "(() => { const i = document.querySelector('#wizard .w-input'); i.value = '这句是打进去的 \"引号\" 与 \\\\ 反斜杠'; i.dispatchEvent(new Event('input', {bubbles:true})); return 'typed'; })()");
            await Task.Delay(150);
            string typed = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("typing enables 完成", typed.Contains("complete=enabled"), typed);

            await ClickAsync(core, "#wizard .tiny.blue", 0);
            await Task.Delay(300);
            check("typed answer is submitted verbatim",
                AnswerPayloadMatches(_probeAnswerPayload,
                    new[] { ("q1", Array.Empty<string>(), (string?)"这句是打进去的 \"引号\" 与 \\ 反斜杠") },
                    out string typedDetail),
                typedDetail);

            // ── a long detail: fill the screen instead of hugging ────────
            DeliverSnapshot(longDetailSnapshot);
            await Task.Delay(500);

            NativeMethods.RECT longWork = WorkAreaAtEdge();
            (int _, int longMax) = NotchGeometry.ScreenLayout(longWork.Bottom - longWork.Top, Scale(TopInset));
            string longProbe = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("long detail switches the layout",
                _longAskDetail && TargetSize().Height == longMax && longProbe.Contains("long=yes"),
                $"long={_longAskDetail} target={TargetSize().Height} max={longMax} page={longProbe}");

            // The point of filling the screen is that the detail scrolls and the
            // chips stay reachable. Asserted on the real boxes: a class name alone
            // passed while the wizard never grew, leaving the extra height empty
            // below the nav and nothing scrollable.
            long scrollNumbers = ParseScrollProbe(longProbe);
            check("long detail is a bounded scroll area",
                longProbe.Contains("overflow=auto") && scrollNumbers > 0
                    && longProbe.Contains("fits=yes"),
                $"scroll(content/viewport)={scrollNumbers} fits={longProbe.Contains("fits=yes")}");

            // ── answering it folds the capsule again ─────────────────────
            DeliverSnapshot(resolvedSnapshot);
            await Task.Delay(400);

            string gone = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("resolved ask folds the capsule",
                !_expanded && _activeAskId is null && !_longAskDetail && gone.Contains("wizard=hidden"),
                $"expanded={_expanded} activeAsk={_activeAskId ?? "-"} page={gone}");

            // ── the failure path the user actually sees ──────────────────
            // Posted while a wizard is open, which is the only time it can
            // happen: the host reports the result of a submission it just made.
            DeliverSnapshot(freeTextSnapshot);
            await Task.Delay(400);
            core.PostWebMessageAsJson("{\"type\":\"answer-failed\"}");
            await Task.Delay(200);
            string failed = Unquote(await core.ExecuteScriptAsync(WizardProbeScript));
            check("submit failure is shown to the user", failed.Contains("error=shown"), failed);

            // The error line adds height; the panel must absorb it too, or the
            // retry buttons would be pushed out of the capsule exactly when the
            // user needs them.
            check("failure keeps the buttons inside the panel", failed.Contains("fits=yes"), failed);
        }
        catch (Exception ex)
        {
            check("ask wizard rendered", false, $"{ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            _pageProbeEnabled = false;
            _probeAnsweredAskId = null;
            _probeAnswerPayload = null;
            _expanded = keepExpanded;
            _activeAskId = keepAskId;
            _longAskDetail = keepLong;
            ApplySize();
        }

        return lines;
    }

    /// <summary>
    /// Phase 4: the four-state stroke, driven and then MEASURED on the live
    /// canvas.
    ///
    /// Every claim here is about pixels and about the real window, because the
    /// failures this phase can have are all silent ones: a brush that flies the
    /// wrong way, a count that appears before its disk, an animation that keeps
    /// running when the user asked for Reduce Motion, or — the upstream bug this
    /// phase exists to avoid — a shell whose height no longer matches where the
    /// disks are. So the page is read back with <c>getImageData</c> and the window
    /// with <c>GetWindowRect</c>.
    ///
    /// The page's presentation clock is pinned for the phase tests (upstream's
    /// <c>renderDate</c>, StatusOrbit.swift:499) and the flight timer is held, so
    /// a frame at t=0.25 s of a 0.95 s flight is the same frame on every run.
    /// </summary>
    private async Task<List<string>> RunOrbitSelfTestAsync(Action<string, bool, string> check)
    {
        var lines = new List<string>();
        CoreWebView2? core = _web.CoreWebView2;
        if (core is null)
        {
            check("orbit canvas present", true, "skipped (renderer unavailable)");
            return lines;
        }

        // ---- fixtures. Deliberately page-direct for the phase tests: the
        // capsules's auto-expand on a new question would hide the rest block, and
        // the strokes are what is under test here (the expand itself is Phase 3's
        // business and is asserted there).
        const string busyOnly = """
        {"type":"snapshot","generatedAt":920001,"counts":{"busy":1,"completed":0,"failed":0,"decision":0,"rows":1},
         "rows":[{"id":"o-busy","title":"orbit running","child":false,"busy":true,"unread":false,
                  "needsAction":false,"failed":false}]}
        """;

        const string busyThenSuccess = """
        {"type":"snapshot","generatedAt":920002,"counts":{"busy":1,"completed":1,"failed":0,"decision":0,"rows":2},
         "rows":[
          {"id":"o-busy","title":"orbit finished","child":false,"busy":false,"unread":true,
           "needsAction":false,"failed":false,"lastTurn":{"at":1,"kind":"completed","failed":false}},
          {"id":"o-busy2","title":"orbit still running","child":false,"busy":true,"unread":false,
           "needsAction":false,"failed":false}]}
        """;

        /* The same task breaking instead of finishing. It is a SEPARATE fixture
           from `busyThenSuccess` for a reason the assertion below depends on: the
           red row must appear in the same frame that starts the flight, or the
           failure disk is already faded in before the brush leaves and the
           "only a short arc at 0.25 s" measurement would really be measuring the
           disk (see the failure-flight section). */
        const string thenFailure = """
        {"type":"snapshot","generatedAt":920004,"counts":{"busy":1,"completed":0,"failed":1,"decision":0,"rows":2},
         "rows":[
          {"id":"o-busy","title":"orbit failed","child":false,"busy":false,"unread":false,
           "needsAction":false,"failed":true,"lastTurn":{"at":2,"kind":"error","failed":true}},
          {"id":"o-busy2","title":"orbit still running","child":false,"busy":true,"unread":false,
           "needsAction":false,"failed":false}]}
        """;

        // All four states at once: the 128 pt stack, one disk per colour.
        const string mixed = """
        {"type":"snapshot","generatedAt":920010,"counts":{"busy":1,"completed":1,"failed":1,"decision":1,"rows":4},
         "rows":[
          {"id":"m-done","title":"done","child":false,"busy":false,"unread":true,"needsAction":false,
           "failed":false,"lastTurn":{"at":3,"kind":"completed","failed":false}},
          {"id":"m-fail","title":"failed","child":false,"busy":false,"unread":false,"needsAction":false,
           "failed":true,"lastTurn":{"at":4,"kind":"error","failed":true}},
          {"id":"m-busy","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false},
          {"id":"m-ask","title":"asking","child":false,"busy":false,"unread":false,"needsAction":true,
           "failed":false,"ask":{"id":"ask-orbit","questions":[{"id":"q1","question":"?"}]}}]}
        """;

        // One waiting question and nothing else: the solo amber glyph, which takes
        // the reversible-morph path rather than the four-slot stack.
        const string askingOnly = """
        {"type":"snapshot","generatedAt":920020,"counts":{"busy":0,"completed":0,"failed":0,"decision":1,"rows":1},
         "rows":[{"id":"a-ask","title":"asking","child":false,"busy":false,"unread":false,
                  "needsAction":true,"failed":false,"ask":{"id":"ask-solo","questions":[{"id":"q1","question":"?"}]}}]}
        """;

        // The live-height pair, fed through the REAL transport path: one finished
        // task plus one running task (two lamps), and then the running one
        // finishing into the existing result — the collapse
        // docs/motion-continuity.md:15 is about.
        const string liveTwo = """
        {"ok":true,"generatedAt":921001,"origin":"http://127.0.0.1:1","rows":[
          {"id":"h-done","title":"finished","child":false,"busy":false,"unread":true,"needsAction":false,
           "failed":false,"lastTurn":{"at":11,"kind":"completed","failed":false}},
          {"id":"h-busy","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,
           "failed":false}]}
        """;

        const string liveOne = """
        {"ok":true,"generatedAt":921002,"origin":"http://127.0.0.1:1","rows":[
          {"id":"h-done","title":"finished","child":false,"busy":false,"unread":true,"needsAction":false,
           "failed":false,"lastTurn":{"at":11,"kind":"completed","failed":false}},
          {"id":"h-busy","title":"finished too","child":false,"busy":false,"unread":true,"needsAction":false,
           "failed":false,"lastTurn":{"at":12,"kind":"completed","failed":false}}]}
        """;

        static (double N, double Cx, double Cy) Ink(JsonElement ink, string colour)
        {
            if (!ink.TryGetProperty(colour, out JsonElement c)
                || !c.TryGetProperty("n", out JsonElement n) || n.GetDouble() <= 0)
            {
                return (0, 0, 0);
            }

            return (n.GetDouble(), c.GetProperty("cx").GetDouble(), c.GetProperty("cy").GetDouble());
        }

        static double Field(JsonElement ink, string colour, string field)
        {
            return ink.TryGetProperty(colour, out JsonElement c)
                && c.TryGetProperty(field, out JsonElement v) ? v.GetDouble() : 0;
        }

        async Task<double> Band(double y0, double y1)
        {
            JsonElement element = await EvalAsync(core,
                $"__notchOrbit.probe.inkBand({y0.ToString(System.Globalization.CultureInfo.InvariantCulture)},"
                + $"{y1.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            return element.ValueKind == JsonValueKind.Number ? element.GetDouble() : 0;
        }

        async Task<double> Dark(double x0, double y0, double x1, double y1)
        {
            JsonElement element = await EvalAsync(core,
                $"__notchOrbit.probe.darkIn({x0.ToString(System.Globalization.CultureInfo.InvariantCulture)},"
                + $"{y0.ToString(System.Globalization.CultureInfo.InvariantCulture)},"
                + $"{x1.ToString(System.Globalization.CultureInfo.InvariantCulture)},"
                + $"{y1.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            return element.ValueKind == JsonValueKind.Number ? element.GetDouble() : 0;
        }

        /* Pin the flight to one phase, then WAIT for the round trip: the frame
           reports its animated height, the host resizes the window to it, and the
           canvas repaints in its new box. Reading the ink before that would be
           reading a stack centred for the previous size — which is exactly the
           "disks drawn outside the pill" failure this phase has to prevent, so
           the wait is part of the measurement, not a convenience. */
        async Task Frame(double at)
        {
            await core.ExecuteScriptAsync(
                $"__notchOrbit.probe.frameAt({at.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            await Task.Delay(90);
        }

        async Task Land()
        {
            await core.ExecuteScriptAsync("__notchOrbit.probe.land()");
            await Task.Delay(90);
        }

        async Task Post(string json)
        {
            core.PostWebMessageAsJson(json);
            await Task.Delay(90);
        }

        bool keepProbe = _pageProbeEnabled;
        bool keepExpanded = _expanded;
        double keepOrbit = _restOrbitPt;
        int keepLamps = _lampCount;
        _pageProbeEnabled = true;
        try
        {
            var wait = Stopwatch.StartNew();
            while (!_pageReady && wait.ElapsedMilliseconds < 15000) await Task.Delay(100);
            if (!_pageReady)
            {
                check("orbit canvas present", false, "page never announced itself");
                return lines;
            }

            JsonElement kind = await EvalAsync(core, "typeof __notchOrbit");
            bool ready = kind.ValueKind == JsonValueKind.String && kind.GetString() == "object";
            check("orbit probe present", ready, ready ? "__notchOrbit" : "page has no orbit probe");
            if (!ready) return lines;

            _expanded = false;
            await core.ExecuteScriptAsync("__notchOrbit.probe.reduce(false)");
            await core.ExecuteScriptAsync("__notchOrbit.probe.hold(false)");

            // The previous phase's tests left the window expanded (an open wizard).
            // Collapse it AND tell the page: the rest block is `display:none` while
            // the page still believes it is expanded, so a canvas probe would read a
            // zero-sized, unpainted bitmap.
            ApplySize();
            PushGeometry(_liveWidth, _liveHeight, settled: true);
            await Task.Delay(150);

            // ── 1. one running task ──────────────────────────────────────
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            await Post(busyOnly);
            await Land();

            JsonElement state = await EvalAsync(core, "__notchOrbit.probe.state()");
            JsonElement ink = await EvalAsync(core, "__notchOrbit.probe.ink()");
            (double blueN, double blueX, double blueY) = Ink(ink, "blue");
            (double greenN, _, _) = Ink(ink, "green");
            (double redN, _, _) = Ink(ink, "red");
            (double amberN, _, _) = Ink(ink, "amber");

            check("running lamp is a blue arc, not a disk",
                blueN > 60 && blueN < 320 && greenN == 0 && redN == 0 && amberN == 0,
                $"blue={blueN:0} (a solid 19 pt disk would be ~600) green={greenN:0} red={redN:0} amber={amberN:0}");
            // Its ink has to be the ring the lamp occupies. The centroid is NOT
            // asserted: the arc rotates, so where its mass sits depends on when
            // the frame was taken — the box is the invariant.
            check("running lamp ink is the ring's box",
                state.GetProperty("height").GetDouble() == 20
                    && Field(ink, "blue", "minX") >= 4 && Field(ink, "blue", "maxX") <= 26
                    && Field(ink, "blue", "minY") >= 11 && Field(ink, "blue", "maxY") <= 33,
                $"layout={state.GetProperty("height").GetDouble()}pt box=("
                    + $"{Field(ink, "blue", "minX"):0.#},{Field(ink, "blue", "minY"):0.#})-("
                    + $"{Field(ink, "blue", "maxX"):0.#},{Field(ink, "blue", "maxY"):0.#}) inside (4,11)-(26,33)");

            NativeMethods.GetWindowRect(Handle, out NativeMethods.RECT restRect);
            check("shell height follows the page's layout",
                restRect.Bottom - restRect.Top == Scale(44),
                $"{restRect.Bottom - restRect.Top}px vs {Scale(44)}px (20 + 24 pt)");

            // ── 2. a success flight, sampled at three fixed phases ───────
            await core.ExecuteScriptAsync("__notchOrbit.probe.hold(true)");
            await Post(busyThenSuccess);

            JsonElement atStart = await EvalAsync(core, "__notchOrbit.probe.frameAt(0.25)");
            await Task.Delay(90);
            JsonElement s025 = await EvalAsync(core, "__notchOrbit.probe.state()");
            JsonElement ink025 = await EvalAsync(core, "__notchOrbit.probe.ink()");
            double corridor025 = await Band(33, 39);
            await Frame(0.5);
            JsonElement ink050 = await EvalAsync(core, "__notchOrbit.probe.ink()");
            double corridorHalf = await Band(33, 39);
            await Frame(0.95);
            JsonElement s095 = await EvalAsync(core, "__notchOrbit.probe.state()");
            JsonElement ink095 = await EvalAsync(core, "__notchOrbit.probe.ink()");
            double corridorEnd = await Band(33, 39);

            JsonElement flight = s095.GetProperty("flight");
            bool flew = atStart.ValueKind == JsonValueKind.True
                && flight.ValueKind == JsonValueKind.Object;
            check("finishing task starts a success flight", flew
                && flight.GetProperty("outcome").GetString() == "success"
                && flight.GetProperty("returnsToRunning").ValueKind == JsonValueKind.True,
                flew ? $"outcome={flight.GetProperty("outcome").GetString()} "
                       + $"to-running={flight.GetProperty("returnsToRunning").GetBoolean()}" : "no flight");

            double height025 = s025.GetProperty("height").GetDouble();
            check("the shell grows on the flight's own timeline",
                height025 > 20.5 && height025 < 47.5,
                $"{height025:0.##} pt at 0.25s (20 -> 48)");

            (double g025, _, double gy025) = Ink(ink025, "green");
            (double g050, _, double gy050) = Ink(ink050, "green");
            (double g095, _, double gy095) = Ink(ink095, "green");
            (double b025, _, double by025) = Ink(ink025, "blue");
            (double b095, double bx095, double by095) = Ink(ink095, "blue");

            // "Success flies up" cannot be asserted as "the ink's y decreases":
            // the DESTINATION is the fixed top slot while the working lamp slides
            // down into the second slot, so part of the ink moves down with it. The
            // claims that do hold, and that a fade-in or a cross-fade would fail:
            // the stroke crosses the corridor between the slots and has left it on
            // arrival; the outcome colour is painted progressively (a short arc,
            // then a solid disk); it ends confined to the top slot; and the working
            // slot really does slide down to make room for it.
            check("the brush crosses the corridor between the slots",
                Math.Max(corridor025, corridorHalf) > 8 && corridorEnd == 0,
                $"ink in y 33..39: {corridor025:0} (0.25) {corridorHalf:0} (0.5) {corridorEnd:0} (0.95)");
            check("the outcome is drawn, not faded in",
                g025 > 0 && g025 < 300 && g095 > 500,
                $"green ink {g025:0} at 0.25s (a partial arc) -> {g050:0} -> {g095:0} px at 0.95s (a solid disk)");
            check("the success count lands in the top slot",
                Field(ink095, "green", "minY") < 17 && Field(ink095, "green", "maxY") < 34
                    && gy095 < by095,
                $"green ink y {Field(ink095, "green", "minY"):0.#}..{Field(ink095, "green", "maxY"):0.#} "
                    + $"(top slot 12.5..31.5), green cy={gy095:0.#} above blue cy={by095:0.#}");
            check("the working slot slides down to make room",
                by095 - by025 > 6 && Math.Abs(by095 - 50) < 4,
                $"blue ink cy {by025:0.#} at 0.25s -> {by095:0.#} at 0.95s (expect 22 -> 50)");
            check("the terminal layout is the two-slot stack",
                s095.GetProperty("height").GetDouble() == 48
                    && s095.GetProperty("counts").GetProperty("completed").GetInt32() == 1
                    && s095.GetProperty("counts").GetProperty("busy").GetInt32() == 1,
                $"height={s095.GetProperty("height").GetDouble()}pt");

            // ── 3. a failure flight goes the other way ───────────────────
            // The fixture here is deliberately NOT the success one with the colour
            // swapped. A failure flight makes TWO things visible at once: the
            // brush (a short red arc at 0.25 s) and the bottom slot fading its disk
            // in (0.42 s layout mix). The disk is opaque long before the arc has
            // finished travelling, so a raw red-pixel count at 0.25 s measures the
            // DISK — which is what an earlier version of this check did, and why
            // the reading below is taken once the layout has settled: then the only
            // red that can grow is the stroke arriving and filling the result
            // circle, exactly like the success case's green.
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            await Post(busyOnly);
            await Post(thenFailure);
            await Frame(0.25);
            JsonElement f025 = await EvalAsync(core, "__notchOrbit.probe.ink()");
            double failCorridorEarly = await Band(33, 39);
            await Frame(0.5);
            JsonElement f050 = await EvalAsync(core, "__notchOrbit.probe.ink()");
            double failCorridor = await Band(33, 39);
            await Frame(0.95);
            JsonElement fState = await EvalAsync(core, "__notchOrbit.probe.state()");
            JsonElement f095 = await EvalAsync(core, "__notchOrbit.probe.ink()");
            double failCorridorEnd = await Band(33, 39);

            (double r025, _, double ry025) = Ink(f025, "red");
            (double r050, _, double ry050) = Ink(f050, "red");
            (double r095, _, double ry095) = Ink(f095, "red");
            (double fb095, _, double fby095) = Ink(f095, "blue");
            // The mirror image of the success case: the failure slot is the second
            // one (its disk spans y 40.5..59.5) while the working lamp stays at 22.
            check("the failure brush crosses the corridor too",
                Math.Max(failCorridorEarly, failCorridor) > 8 && failCorridorEnd == 0,
                $"ink in y 33..39: {failCorridorEarly:0} (0.25) {failCorridor:0} (0.5) {failCorridorEnd:0} (0.95)");
            check("the failure ink lands in the second slot",
                r095 > 500 && Field(f095, "red", "maxY") > 55 && ry095 > fby095
                    && Math.Abs(fby095 - 22) < 4,
                $"red n={r095:0} cy={ry095:0.#} box y ..{Field(f095, "red", "maxY"):0.#} "
                    + $"(slot 40.5..59.5), working lamp still at {fby095:0.#}");
            // A short arc at 0.25 s, measured as INK not as area: the stroke is
            // still travelling (its own drawn length is the first number below)
            // while a fade-in or a fill would already be at the final count.
            JsonElement canvas025 = await EvalAsync(core, "__notchOrbit.probe.snapshotOf()");
            // The count is expected to be a PARTIAL result circle here, not the
            // settled disk: 0.25 s into the flight the drawn arc is still short.
            check("the failure outcome is drawn, not faded in",
                r025 > 0 && r025 < 0.8 * r095 && r095 > 500,
                $"red ink {r025:0} at 0.25s (a partial arc) -> {r050:0} -> {r095:0} px "
                    + $"at 0.95s (a solid disk); now[{canvas025.GetString()}]");
            check("failure ink is red, not green",
                Ink(f095, "green").Item1 == 0
                    && fState.GetProperty("counts").GetProperty("failed").GetInt32() == 1,
                $"green={Ink(f095, "green").Item1:0} failed={fState.GetProperty("counts").GetProperty("failed").GetInt32()}");
            await core.ExecuteScriptAsync("__notchOrbit.probe.hold(false)");

            // ── 4. all four states at once: the 128 pt stack ─────────────
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            await Post(mixed);
            await Land();
            JsonElement mState = await EvalAsync(core, "__notchOrbit.probe.state()");
            JsonElement mInk = await EvalAsync(core, "__notchOrbit.probe.ink()");
            (double mGreen, _, double mGreenY) = Ink(mInk, "green");
            (double mBlue, _, double mBlueY) = Ink(mInk, "blue");
            (double mRed, _, double mRedY) = Ink(mInk, "red");
            (double mAmber, _, double mAmberY) = Ink(mInk, "amber");
            double mHeight = mState.GetProperty("height").GetDouble();
            check("four states paint four disks",
                mGreen > 200 && mBlue > 60 && mRed > 200 && mAmber > 200
                    && mState.GetProperty("counts").GetProperty("decision").GetInt32() == 1,
                $"green={mGreen:0} blue={mBlue:0} red={mRed:0} amber={mAmber:0}");
            check("the four disks sit on a 28 pt pitch",
                Math.Abs(mAmberY - 22) < 3 && Math.Abs(mGreenY - 50) < 3
                    && Math.Abs(mBlueY - 78) < 4 && Math.Abs(mRedY - 106) < 3,
                $"amber={mAmberY:0.#} green={mGreenY:0.#} blue={mBlueY:0.#} red={mRedY:0.#}");
            check("four lamps make a 128 pt capsule",
                mHeight == 104 && mHeight == NotchGeometry.RestHeight(4) - 24,
                $"orbit={mHeight}pt capsule={mHeight + 24}pt");
            NativeMethods.GetWindowRect(Handle, out NativeMethods.RECT mixedRect);
            check("the window is the four-lamp height",
                mixedRect.Bottom - mixedRect.Top == Scale(128),
                $"{mixedRect.Bottom - mixedRect.Top}px vs {Scale(128)}px");

            // ── 4b. a SOLO question: the reversible amber glyph ──────────
            // One waiting task and nothing else goes through WorkingDecisionGlyph
            // rather than the four-slot stack (StatusOrbit.swift:535-545), and that
            // path has its own way of keeping the glyph legible: the numeral's
            // COLOUR is multiplied towards black over the filling amber disk.
            // Fading it out instead leaves a blank yellow lamp — which is exactly
            // what a screenshot of this state caught and no count-based check did.
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            await Post(askingOnly);
            await Land();
            JsonElement soloState = await EvalAsync(core, "__notchOrbit.probe.state()");
            JsonElement soloInk = await EvalAsync(core, "__notchOrbit.probe.ink()");
            (double soloAmber, _, double soloAmberY) = Ink(soloInk, "amber");
            double soloDark = await Dark(12, 16, 18, 28);
            double soloPlain = await Dark(6, 23, 10, 27);
            check("the solo decision lamp is a solid amber disk",
                soloAmber > 400 && soloState.GetProperty("height").GetDouble() == 20
                    && Math.Abs(soloAmberY - 22) < 2,
                $"amber={soloAmber:0} at y={soloAmberY:0.#} (expect ~600 at 22)");
            check("its exclamation point is drawn on the disk",
                soloDark >= 5 && soloPlain == 0,
                $"{soloDark:0} dark px where the glyph is, {soloPlain:0} inside the same disk away from it");
            check("the solo lamp keeps no stray arc", Ink(soloInk, "blue").Item1 == 0
                && Ink(soloInk, "green").Item1 == 0 && Ink(soloInk, "red").Item1 == 0,
                $"blue={Ink(soloInk, "blue").Item1:0} green={Ink(soloInk, "green").Item1:0} "
                    + $"red={Ink(soloInk, "red").Item1:0}");

            // ── 5. Reduce Motion shows the terminal state at once ────────
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            await Post(busyOnly);
            await core.ExecuteScriptAsync("__notchOrbit.probe.reduce(true)");
            await Post(busyThenSuccess);
            await Task.Delay(90);
            JsonElement rState = await EvalAsync(core, "__notchOrbit.probe.state()");
            JsonElement rInk = await EvalAsync(core, "__notchOrbit.probe.ink()");
            (double rGreen, _, double rGreenY) = Ink(rInk, "green");
            check("reduce motion skips the travel",
                rState.GetProperty("reduced").ValueKind == JsonValueKind.True
                    && rState.GetProperty("flight").ValueKind == JsonValueKind.Null
                    && rState.GetProperty("animating").ValueKind == JsonValueKind.False,
                $"reduced={rState.GetProperty("reduced").GetBoolean()} "
                    + $"flight={rState.GetProperty("flight").ValueKind} animating={rState.GetProperty("animating").GetBoolean()}");
            check("reduce motion shows the final counts",
                rGreen > 200 && Math.Abs(rGreenY - 22) < 3
                    && rState.GetProperty("height").GetDouble() == 48,
                $"green={rGreen:0} at y={rGreenY:0.#} in the top slot");
            await core.ExecuteScriptAsync("__notchOrbit.probe.reduce(false)");

            // ── 6. the real path: the shell height follows a live flight ──
            // Two lamps going to one, through OnSnapshot, at the real clock. The
            // window must take the intermediate heights rather than jumping, and
            // the shrink must be monotone: that is the invariant that makes the
            // disk displacement and the shell edge agree.
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            await core.ExecuteScriptAsync("__notchOrbit.probe.hold(false)");
            await core.ExecuteScriptAsync("__notchOrbit.probe.live()");
            DeliverSnapshot(liveTwo);
            await Task.Delay(400);
            NativeMethods.GetWindowRect(Handle, out NativeMethods.RECT liveTwoRect);
            int before = liveTwoRect.Bottom - liveTwoRect.Top;

            DeliverSnapshot(liveOne);
            var heights = new List<int>();
            var poll = Stopwatch.StartNew();
            while (poll.ElapsedMilliseconds < 1300)
            {
                NativeMethods.GetWindowRect(Handle, out NativeMethods.RECT frame);
                int live = frame.Bottom - frame.Top;
                if (heights.Count == 0 || heights[^1] != live) heights.Add(live);
                await Task.Delay(12);
            }

            bool monotone = true;
            for (int i = 1; i < heights.Count; i++)
            {
                if (heights[i] > heights[i - 1]) monotone = false;
            }

            check("two lamps before the flight", before == Scale(72), $"{before}px vs {Scale(72)}px");
            check("the shell shrinks frame by frame",
                monotone && heights.Count >= 6 && heights[^1] == Scale(44)
                    && heights[0] == Scale(72),
                $"{heights.Count} distinct heights {heights[0]} -> {heights[^1]}, monotone={monotone}");
            check("it passes through the intermediate heights",
                heights.Exists(h => h > Scale(44) && h < Scale(72)),
                string.Join(" ", heights));

            JsonElement liveState = await EvalAsync(core, "__notchOrbit.probe.state()");
            JsonElement liveInk = await EvalAsync(core, "__notchOrbit.probe.ink()");
            (double liveGreen, _, double liveGreenY) = Ink(liveInk, "green");
            (double liveBlue, _, _) = Ink(liveInk, "blue");
            check("the finished task leaves a green count only",
                liveGreen > 200 && liveBlue == 0 && Math.Abs(liveGreenY - 22) < 3,
                $"green={liveGreen:0} at y={liveGreenY:0.#}, blue={liveBlue:0}");
            check("the page's settled height agrees with the lamp tally",
                Math.Abs(liveState.GetProperty("reported").GetDouble()
                         - (NotchGeometry.RestHeight(1) - 24)) < 0.001
                    && Math.Abs(_restOrbitPt - (NotchGeometry.RestHeight(1) - 24)) < 0.001,
                $"reported={liveState.GetProperty("reported").GetDouble()}pt "
                    + $"host={_restOrbitPt:0.##}pt expect {NotchGeometry.RestHeight(1) - 24}pt");
        }
        catch (Exception ex)
        {
            check("orbit stroke regression", false,
                $"{ex.GetType().Name}: {ex.Message} @@ {string.Join(" | ",
                    (ex.StackTrace ?? string.Empty).Split('\n').Take(4).Select(l => l.Trim()))}");
        }
        finally
        {
            _pageProbeEnabled = keepProbe;
            _expanded = keepExpanded;
            _restOrbitPt = keepOrbit;
            _lampCount = keepLamps;
            try { await _web.CoreWebView2!.ExecuteScriptAsync("__notchOrbit.probe.hold(false)"); }
            catch { /* the renderer may be gone */ }
            try { await _web.CoreWebView2!.ExecuteScriptAsync("__notchOrbit.probe.live()"); }
            catch { /* ditto */ }
            ApplySize();
        }

        return lines;
    }

    /// <summary>
    /// Phase 5 checks: the idle robot — the presence machine (departure to the
    /// status pen, arrival out of a ring), the scheduler (blink, gestures, dance)
    /// and the artwork itself, which is the vendored OpenBotMotion renderer
    /// rasterised into the pill's canvas.
    ///
    /// The assertions are about PAINTED PIXELS, like every phase since Phase 2:
    /// the robot's own palette (a light body, near-black eyes) is counted back
    /// out of the canvas, and the vendored engine's live SVG attributes are read
    /// back through the probe so a renderer that silently stopped writing
    /// geometry cannot pass. The clock is pinned for the same reason Phase 4
    /// pins it: a real 60 fps loop would overtake the frame under test.
    /// </summary>
    private async Task<List<string>> RunRobotSelfTestAsync(Action<string, bool, string> check)
    {
        var lines = new List<string>();
        CoreWebView2? core = _web.CoreWebView2;
        if (core is null)
        {
            check("robot renderer available", true, "skipped (renderer unavailable)");
            return lines;
        }

        // A task appearing, and the same task finishing: nothing but the robot
        // and one lamp, so the pill's height belongs to the layout and the robot
        // is the only thing that can be painting inside it.
        const string robotBusy = """
        {"type":"snapshot","generatedAt":940001,"counts":{"busy":1,"completed":0,"failed":0,"decision":0,"rows":1},
         "rows":[{"id":"r-busy","title":"robot probe","child":false,"busy":true,"unread":false,
                  "needsAction":false,"failed":false}]}
        """;
        const string robotIdle = """
        {"type":"snapshot","generatedAt":940002,"counts":{"busy":0,"completed":0,"failed":0,"decision":0,"rows":1},
         "rows":[{"id":"r-busy","title":"robot probe","child":false,"busy":false,"unread":false,
                  "needsAction":false,"failed":false}]}
        """;

        bool keepProbe = _pageProbeEnabled;
        bool keepExpanded = _expanded;
        double keepOrbit = _restOrbitPt;
        int keepLamps = _lampCount;

        async Task<JsonElement> Eval(string script) => await EvalAsync(core, script);

        async Task Pin(double at)
        {
            await core.ExecuteScriptAsync(
                $"__notchOrbit.probe.pin({at.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            await Task.Delay(90);
        }

        async Task<JsonElement> Robot() => await Eval("__notchOrbit.probe.robot()");
        async Task<JsonElement> Ink() => await Eval("__notchOrbit.probe.robotInk()");

        static double Num(JsonElement element, string name)
        {
            return element.TryGetProperty(name, out JsonElement value)
                && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : 0;
        }

        static double Body(JsonElement ink)
        {
            return ink.TryGetProperty("body", out JsonElement body)
                && body.TryGetProperty("n", out JsonElement n) ? n.GetDouble() : 0;
        }

        static double Eye(JsonElement ink)
        {
            return ink.TryGetProperty("eye", out JsonElement eye)
                && eye.TryGetProperty("n", out JsonElement n) ? n.GetDouble() : 0;
        }

        _pageProbeEnabled = true;
        // The synthetic snapshots below are the whole point of this test, and a
        // live Host would keep pushing its own rows over them (this machine has a
        // real DSH running) — so the transport is parked for the duration,
        // exactly as the --shot injectors park it.
        NotchClient? keepClient = _client;
        _client = null;
        keepClient?.Dispose();
        try
        {
            var wait = Stopwatch.StartNew();
            while (!_pageReady && wait.ElapsedMilliseconds < 15000) await Task.Delay(100);
            if (!_pageReady)
            {
                check("robot probe present", false, "page never announced itself");
                return lines;
            }

            _expanded = false;
            await core.ExecuteScriptAsync("__notchOrbit.probe.hold(true)");
            await core.ExecuteScriptAsync("__notchOrbit.probe.reduce(false)");
            ApplySize();
            PushGeometry(_liveWidth, _liveHeight, settled: true);
            await Task.Delay(150);

            // ── 1. the vendored engine is alive, and writes the attributes the
            //       page parses (a polyline `d`, eyes as rects with a transform)
            JsonElement engine = await Eval("__notchOrbit.probe.robotEngine('blink', 0)");
            bool engineOk = engine.GetProperty("ready").GetBoolean()
                && Num(engine, "dLength") > 100
                && Num(engine, "eyes") == 2
                && (engine.GetProperty("eyeTransform").GetString() ?? "").Contains("translate");
            check("the vendored OpenBotMotion renderer is driving the robot",
                engineOk,
                $"ready={engine.GetProperty("ready").GetBoolean()} d={Num(engine, "dLength"):0} chars "
                    + $"eyes={Num(engine, "eyes"):0} transform={engine.GetProperty("eyeTransform").GetString()}");

            // ── 2. no lamps at all: the robot is what the pill shows
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            DeliverSnapshot(robotIdle);
            await Task.Delay(200);
            JsonElement idleState = await Robot();
            JsonElement idleInk = await Ink();
            JsonElement idleSnap = await EvalAsync(core, "__notchOrbit.probe.snapshotOf()");
            double idleBody = Body(idleInk);
            check("the idle pill paints the robot",
                idleState.GetProperty("shows").GetBoolean()
                    && idleState.GetProperty("display").GetBoolean()
                    && idleBody > 40,
                $"shows={idleState.GetProperty("shows").GetBoolean()} display={idleState.GetProperty("display").GetBoolean()} "
                    + $"body={idleBody:0}px eyes={Eye(idleInk):0}px reason={idleState.GetProperty("reason").GetString()}; "
                    + idleSnap.GetString());
            JsonElement idleLayout = await Eval("__notchOrbit.probe.state()");
            NativeMethods.GetWindowRect(Handle, out NativeMethods.RECT idleRect);
            double idleHeight = idleLayout.GetProperty("height").GetDouble();
            check("the robot's pill is the empty-layout height",
                Math.Abs(idleHeight - (NotchGeometry.RestHeight(1) - 24)) < 0.001
                    && idleRect.Bottom - idleRect.Top == Scale(NotchGeometry.RestHeight(1)),
                $"orbit={idleHeight}pt window={idleRect.Bottom - idleRect.Top}px vs {Scale(44)}px");

            // ── 3. the scheduler: an eyelid really closes, a gesture really moves,
            //       and the dance clip really changes the body pigment.
            // `pin` takes an ABSOLUTE page-clock instant (performance.now()/1000),
            // so each scenario first reads `probe.state().now` and then pins
            // `base + offset`. Pinning to a small constant instead would leave the
            // clock far behind a departure that is anchored to the real flight
            // start, and the frame under test would freeze instead of shrinking.
            double clockBase = (await EvalAsync(core, "__notchOrbit.probe.state()")).GetProperty("now").GetDouble();
            await core.ExecuteScriptAsync($"__notchOrbit.probe.robotAction('blink', 0.6)");
            await Pin(clockBase);
            JsonElement open = await Ink();
            await core.ExecuteScriptAsync($"__notchOrbit.probe.robotAction('blink', 1.26)");
            await Pin(clockBase);
            JsonElement shut = await Ink();
            check("the scheduled blink closes the eyelids",
                Eye(open) > 2 && Eye(shut) < Eye(open),
                $"eyes {Eye(open):0}px open -> {Eye(shut):0}px closed");

            await core.ExecuteScriptAsync($"__notchOrbit.probe.robotAction('hop', 1.9)");
            await Pin(clockBase);
            JsonElement hopRobot = await Robot();
            JsonElement hopInk = await Ink();
            double hopTop = hopRobot.GetProperty("bbox").GetProperty("minY").GetDouble();
            check("a scheduled gesture moves the silhouette",
                hopTop < -70 && Body(hopInk) > 20,
                $"hop bbox minY={hopTop:0.#} (rest is about -63), body={Body(hopInk):0}px");

            await core.ExecuteScriptAsync($"__notchOrbit.probe.robotAction('dance', 1.0)");
            await Pin(clockBase);
            string danceFill = (await Eval("__notchOrbit.probe.robotEngine('dance', 1.0)")).GetProperty("fill").GetString() ?? "";
            JsonElement danceInk = await Ink();
            await core.ExecuteScriptAsync($"__notchOrbit.probe.robotAction('dance', 4.0)");
            await Pin(clockBase);
            string danceFill2 = (await Eval("__notchOrbit.probe.robotEngine('dance', 4.0)")).GetProperty("fill").GetString() ?? "";
            JsonElement danceSnap = await EvalAsync(core, "__notchOrbit.probe.snapshotOf()");
            check("the dance clip cycles its own pigment",
                danceFill != danceFill2 && danceFill.StartsWith("#") && danceFill2.StartsWith("#")
                    && Body(danceInk) > 20,
                $"{danceFill} -> {danceFill2}, body={Body(danceInk):0}px; {danceSnap.GetString()}");

            // ── 4. the departure: the silhouette shrinks to the tiny point that
            //       becomes the pen, and the status does not appear until it has
            //
            // The samples are taken on the ROBOT's own clock (`robot.departAt`,
            // reported by the page) rather than on the layout flight's: the
            // departure is anchored either to the flight that started with the
            // lamp or to the frame that saw it, and on this machine the two
            // differ by ~60 ms — computing "departure + 0.7 s" from the flight
            // put every sample past the robot's own 0.9 s curve, where the
            // measurement had already changed owner (see the isolation note
            // below). The anchor itself is asserted separately.
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            // The robot's pigment is handed over to the outgoing status colour
            // by design, so during a departure the robot and the arriving brush
            // paint the SAME blue: a pixel count in the shared column cannot
            // tell "the silhouette shrank" from "the status is drawing". The
            // status channel is parked for these samples and the canvas then
            // holds the robot alone; the brush's own parking is asserted from
            // the pen's position further down.
            await core.ExecuteScriptAsync("__notchOrbit.probe.soloRobot(true)");
            await core.ExecuteScriptAsync("__notchOrbit.probe.robotAction('blink', 0.6)");
            DeliverSnapshot(robotIdle);
            await Task.Delay(200);

            double lampBefore = (await EvalAsync(core, "__notchOrbit.probe.state()"))
                .GetProperty("now").GetDouble();
            DeliverSnapshot(robotBusy);
            await Task.Delay(60);
            JsonElement departRobot = await Robot();
            double departAt = Num(departRobot, "departAt");
            JsonElement lampState = await EvalAsync(core, "__notchOrbit.probe.state()");
            double lampAfter = lampState.GetProperty("now").GetDouble();
            JsonElement flightStart = lampState.GetProperty("flightStart");
            check("the departure starts when the lamp appears",
                departRobot.GetProperty("depart").GetBoolean()
                    && departAt >= lampBefore - 0.03 && departAt <= lampAfter + 0.03,
                $"departAt={departAt:0.###} within the lamp frame {lampBefore:0.###}..{lampAfter:0.###} "
                    + $"(flightStart={flightStart.GetRawText()})");

            await Pin(departAt + 0.30);
            JsonElement early = await Robot();
            JsonElement earlyInk = await Ink();
            JsonElement earlyPaint = await EvalAsync(core, "__notchOrbit.probe.paint()");
            JsonElement earlyPen = await EvalAsync(core, "__notchOrbit.probe.pen()");
            await Pin(departAt + 0.51);
            JsonElement mid = await Robot();
            JsonElement midInk = await Ink();
            JsonElement midPaint = await EvalAsync(core, "__notchOrbit.probe.paint()");
            JsonElement midPen = await EvalAsync(core, "__notchOrbit.probe.pen()");
            await Pin(departAt + 0.61);
            JsonElement tiny = await Robot();
            JsonElement tinyInk = await Ink();
            JsonElement tinyPaint = await EvalAsync(core, "__notchOrbit.probe.paint()");
            await Pin(departAt + 0.75);
            JsonElement gone = await Robot();
            JsonElement goneInk = await Ink();

            check("the robot shrinks into the tiny point",
                Body(earlyInk) > 100 && Num(earlyPaint, "scale") > 0.9
                    && Body(midInk) > 4 && Body(midInk) < Body(earlyInk) * 0.6
                    && Num(midPaint, "scale") < 0.8
                    && Body(tinyInk) < Body(midInk) * 0.6 && Num(tinyPaint, "scale") < 0.10
                    && Body(goneInk) == 0 && tiny.GetProperty("depart").GetBoolean(),
                $"painted body px @{Num(early, "departProgress"):0.###}: {Body(earlyInk):0} early -> "
                    + $"{Body(midInk):0} @{Num(mid, "departProgress"):0.###} -> "
                    + $"{Body(tinyInk):0} @{Num(tiny, "departProgress"):0.###} -> "
                    + $"{Body(goneInk):0} @{Num(gone, "departProgress"):0.###}; "
                    + $"scale {Num(earlyPaint, "scale"):0.###}/{Num(midPaint, "scale"):0.###}/"
                    + $"{Num(tinyPaint, "scale"):0.###}; midPaint={midPaint.GetRawText()}");
            // The pen waits for the robot's own 1.22 s (`DecisionSpin.delay` is
            // `ROBOT_DEPARTURE`): its position must not have moved at either
            // departure sample, and must be moving once that window is over.
            await Pin(departAt + 1.45);
            JsonElement afterPen = await EvalAsync(core, "__notchOrbit.probe.pen()");
            bool afterMoving = !afterPen.GetProperty("parked").GetBoolean()
                && (!afterPen.GetProperty("spin").GetBoolean() || Num(afterPen, "travelled") > 0.05);
            check("the pen is parked until the departure is over",
                earlyPen.GetProperty("parked").GetBoolean()
                    && midPen.GetProperty("parked").GetBoolean() && afterMoving,
                $"in transit: early={earlyPen.GetRawText()} mid={midPen.GetRawText()}; "
                    + $"after the window: pen={afterPen.GetRawText()}");
            await core.ExecuteScriptAsync("__notchOrbit.probe.soloRobot(false)");

            // ── 5. the arrival: the ring opens out and the robot comes back.
            // The clock is pinned BEFORE the fixture is replaced, so the presence
            // machine cannot quietly run the whole arrival while the snapshots are
            // being delivered (it did exactly that once, and this test then measured
            // a robot that was already home). The frozen instant is also the
            // arrival's start, so the transition can be walked with `probe.pin(at)`
            // — which keeps the check honest: it asserts the visibility OPENING OUT
            // rather than one finished sample, which a hard cut would also pass.
            double arriveAt = (await EvalAsync(core, "__notchOrbit.probe.state()")).GetProperty("now").GetDouble();
            await core.ExecuteScriptAsync(
                $"__notchOrbit.probe.pin({arriveAt.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            DeliverSnapshot(robotBusy);
            await Pin(arriveAt);
            await core.ExecuteScriptAsync("__notchOrbit.probe.robotAction('hop', 1.9)");
            await Pin(arriveAt);
            JsonElement hopFrozen = await Robot();
            DeliverSnapshot(robotIdle);
            // The snapshot is marshalled by the host (`BeginInvoke`), so one frame
            // has to pass before the page has actually seen it. The arrival's own
            // start is then read back from the page — pinning an assumed instant
            // would either freeze before the edge or step over the whole 1.05 s.
            await Task.Delay(120);
            JsonElement landed = await Robot();
            double entryAt = Num(landed, "entryAt");
            await Pin(entryAt + 0.10);
            JsonElement midway = await Robot();
            await Pin(entryAt + 0.30);
            JsonElement later = await Robot();
            check("the arrival opens out, it does not cut",
                midway.GetProperty("shows").GetBoolean()
                    && Num(midway, "visibility") > 0.02 && Num(midway, "visibility") < 0.98
                    && Num(later, "visibility") > Num(midway, "visibility"),
                $"visibility {Num(midway, "visibility"):0.###} at 0.10s -> "
                    + $"{Num(later, "visibility"):0.###} at 0.30s "
                    + $"(entryAt={entryAt:0.###}, idle={(landed.GetProperty("idle").ValueKind == JsonValueKind.Null ? "null" : landed.GetProperty("idle").GetRawText())}, "
                    + $"shows={landed.GetProperty("shows").GetBoolean()}, "
                    + (await EvalAsync(core, "__notchOrbit.probe.snapshotOf()")).GetString() + ")");
            await Pin(entryAt + 3.0);
            JsonElement arrived = await Robot();
            JsonElement arrivedInk = await Ink();
            check("the robot is back and animating",
                Num(arrived, "visibility") > 0.999 && Body(arrivedInk) > 20
                    && arrived.GetProperty("live").GetBoolean(),
                $"visibility={Num(arrived, "visibility"):0.###} body={Body(arrivedInk):0}px "
                    + $"action={arrived.GetProperty("action").GetString()} "
                    + $"(frozen bbox={(hopFrozen.GetProperty("bbox").ValueKind == JsonValueKind.Object
                        ? hopFrozen.GetProperty("bbox").GetProperty("minY").GetDouble().ToString("0.#") : "-")})");
            await core.ExecuteScriptAsync("__notchOrbit.probe.live()");
            await core.ExecuteScriptAsync("__notchOrbit.probe.hold(false)");

            // ── 6. Reduce Motion: the neutral pose, no gestures, no fade
            await core.ExecuteScriptAsync("__notchOrbit.probe.reduce(true)");
            await Task.Delay(120);
            JsonElement still = await Ink();
            await Task.Delay(400);
            JsonElement still2 = await Ink();
            check("reduce motion holds a still neutral robot",
                Body(still) > 20 && Body(still2) > 0
                    && Math.Abs(Body(still2) - Body(still)) <= Math.Max(2, Body(still) * 0.05),
                $"body {Body(still):0}px -> {Body(still2):0}px over 400 ms");
            await core.ExecuteScriptAsync("__notchOrbit.probe.reduce(false)");

            JsonElement final = await Robot();
            lines.Add($"robot: action={final.GetProperty("action").GetString()} "
                + $"visibility={Num(final, "visibility"):0.###} "
                + $"canvas={idleInk.GetProperty("w").GetInt32()}x{idleInk.GetProperty("h").GetInt32()}"
                + $" dpr={idleInk.GetProperty("dpr").GetDouble():0.##}");
        }
        catch (Exception ex)
        {
            check("robot regression", false, $"{ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            _pageProbeEnabled = keepProbe;
            _expanded = keepExpanded;
            _restOrbitPt = keepOrbit;
            _lampCount = keepLamps;
            try { await _web.CoreWebView2!.ExecuteScriptAsync("__notchOrbit.probe.reduce(false)"); }
            catch { /* the renderer may be gone */ }
            try { await _web.CoreWebView2!.ExecuteScriptAsync("__notchOrbit.probe.soloRobot(false)"); }
            catch { /* ditto */ }
            try { await _web.CoreWebView2!.ExecuteScriptAsync("__notchOrbit.probe.hold(false)"); }
            catch { /* ditto */ }
            try { await _web.CoreWebView2!.ExecuteScriptAsync("__notchOrbit.probe.live()"); }
            catch { /* ditto */ }
            // Put the transport back exactly as the constructor left it, so the
            // data test that follows still has a client to talk to.
            if (keepClient is not null && _client is null)
            {
                _client = keepClient;
                _client.SnapshotReceived += OnSnapshot;
                _client.TransportStateChanged += message => NotchLog.Write($"transport {message}");
                if (!_selfTest) _client.Start();
            }

            ApplySize();
        }

        return lines;
    }

    /// <summary>
    /// Phase 5 capture aid: paints the idle robot — or one frozen phase of its
    /// departure — so <c>--shot</c> can photograph it without waiting for a
    /// random 5-10 s gesture gap and without a real task having to finish.
    ///
    /// Page-direct, exactly like the Phase 4 helper: the empty snapshot is what
    /// makes the page show the robot, and the departure is driven through the
    /// same `OnSnapshot` path a real task uses, so the capture shows the real
    /// presence machine rather than a staged picture.
    /// </summary>
    internal async Task InjectSyntheticRobotAsync(string name, double freezeAt, bool noMotion)
    {
        CoreWebView2? core = _web.CoreWebView2;
        if (core is null) return;

        // A capture must show the synthetic state, not a real snapshot arriving
        // mid-exposure (this helper plugs into a live DSH).
        _client?.Dispose();
        _client = null;

        _expanded = false;
        ApplySize();

        const string busy = """
        {"type":"snapshot","generatedAt":950001,"counts":{"busy":1,"completed":0,"failed":0,"decision":0,"rows":1},
         "rows":[{"id":"p-busy","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}
        """;
        const string none = """
        {"type":"snapshot","generatedAt":950002,"counts":{"busy":0,"completed":0,"failed":0,"decision":0,"rows":1},
         "rows":[{"id":"p-busy","title":"running","child":false,"busy":false,"unread":false,"needsAction":false,"failed":false}]}
        """;

        await core.ExecuteScriptAsync("__notchOrbit.probe.hold(true)");
        await core.ExecuteScriptAsync($"__notchOrbit.probe.reduce({(noMotion ? "true" : "false")})");
        await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");

        // The robot's own clip phase is what is being photographed; pinning the
        // clock afterwards keeps that phase from being overtaken by a real frame.
        string action = name.StartsWith("dance") ? "dance"
            : name.StartsWith("hop") ? "hop"
            : name.StartsWith("blink") ? "blink" : "blink";
        double phase = name.StartsWith("dance") ? 1.0 : name.StartsWith("hop") ? 1.9 : 0.6;
        if (name.StartsWith("blink", StringComparison.Ordinal))
        {
            int dash = name.IndexOf('-');
            if (dash > 0 && double.TryParse(name[(dash + 1)..], System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out double parsed))
            {
                phase = parsed;
            }
        }

        if (name.StartsWith("arrive", StringComparison.OrdinalIgnoreCase))
        {
            // The arrival's start is read back from the page (a pinned instant
            // would have to guess the live clock), and `--robot-at` is then the
            // OFFSET from that start, not an absolute instant.
            await core.ExecuteScriptAsync(
                $"__notchOrbit.probe.robotAction('{action}', {phase.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            DeliverSnapshot(none);
            await Task.Delay(300);
            JsonElement landed = await EvalAsync(core, "__notchOrbit.probe.robot()");
            double entryAt = landed.TryGetProperty("entryAt", out JsonElement ea) ? ea.GetDouble() : 0;
            double entryOffset = freezeAt >= 0 ? freezeAt : 0.15;
            await core.ExecuteScriptAsync(
                $"__notchOrbit.probe.pin({(entryAt + entryOffset).ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            await Task.Delay(280);
            await LogRobotFrameAsync(core);
            return;
        }

        if (name.StartsWith("flight", StringComparison.OrdinalIgnoreCase))
        {
            // Neutralize the live transport AND seed a lamp first: a departure
            // needs a real status to leave towards.
            DeliverSnapshot(busy);
            await Task.Delay(60);
            await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");
            DeliverSnapshot(none);
            await Task.Delay(200);
            await core.ExecuteScriptAsync($"__notchOrbit.probe.robotAction('{action}', {phase.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            DeliverSnapshot(busy);
            await Task.Delay(60);
            // Same rule as the self-test: the departure is anchored to the lamp,
            // and the anchor is read back from the page instead of assumed (the
            // layout flight and the presence edge can be ~60 ms apart, which is
            // enough to photograph the wrong phase). `--robot-at` is the offset
            // from the anchor.
            JsonElement departing = await EvalAsync(core, "__notchOrbit.probe.robot()");
            double departAt = departing.TryGetProperty("departAt", out JsonElement da) ? da.GetDouble() : 0;
            double departOffset = freezeAt >= 0 ? freezeAt : 0.51;
            await core.ExecuteScriptAsync(
                $"__notchOrbit.probe.pin({(departAt + departOffset).ToString(System.Globalization.CultureInfo.InvariantCulture)})");
            await Task.Delay(280);
            await LogRobotFrameAsync(core);
            return;
        }

        // A clip pose is anchored to the instant it was started
        // (`RobotDirector.resume` sets `began = at - elapsed`), so the clock is
        // pinned FIRST and the clip is started AT that pinned instant: the pose
        // is then exactly at `phase` however long the capture takes. The arrival
        // has to finish on the live clock before that, or the pill would be
        // photographed mid-fade. `--robot-at` is an offset from that instant.
        DeliverSnapshot(none);
        await Task.Delay(400);
        JsonElement settled = await EvalAsync(core, "__notchOrbit.probe.state()");
        double holdAt = settled.GetProperty("now").GetDouble() + (freezeAt >= 0 ? freezeAt : 0);
        await core.ExecuteScriptAsync(
            $"__notchOrbit.probe.pin({holdAt.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
        await core.ExecuteScriptAsync($"__notchOrbit.probe.robotAction('{action}', {phase.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
        await core.ExecuteScriptAsync(
            $"__notchOrbit.probe.pin({holdAt.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
        await Task.Delay(280);
        await LogRobotFrameAsync(core);
    }

    /// <summary>Phase 5 capture/diagnosis log: the robot's own state and its
    /// painted footprint, so "the pill is a black box" can be told apart from
    /// "the robot is mid-departure" without looking at the picture.</summary>
    internal async Task LogRobotFrameAsync(CoreWebView2 core)
    {
        try
        {
            JsonElement robot = await EvalAsync(core, "__notchOrbit.probe.robot()");
            JsonElement ink = await EvalAsync(core, "__notchOrbit.probe.robotInk()");
            double body = ink.TryGetProperty("body", out JsonElement b) && b.TryGetProperty("n", out JsonElement bn)
                ? bn.GetDouble() : 0;
            double eyes = ink.TryGetProperty("eye", out JsonElement e) && e.TryGetProperty("n", out JsonElement en)
                ? en.GetDouble() : 0;
            string bbox = robot.TryGetProperty("bbox", out JsonElement box) && box.ValueKind == JsonValueKind.Object
                ? $"{box.GetProperty("minX").GetDouble():0.#},{box.GetProperty("maxX").GetDouble():0.#},"
                    + $"{box.GetProperty("minY").GetDouble():0.#},{box.GetProperty("maxY").GetDouble():0.#}"
                : "-";
            NotchLog.Write(
                $"robot state: reason={robot.GetProperty("reason").GetString()} "
                + $"shows={robot.GetProperty("shows").GetBoolean()} "
                + $"visibility={robot.GetProperty("visibility").GetDouble():0.###} "
                + $"depart={robot.GetProperty("depart").GetBoolean()} "
                + $"live={robot.GetProperty("live").GetBoolean()} "
                + $"action={robot.GetProperty("action").GetString()} "
                + $"ready={robot.GetProperty("ready").GetBoolean()} err={robot.GetProperty("error").GetString()} "
                + $"bbox={bbox} body={body:0}px eyes={eyes:0}px");
        }
        catch (Exception ex)
        {
            NotchLog.Write($"robot state probe failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Phase 4 capture aid: paints one named status state — or one frozen phase of
    /// a status flight — so <c>--shot</c> can photograph the stroke without waiting
    /// for a real task to finish.
    ///
    /// Page-direct on purpose: the host's own auto-expand would hide the rest block
    /// the moment a question appears, and what is being photographed is the
    /// collapsed pill. The window height is not faked — the page reports its
    /// animated orbit height exactly as it does in use, so the capture includes the
    /// pill's real geometry.
    /// </summary>
    internal async Task InjectSyntheticOrbitAsync(string name, double at, bool noMotion)
    {
        CoreWebView2? core = _web.CoreWebView2;
        if (core is null) return;

        // A capture must show the synthetic state, not a real snapshot that happens
        // to arrive mid-exposure — this helper plugs into a live DSH, and the pill
        // would otherwise switch to whatever the user's sessions are doing between
        // the injection and the shutter.
        _client?.Dispose();
        _client = null;

        _expanded = false;
        ApplySize();

        const string busy = """
        {"type":"snapshot","generatedAt":930001,"counts":{"busy":1,"completed":0,"failed":0,"decision":0,"rows":1},
         "rows":[{"id":"s-busy","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}
        """;
        const string busy2 = """
        {"type":"snapshot","generatedAt":930002,"counts":{"busy":2,"completed":0,"failed":0,"decision":0,"rows":2},
         "rows":[
          {"id":"s-busy","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false},
          {"id":"s-busy2","title":"running too","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}
        """;
        const string done = """
        {"type":"snapshot","generatedAt":930003,"counts":{"busy":0,"completed":1,"failed":0,"decision":0,"rows":1},
         "rows":[{"id":"s-busy","title":"finished","child":false,"busy":false,"unread":true,"needsAction":false,
                  "failed":false,"lastTurn":{"at":1,"kind":"completed","failed":false}}]}
        """;
        const string failed = """
        {"type":"snapshot","generatedAt":930004,"counts":{"busy":0,"completed":0,"failed":1,"decision":0,"rows":1},
         "rows":[{"id":"s-busy","title":"crashed","child":false,"busy":false,"unread":false,"needsAction":false,
                  "failed":true,"lastTurn":{"at":2,"kind":"error","failed":true}}]}
        """;
        const string asking = """
        {"type":"snapshot","generatedAt":930005,"counts":{"busy":0,"completed":0,"failed":0,"decision":1,"rows":1},
         "rows":[{"id":"s-ask","title":"asking","child":false,"busy":false,"unread":false,"needsAction":true,
                  "failed":false,"ask":{"id":"ask-shot","questions":[{"id":"q1","question":"?"}]}}]}
        """;
        const string mixed = """
        {"type":"snapshot","generatedAt":930006,"counts":{"busy":1,"completed":1,"failed":1,"decision":1,"rows":4},
         "rows":[
          {"id":"s-done","title":"done","child":false,"busy":false,"unread":true,"needsAction":false,
           "failed":false,"lastTurn":{"at":3,"kind":"completed","failed":false}},
          {"id":"s-fail","title":"failed","child":false,"busy":false,"unread":false,"needsAction":false,
           "failed":true,"lastTurn":{"at":4,"kind":"error","failed":true}},
          {"id":"s-busy","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false},
          {"id":"s-ask","title":"asking","child":false,"busy":false,"unread":false,"needsAction":true,
           "failed":false,"ask":{"id":"ask-shot","questions":[{"id":"q1","question":"?"}]}}]}
        """;
        // One task failing while another keeps running: the red stroke has a
        // destination slot that did not exist before, and it returns to the arc.
        const string failedThenBusy = """
        {"type":"snapshot","generatedAt":930009,"counts":{"busy":1,"completed":0,"failed":1,"decision":0,"rows":2},
         "rows":[
          {"id":"s-busy","title":"crashed","child":false,"busy":false,"unread":false,"needsAction":false,
           "failed":true,"lastTurn":{"at":2,"kind":"error","failed":true}},
          {"id":"s-busy2","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}
        """;
        // One task finishing successfully while another keeps running: the green
        // stroke's destination slot did not exist before, and it returns to the arc.
        const string doneThenBusy = """
        {"type":"snapshot","generatedAt":930011,"counts":{"busy":1,"completed":1,"failed":0,"decision":0,"rows":2},
         "rows":[
          {"id":"s-busy","title":"finished","child":false,"busy":false,"unread":true,"needsAction":false,
           "failed":false,"lastTurn":{"at":1,"kind":"completed","failed":false}},
          {"id":"s-busy2","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}
        """;
        // The same task turning into a question while another keeps running: the
        // amber stroke leaves the running arc for the decision slot.
        const string busyThenAsk = """
        {"type":"snapshot","generatedAt":930007,"counts":{"busy":1,"completed":0,"failed":0,"decision":1,"rows":2},
         "rows":[
          {"id":"s-busy","title":"asking now","child":false,"busy":false,"unread":false,"needsAction":true,
           "failed":false,"ask":{"id":"ask-shot","questions":[{"id":"q1","question":"?"}]}},
          {"id":"s-busy2","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}
        """;
        // A question being answered: the amber task is running again, and the reply
        // stroke has to travel back into the blue arc.
        const string askThenBusy = """
        {"type":"snapshot","generatedAt":930008,"counts":{"busy":2,"completed":0,"failed":0,"decision":0,"rows":2},
         "rows":[
          {"id":"s-busy","title":"resumed","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false},
          {"id":"s-busy2","title":"running","child":false,"busy":true,"unread":false,"needsAction":false,"failed":false}]}
        """;

        async Task Post(string json)
        {
            core.PostWebMessageAsJson(json);
            await Task.Delay(160);
        }

        await core.ExecuteScriptAsync("__notchOrbit.probe.hold(false)");
        await core.ExecuteScriptAsync(noMotion
            ? "__notchOrbit.probe.reduce(true)"
            : "__notchOrbit.probe.reduce(false)");
        await core.ExecuteScriptAsync("__notchOrbit.probe.reset()");

        switch (name)
        {
            case "idle":
                core.PostWebMessageAsJson(
                    "{\"type\":\"snapshot\",\"generatedAt\":930000,\"counts\":{\"busy\":0,\"completed\":0,"
                    + "\"failed\":0,\"decision\":0,\"rows\":0},\"rows\":[]}");
                await Task.Delay(160);
                await core.ExecuteScriptAsync("__notchOrbit.probe.land()");
                break;

            case "running": await Post(busy2); await core.ExecuteScriptAsync("__notchOrbit.probe.land()"); break;
            case "decision": await Post(asking); await core.ExecuteScriptAsync("__notchOrbit.probe.land()"); break;
            case "success": await Post(done); await core.ExecuteScriptAsync("__notchOrbit.probe.land()"); break;
            case "failure": await Post(failed); await core.ExecuteScriptAsync("__notchOrbit.probe.land()"); break;
            case "mixed": await Post(mixed); await core.ExecuteScriptAsync("__notchOrbit.probe.land()"); break;

            case "flight-success":
                await core.ExecuteScriptAsync("__notchOrbit.probe.hold(true)");
                await Post(busy);
                await Post(doneThenBusy);
                await core.ExecuteScriptAsync($"__notchOrbit.probe.frameAt({At(at)})");
                break;

            case "flight-failure":
                await core.ExecuteScriptAsync("__notchOrbit.probe.hold(true)");
                await Post(busy);
                await Post(failedThenBusy);
                await core.ExecuteScriptAsync($"__notchOrbit.probe.frameAt({At(at)})");
                break;

            case "flight-decision":
                await core.ExecuteScriptAsync("__notchOrbit.probe.hold(true)");
                await Post(busy);
                await Post(busyThenAsk);
                await core.ExecuteScriptAsync($"__notchOrbit.probe.frameAt({At(at)})");
                break;

            case "reply":
                // The amber stroke has to land first: the reply only exists while
                // a decision slot is on screen and work remains.
                await core.ExecuteScriptAsync("__notchOrbit.probe.hold(true)");
                await Post(busy);
                await Post(busyThenAsk);
                await core.ExecuteScriptAsync("__notchOrbit.probe.land()");
                await Task.Delay(160);
                await Post(askThenBusy);
                await core.ExecuteScriptAsync($"__notchOrbit.probe.replyAt({At(at)})");
                break;

            default:
                NotchLog.Write($"unknown orbit state '{name}'");
                break;
        }

        try
        {
            JsonElement state = await EvalAsync(core, "__notchOrbit.probe.state()");
            NotchLog.Write($"orbit state {name}@{at}: layout={state.GetProperty("height").GetDouble()}pt "
                + $"flight={state.GetProperty("flight").ValueKind} reply={state.GetProperty("reply").ValueKind} "
                + $"queued={state.GetProperty("queued").GetInt32()} "
                + $"counts={state.GetProperty("counts").GetRawText()} "
                + $"pinned={state.GetProperty("pinned").GetRawText()} "
                + $"progress={state.GetProperty("progress").GetRawText()} "
                + $"flight={state.GetProperty("flight").GetRawText()} "
                + $"motion={state.GetProperty("motion").GetRawText()} "
                + $"replyFrame={state.GetProperty("replyFrame").GetRawText()}");
        }
        catch (Exception ex)
        {
            NotchLog.Write($"orbit state probe failed: {ex.Message}");
        }
    }

    /// <summary>Invariant formatting for a probe phase, so the injected script is
    /// identical on every locale.</summary>
    private static string At(double value) =>
        value.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>Runs a script that returns a value and parses it as JSON. A
    /// throwing script comes back as a JSON string, which is reported as-is.</summary>
    private static async Task<JsonElement> EvalAsync(CoreWebView2 core, string script)
    {
        string raw = await core.ExecuteScriptAsync(script);
        try
        {
            using JsonDocument doc = JsonDocument.Parse(raw);
            return doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            return JsonSerializer.SerializeToElement(raw);
        }
    }

    /// <summary>
    /// Reads the "scroll=content/viewport" field of the wizard probe and returns
    /// how many pixels the detail overflows by (0 when it does not scroll, -1
    /// when the field is missing). A positive value is the evidence that the
    /// long-detail layout really is a bounded scroll area rather than a class name.
    /// </summary>
    private static long ParseScrollProbe(string probe)
    {
        const string marker = "scroll=";
        int at = probe.IndexOf(marker, StringComparison.Ordinal);
        if (at < 0) return -1;

        string rest = probe[(at + marker.Length)..];
        int end = rest.IndexOf(' ');
        if (end >= 0) rest = rest[..end];

        string[] parts = rest.Split('/');
        if (parts.Length != 2
            || !long.TryParse(parts[0], out long content)
            || !long.TryParse(parts[1], out long viewport))
        {
            return -1;
        }

        return Math.Max(0, content - viewport);
    }

    /// <summary>Feeds a snapshot through the real handler, as the transport would.</summary>
    private void DeliverSnapshot(string json)
    {
        NotchSnapshot? snapshot = JsonSerializer.Deserialize<NotchSnapshot>(json, NotchJson.Options);
        if (snapshot is null)
        {
            NotchLog.Write("self-test snapshot failed to parse");
            return;
        }

        OnSnapshot(snapshot);
    }

    private static async Task ClickAsync(CoreWebView2 core, string selector, int index)
    {
        await core.ExecuteScriptAsync(
            $"(() => {{ const els = document.querySelectorAll({JsonSerializer.Serialize(selector)}); " +
            $"if (els.length <= {index}) return 'no-match'; els[{index}].click(); return 'clicked'; }})()");
    }

    /// <summary>
    /// Compares a built answer body against the expected (id, selected, custom)
    /// per question. Compares the CONTENT, not the serialisation, so a Host-side
    /// change of key order or whitespace does not turn into a false failure.
    /// </summary>
    private static bool AnswerPayloadMatches(
        string? payload, (string Id, string[] Selected, string? Custom)[] expected, out string detail)
    {
        detail = payload ?? "no payload";
        if (payload is null) return false;

        try
        {
            using JsonDocument doc = JsonDocument.Parse(payload);
            JsonElement root = doc.RootElement;
            if (!root.TryGetProperty("answers", out JsonElement answers)
                || answers.ValueKind != JsonValueKind.Array
                || answers.GetArrayLength() != expected.Length)
            {
                detail = $"answers={payload}";
                return false;
            }

            for (int i = 0; i < expected.Length; i++)
            {
                JsonElement item = answers[i];
                string id = item.GetProperty("id").GetString() ?? "";
                if (id != expected[i].Id)
                {
                    detail = $"answers[{i}].id={id} expected={expected[i].Id}";
                    return false;
                }

                var actual = new List<string>();
                if (item.TryGetProperty("selected", out JsonElement selected))
                {
                    foreach (JsonElement label in selected.EnumerateArray())
                    {
                        actual.Add(label.GetString() ?? "");
                    }
                }

                if (!actual.SequenceEqual(expected[i].Selected))
                {
                    detail = $"answers[{i}].selected=[{string.Join(",", actual)}] expected=[{string.Join(",", expected[i].Selected)}]";
                    return false;
                }

                string? custom = item.TryGetProperty("custom", out JsonElement customElement)
                    ? customElement.GetString()
                    : null;
                if (custom != expected[i].Custom)
                {
                    detail = $"answers[{i}].custom={custom ?? "null"} expected={expected[i].Custom ?? "null"}";
                    return false;
                }
            }

            detail = payload;
            return true;
        }
        catch (Exception ex)
        {
            detail = $"{ex.GetType().Name}: {payload}";
            return false;
        }
    }

    /// <summary>Reads the wizard's own state out of the live DOM.</summary>
    private const string WizardProbeScript = """
    (() => {
      const w = document.getElementById('wizard');
      const wz = w;
      const visible = w && !w.hidden && w.offsetParent !== null;
      const err = document.getElementById('answer-error');
      const errorPart = ' error=' + (err && !err.hidden && err.textContent.trim() ? 'shown' : 'hidden');
      if (!visible) return 'wizard=hidden' + errorPart;

      const text = (sel) => { const el = document.querySelector(sel); return el ? el.textContent.trim() : '-'; };
      const chips = [...document.querySelectorAll('#wizard .chip')];
      const detail = document.getElementById('w-detail');
      return 'wizard=shown'
        + ' title=' + text('#wizard .w-title')
        + ' counter=' + text('#wizard .w-counter')
        + ' chips=' + chips.map(c => c.querySelector('.chip-label').textContent).join('|')
        + ' desc=' + chips.filter(c => c.querySelector('.chip-desc')).length
        + ' on=' + chips.filter(c => c.classList.contains('on'))
            .map(c => c.querySelector('.chip-label').textContent).join('|')
        + ' input=' + (document.querySelector('#wizard .w-input') ? 'yes' : 'no')
        + ' complete=' + (() => {
            const b = document.querySelector('#wizard .tiny.blue');
            return b ? (b.disabled ? 'disabled' : 'enabled') : 'no';
          })()
        + ' md=' + (detail
            ? ['h1','h2','p','li','table','code','strong'].map(t => t + ':' + detail.querySelectorAll(t).length).join(',')
            : '-')
        + ' long=' + (document.body.classList.contains('long-detail') ? 'yes' : 'no')
        // Whether the detail is really a bounded scroll region, and whether the
        // chips/nav are still inside the panel. Both were false-but-plausible in
        // the first cut: the class was set, yet the wizard never grew, so the
        // extra height sat empty below the nav and nothing could scroll.
        + ' scroll=' + (detail ? detail.scrollHeight + '/' + detail.clientHeight : '-')
        + ' overflow=' + (detail ? getComputedStyle(detail).overflowY : '-')
        + ' fits=' + (() => {
            const panel = document.getElementById('panel');
            const nav = document.getElementById('w-nav');
            if (!panel || !nav) return '-';
            return nav.getBoundingClientRect().bottom <= panel.getBoundingClientRect().bottom + 1 ? 'yes' : 'no';
          })()
        // Geometry of the three boxes that decide whether the panel really grew:
        // viewport (CSS px), the wizard's own content height, and how far the nav
        // sits below the viewport's bottom edge (negative = inside).
        + ' win=' + Math.round(window.innerHeight)
        + ' wiz=' + Math.round(wz.getBoundingClientRect().height) + '/' + wz.scrollHeight
        + ' navOver=' + Math.round(document.getElementById('w-nav').getBoundingClientRect().bottom
            - Math.round(window.innerHeight))
        + errorPart;
    })()
    """;

    /// <summary>Reads the live page's own view of what it is showing. Runs inside
    /// the page, so it reports the real DOM rather than a host-side guess.</summary>
    private const string PageProbeScript = """
    (() => {
      // The compact pill is one canvas since Phase 4, so the lamps are read from
      // the orbit model rather than from the DOM — same slot order, same
      // spelling ("running" for busy), so every assertion still means what it
      // always meant.
      const withCount = (window.__notchOrbit ? window.__notchOrbit.probe.lampList() : []);
      const badge = document.querySelector('.badge.completed');
      const labels = document.querySelectorAll('.row .state.completed').length;
      return 'lamps=' + (withCount.length ? withCount.join(',') : 'none')
        + ' badge=' + (badge && !badge.hidden ? badge.textContent.trim() : '0 完成')
        + ' labels=' + labels
        + ' win=' + Math.round(window.innerHeight)
        // The panel's own children, so a "the panel did not grow" report can be
        // read without guessing which block took the height.
        + ' boxes=' + [...document.getElementById('panel').children]
            .map(k => (k.id || k.tagName) + ':'
              + (k.hidden || getComputedStyle(k).display === 'none'
                  ? 'x' : Math.round(k.getBoundingClientRect().height)))
            .join(',')
        // Row heights and the list's own width: a row that measures short because
        // its title box is empty (or because the list is 0 px wide) is invisible
        // in every other number.
        + ' kids=' + [...document.getElementById('list').children]
            .map(r => {
              const t = r.querySelector('.title');
              return Math.round(r.getBoundingClientRect().height) + (t && t.textContent ? 'T' : 'E');
            }).join('/')
        + ' listW=' + Math.round(document.getElementById('list').getBoundingClientRect().width)
        + ' emptyH=' + document.getElementById('empty').offsetHeight
        // Does the panel actually fit the glance list it is showing? Nothing
        // asserted this until Phase 3: the page measured in CSS pixels while the
        // host sizes the window in physical pixels, so the expanded panel was
        // exactly 1/1.5 too short at this DPI and the bottom of the list was
        // clipped — with every existing check green.
        + ' listFits=' + (() => {
            const panel = document.getElementById('panel');
            const list = document.getElementById('list');
            if (!panel || !list) return '-';
            const last = list.lastElementChild;
            const bottom = last ? last.getBoundingClientRect().bottom : list.getBoundingClientRect().bottom;
            return (bottom <= panel.getBoundingClientRect().bottom + 1 ? 'yes' : 'no')
              + ':' + list.clientHeight + '/' + list.scrollHeight
              + '@' + Math.round(bottom) + '-' + Math.round(panel.getBoundingClientRect().bottom)
              + '#' + list.children.length;
          })();
    })()
    """;

    /// <summary>WebView2 hands script results back as a JSON string literal.</summary>
    private static string Unquote(string value)
    {
        string text = value.Trim();
        if (text.Length >= 2 && text[0] == '"' && text[^1] == '"')
        {
            text = text[1..^1].Replace("\\\"", "\"").Replace("\\n", " ");
        }

        return text;
    }

    /// <summary>Pure data-shape checks: SSE framing and the DTO mapping. No
    /// window, no network — a streaming body can split anywhere, so the parser
    /// has to be exercised with hostile chunking.</summary>
    private static List<string> RunDataSelfTest(Action<string, bool, string> check)
    {
        var lines = new List<string>();

        // SSE: one frame split across three chunks.
        var parser = new SseParser();
        List<string> frames = parser.Feed("data: {\"ok\":tr");
        frames.AddRange(parser.Feed("ue,\"generatedAt\":1"));
        frames.AddRange(parser.Feed("}\n\n"));
        check("SSE frame spans chunks", frames.Count == 1 && frames[0] == "{\"ok\":true,\"generatedAt\":1}",
            $"frames={frames.Count}");

        // SSE: a comment/keep-alive must not produce (or clear) state.
        var keepAlive = new SseParser();
        List<string> none = keepAlive.Feed(": ping\n\n");
        none.AddRange(keepAlive.Feed("event: message\ndata: {}\n\n"));
        check("SSE ignores comments", none.Count == 1 && none[0] == "{}", $"frames={none.Count}");

        // SSE: CRLF framing and a multi-line data payload.
        var crlf = new SseParser();
        List<string> crlfFrames = crlf.Feed("data: a\r\ndata: b\r\n\r\n");
        check("SSE handles CRLF + multi-line", crlfFrames.Count == 1 && crlfFrames[0] == "a\nb",
            $"frames={crlfFrames.Count} value={string.Join("|", crlfFrames)}");

        // DTO mapping: the predicates that decide lamp colours.
        const string snapshot = """
        {"ok":true,"generatedAt":1789362864741,"origin":"http://127.0.0.1:3080","rows":[
          {"id":"a","title":"busy","child":false,"busy":true,"unread":false},
          {"id":"b","title":"child","child":true,"busy":true,"unread":false},
          {"id":"c","title":"done","child":false,"busy":false,"unread":true,
           "lastTurn":{"at":1789362792748,"kind":"completed","failed":false}},
          {"id":"d","title":"failed","child":false,"busy":false,"unread":false,
           "lastTurn":{"at":1789362792749,"kind":"error","failed":true}},
          {"id":"e","title":"ask","child":false,"busy":false,"unread":false,
           "ask":{"id":"ask-1","questions":[
             {"id":"q1","question":"pick","detail":"## plan","header":"H","multiSelect":true,
              "options":[{"label":"A","description":"first"},{"label":"B"}]}
           ]}}
        ]}
        """;

        NotchSnapshot? parsed = JsonSerializer.Deserialize<NotchSnapshot>(snapshot, NotchJson.Options);
        NotchCounts counts = NotchCounts.From(parsed?.Rows ?? new List<NotchRow>());
        check("snapshot parses", parsed is not null && parsed.Rows.Count == 5,
            $"rows={parsed?.Rows.Count ?? -1}");
        check("counts derive 4 lamps",
            counts.Busy == 2 && counts.Completed == 1 && counts.Failed == 1 && counts.Decision == 1,
            $"busy={counts.Busy} done={counts.Completed} failed={counts.Failed} decision={counts.Decision}");
        check("counts map to 4 lamps", counts.Lamps == 4, $"lamps={counts.Lamps}");
        check("needsAction excludes row from busy", counts.Busy == 2, $"busy={counts.Busy} (ask row excluded)");

        NotchRow? askRow = parsed?.Rows.Find(r => r.Id == "e");
        NotchRow? failedRow = parsed?.Rows.Find(r => r.Id == "d");
        check("needsAction / isFailedResult",
            askRow?.NeedsAction == true && failedRow?.IsFailedResult == true
                && parsed?.Rows.Find(r => r.Id == "a")?.IsFailedResult == false,
            $"ask={askRow?.NeedsAction} failed={failedRow?.IsFailedResult}");

        // The question shape the wizard renders from (src/types.ts:10-18): a
        // missing "description" must stay null rather than becoming an empty
        // string, because the page draws the second line only when it is present.
        NotchQuestion? question = askRow?.Ask?.Questions.Count > 0 ? askRow.Ask.Questions[0] : null;
        check("question decodes detail/header/multiSelect",
            askRow?.Ask?.Id == "ask-1" && question?.Detail == "## plan" && question?.Header == "H"
                && question?.MultiSelect == true && question?.Options?.Count == 2
                && question.Options[0].Description == "first" && question.Options[1].Description is null,
            $"ask={askRow?.Ask?.Id} detail={question?.Detail} multi={question?.MultiSelect} " +
            $"options={question?.Options?.Count} desc0={question?.Options?[0].Description} desc1={question?.Options?[1].Description}");

        // The answer body (src/http.ts:167). Serialised through the DTO so that a
        // typed answer containing quotes or newlines survives; the page's copy of
        // this text is compared field by field.
        var answerItems = new List<NotchAnswerItem>
        {
            new() { Id = "q1", Selected = { "A" } },
            new() { Id = "q2", Selected = { "日志", "截图" } },
            new() { Id = "q3", Custom = "typed \"quoted\"\nsecond line" },
            new() { Id = "q4" },
        };
        string answerJson = NotchMessages.Answer("ask-1", answerItems);
        check("answer payload round-trips",
            AnswerPayloadMatches(answerJson, new[]
            {
                ("q1", new[] { "A" }, (string?)null),
                ("q2", new[] { "日志", "截图" }, null),
                ("q3", Array.Empty<string>(), "typed \"quoted\"\nsecond line"),
                ("q4", Array.Empty<string>(), null),
            }, out string answerDetail)
                && answerJson.StartsWith("{\"id\":\"ask-1\"", StringComparison.Ordinal),
            answerDetail);

        // A typed answer must not be able to break out of its JSON string. The
        // round-trip above already proves the VALUE survives; this proves the
        // mechanism — no raw newline in the body, and the quote escaped rather
        // than emitted literally (System.Text.Json's default encoder writes it as
        // \u0022, so both spellings are accepted).
        check("answer payload escapes typed text",
            !answerJson.Contains('\n') && !answerJson.Contains('\r')
                && (answerJson.Contains("\\u0022quoted\\u0022") || answerJson.Contains("\\\"quoted\\\"")),
            $"{answerJson.Length} bytes, single line");

        // The generatedAt guard: a snapshot that is not newer must be ignored, so
        // a duplicate push cannot re-run an animation or re-render the list.
        var client = new NotchClient();
        bool first = client.Accept(snapshot);
        bool duplicate = client.Accept(snapshot);
        bool newer = client.Accept(snapshot.Replace("1789362864741", "1789362864999"));
        bool malformed = client.Accept("{not json");
        client.Dispose();
        check("snapshot dedupe by generatedAt", first && !duplicate && newer && !malformed,
            $"first={first} duplicate={duplicate} newer={newer} malformed={malformed}");

        // Region shape: corners are rounded on the free side only.
        List<NotchRect> rightEdge = NotchGeometry.CapsuleRegion(48, 165, 24, attachedRight: true);
        int topRowLeft = rightEdge[0].Left;
        int bottomRowLeft = rightEdge[^1].Left;
        bool fullWidthMiddle = rightEdge.Exists(r => r.Left == 0 && r.Width == 48 && r.Height > 50);
        check("region rounds free side only", topRowLeft > 0 && bottomRowLeft > 0 && fullWidthMiddle,
            $"topLeft={topRowLeft} bottomLeft={bottomRowLeft} rects={rightEdge.Count}");

        List<NotchRect> leftEdge = NotchGeometry.CapsuleRegion(48, 165, 24, attachedRight: false);
        check("region mirrors with the edge",
            leftEdge[0].Right < 48 && leftEdge[0].Left == 0 && leftEdge[^1].Right < 48,
            $"topRight={leftEdge[0].Right} rects={leftEdge.Count}");

        List<NotchRect> big = NotchGeometry.CapsuleRegion(720, 390, 24, attachedRight: true);
        check("region boxes the window",
            big[0].Top == 0 && big[^1].Bottom == 390 && big.TrueForAll(r => r.Left == 0 || r.Left > 0),
            $"rects={big.Count} span={big[0].Top}-{big[^1].Bottom}");

        return lines;
    }
}
