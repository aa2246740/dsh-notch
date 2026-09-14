namespace DshNotchWin;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool selfTest = Array.Exists(
            args, a => a.Equals("--selftest", StringComparison.OrdinalIgnoreCase));

        int shotIndex = Array.FindIndex(
            args, a => a.Equals("--shot", StringComparison.OrdinalIgnoreCase));
        string? shotPath = shotIndex >= 0 && shotIndex + 1 < args.Length ? args[shotIndex + 1] : null;
        bool shotExpanded = Array.Exists(
            args, a => a.Equals("--expanded", StringComparison.OrdinalIgnoreCase));

        int edgeIndex = Array.FindIndex(
            args, a => a.Equals("--edge", StringComparison.OrdinalIgnoreCase));
        string? edgeArg = edgeIndex >= 0 && edgeIndex + 1 < args.Length ? args[edgeIndex + 1] : null;

        // --shot --ask / --ask-long: render the AskUserQuestion wizard from a
        // synthetic question, so the Phase 3 UI can be captured without a live
        // question pending anywhere.
        bool shotAskLong = Array.Exists(
            args, a => a.Equals("--ask-long", StringComparison.OrdinalIgnoreCase));
        bool shotAsk = shotAskLong || Array.Exists(
            args, a => a.Equals("--ask", StringComparison.OrdinalIgnoreCase));

        // --orbit <state> [--orbit-at <0..1>] [--no-motion]: paint one named status
        // state — or one frozen phase of a status flight — so the Phase 4 four-state
        // stroke can be photographed without waiting for a real task to finish.
        // --no-motion photographs the Reduce Motion contract instead.
        int orbitIndex = Array.FindIndex(
            args, a => a.Equals("--orbit", StringComparison.OrdinalIgnoreCase));
        string? orbitState = orbitIndex >= 0 && orbitIndex + 1 < args.Length ? args[orbitIndex + 1] : null;

        int orbitAtIndex = Array.FindIndex(
            args, a => a.Equals("--orbit-at", StringComparison.OrdinalIgnoreCase));
        double orbitAt = 0.5;
        if (orbitAtIndex >= 0 && orbitAtIndex + 1 < args.Length
            && double.TryParse(args[orbitAtIndex + 1], System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out double parsedAt))
        {
            orbitAt = parsedAt;
        }

        bool noMotion = Array.Exists(
            args, a => a.Equals("--no-motion", StringComparison.OrdinalIgnoreCase));

        // --robot <idle|blink-1.26|hop|dance|flight|arrive> [--robot-at <t>]:
        // paint the Phase 5 idle robot, or one frozen phase of its departure /
        // arrival, so the artwork can be photographed deterministically. For the
        // clip poses `--robot-at` is an absolute page-clock instant; for
        // `flight` / `arrive` it is the OFFSET from the departure / arrival start,
        // which is read back from the page.
        int robotIndex = Array.FindIndex(
            args, a => a.Equals("--robot", StringComparison.OrdinalIgnoreCase));
        string? robotState = robotIndex >= 0 && robotIndex + 1 < args.Length ? args[robotIndex + 1] : null;

        int robotAtIndex = Array.FindIndex(
            args, a => a.Equals("--robot-at", StringComparison.OrdinalIgnoreCase));
        double robotAt = -1;
        if (robotAtIndex >= 0 && robotAtIndex + 1 < args.Length
            && double.TryParse(args[robotAtIndex + 1], System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out double parsedRobotAt))
        {
            robotAt = parsedRobotAt;
        }

        // --icon <path>: write the notification-area glyph out as a PNG (and the
        // multi-size .ico next to it) and exit. The tray icon is drawn in code
        // rather than shipped as a binary asset, so this is the only way to look
        // at it without a notification area in front of you — and it is how the
        // acceptance screenshot in windows/shots was produced.
        int iconIndex = Array.FindIndex(
            args, a => a.Equals("--icon", StringComparison.OrdinalIgnoreCase));
        string? iconPath = iconIndex >= 0 && iconIndex + 1 < args.Length ? args[iconIndex + 1] : null;
        if (iconPath is not null)
        {
            NativeMethods.AttachConsole(-1);

            string iconPng = Path.ChangeExtension(iconPath, ".png");
            string iconIco = Path.ChangeExtension(iconPath, ".ico");

            using (Bitmap bitmap = TrayGlyph.Render(48))
            {
                bitmap.Save(iconPng, System.Drawing.Imaging.ImageFormat.Png);
            }

            using (Icon icon = TrayGlyph.CreateIcon(new[] { 16, 24, 32, 48 }))
            using (FileStream stream = File.Create(iconIco))
            {
                icon.Save(stream);
            }

            Console.WriteLine($"tray icon: {iconPng} + {iconIco} (16/24/32/48)");
            return 0;
        }

        // Upstream warns against running a second helper while one is already
        // shell-managed; a named mutex enforces it in a single instance. The
        // test modes take their own names so they can run beside the real one.
        string mutexName = selfTest ? @"Global\dsh-notch-win-selftest"
            : shotPath is not null ? @"Global\dsh-notch-win-shot"
            : @"Global\dsh-notch-win";
        using var mutex = new Mutex(initiallyOwned: true, name: mutexName, createdNew: out bool isNew);
        if (!isNew)
        {
            Console.Error.WriteLine("dsh-notch-win: already running");
            return 2;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        // DPI awareness is NOT set here on purpose — see app.manifest. The
        // manifest is applied by the OS at process start, so the capsule always
        // measures in physical pixels regardless of how it was launched.

        // A WinExe has no console of its own; without this the self-test report
        // would never reach the terminal that launched it.
        if (selfTest) NativeMethods.AttachConsole(-1);

        var window = new NotchWindow(selfTest, automation: shotPath is not null);

        if (selfTest)
        {
            window.Shown += async (_, _) =>
            {
                int code = await window.RunSelfTestAsync();
                Environment.Exit(code);
            };
            Application.Run(window);
            return 1; // only reached if the window closed before the test finished
        }

        if (shotPath is not null)
        {
            window.Shown += async (_, _) =>
            {
                // Let the renderer paint its first frame before capturing.
                await Task.Delay(2500);
                if (string.Equals(edgeArg, "left", StringComparison.OrdinalIgnoreCase))
                {
                    window.ForceEdge(ScreenEdge.Left);
                }

                if (orbitState is not null)
                {
                    // A status state paints itself inside the collapsed pill and
                    // reports its own height, so nothing else has to be driven.
                    await window.InjectSyntheticOrbitAsync(orbitState, orbitAt, noMotion);
                    await Task.Delay(500);
                    await window.LogPageLayoutAsync();
                    try
                    {
                        window.CaptureTo(shotPath);
                        Console.WriteLine($"captured: {shotPath} (orbit={orbitState} at={orbitAt})");
                        Environment.Exit(0);
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine($"capture failed: {ex.Message}");
                        Environment.Exit(3);
                    }

                    return;
                }

                if (robotState is not null)
                {
                    await window.InjectSyntheticRobotAsync(robotState, robotAt, noMotion);
                    try
                    {
                        window.CaptureTo(shotPath);
                        Console.WriteLine($"captured: {shotPath} (robot={robotState} at={robotAt})");
                        Environment.Exit(0);
                    }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine($"capture failed: {ex.Message}");
                        Environment.Exit(3);
                    }

                    return;
                }

                if (shotAsk)
                {
                    // The question expands the capsule by itself, exactly as a live
                    // one does; --expanded would only be a second way to say it.
                    window.InjectSyntheticAsk(shotAskLong);
                }
                else if (shotExpanded)
                {
                    window.ForceExpanded();
                }

                await Task.Delay(700);

                // Both ForceEdge and ForceExpanded changed the capsule's state
                // from outside the page, and the panel's height depends on the
                // page's own content measurement — so ask for one and give it a
                // frame to arrive before the capture.
                window.RequestContentMeasure();
                await Task.Delay(700);
                await window.LogPageLayoutAsync();
                try
                {
                    window.CaptureTo(shotPath);
                    Console.WriteLine($"captured: {shotPath}");
                    Environment.Exit(0);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"capture failed: {ex.Message}");
                    Environment.Exit(3);
                }
            };
            Application.Run(window);
            return 1;
        }

        Application.Run(window);
        return 0;
    }
}
