using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DshNotchWin;

/// <summary>
/// Origin + token the Host writes for its helper. Same file and same
/// environment override as upstream (Client.swift:71-78), so both helpers can
/// run side by side against one Host.
/// </summary>
internal sealed class RuntimeFile
{
    internal const string EnvOverride = "DSH_NOTCH_RUNTIME_FILE";

    internal string Origin { get; private set; } = "";
    internal string Token { get; private set; } = "";

    private static string FilePath()
    {
        string? overridden = Environment.GetEnvironmentVariable(EnvOverride);
        if (!string.IsNullOrWhiteSpace(overridden)) return overridden;

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".dsh", "dsh-notch", "runtime.json");
    }

    /// <summary>Reads the file. Returns null when it is absent or unreadable —
    /// which is the normal state before the Host has ever started.</summary>
    internal static RuntimeFile? Load()
    {
        try
        {
            string path = FilePath();
            if (!File.Exists(path)) return null;

            using JsonDocument doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("origin", out JsonElement origin)
                || !doc.RootElement.TryGetProperty("token", out JsonElement token)) return null;

            string? originText = origin.GetString();
            string? tokenText = token.GetString();
            if (string.IsNullOrWhiteSpace(originText) || string.IsNullOrWhiteSpace(tokenText)) return null;

            return new RuntimeFile
            {
                Origin = originText.TrimEnd('/'),
                Token = tokenText,
            };
        }
        catch
        {
            return null;
        }
    }
}

/// <summary>
/// The HTTP/SSE side of the helper. It lives in the host process, not in the
/// page, for two reasons that are both load-bearing (PLAN.md §7.1):
///   * the page is served from https://notch.local while the API is
///     http://127.0.0.1:&lt;port&gt;, so every page-side fetch would be blocked as
///     cross-origin — the Host sends no CORS headers at all;
///   * the Bearer token then never reaches page JavaScript, matching the Host's
///     own stance (src/http.ts:25-29).
///
/// macOS upstream polls GET /status every ~0.8 s (RootView.swift:170-174). The
/// Host additionally exposes a real SSE stream (<c>GET /events</c>) that the
/// Swift helper never used, so this client subscribes to it and keeps a slow
/// status poll as a correctness net: transport hiccups must never leave the
/// capsule showing stale work.
/// </summary>
internal sealed class NotchClient : IDisposable
{
    private const string StatusPath = "/dsh-notch/status";
    private const string EventsPath = "/dsh-notch/events";
    private const string SeenPath = "/dsh-notch/seen";
    private const string FocusPath = "/dsh-notch/focus";
    private const string AnswerPath = "/dsh-notch/answer";

    /// <summary>Fallback poll while the SSE stream is healthy — it only exists to
    /// catch a snapshot the stream failed to deliver.</summary>
    private static readonly TimeSpan HealthyPollInterval = TimeSpan.FromSeconds(30);

    /// <summary>Poll interval once streaming has failed repeatedly.</summary>
    private static readonly TimeSpan DegradedPollInterval = TimeSpan.FromSeconds(2);

    private static readonly TimeSpan[] ReconnectBackoff =
    {
        TimeSpan.FromMilliseconds(500),
        TimeSpan.FromSeconds(1),
        TimeSpan.FromSeconds(2),
        TimeSpan.FromSeconds(5),
    };

    private readonly HttpClient _http = new() { Timeout = Timeout.InfiniteTimeSpan };
    private readonly CancellationTokenSource _cts = new();

    private RuntimeFile? _runtime;
    private int _consecutiveStreamFailures;
    private long _lastGeneratedAt;

    /// <summary>Raised on a background thread for every accepted snapshot. The
    /// listener marshals to the UI thread; this class touches no UI.</summary>
    internal event Action<NotchSnapshot>? SnapshotReceived;

    /// <summary>Raised when streaming state changes, for the diagnostic log.</summary>
    internal event Action<string>? TransportStateChanged;

    internal NotchClient()
    {
        _http.Timeout = TimeSpan.FromSeconds(10);
    }

    internal bool Connected { get; private set; }

    internal string Origin => _runtime?.Origin ?? "";

    /// <summary>The newest accepted snapshot. Kept for diagnostics and for the
    /// self-test; the page is driven by the pushed JSON, not by this.</summary>
    internal NotchSnapshot? LastSnapshot { get; private set; }

    /// <summary>Number of snapshots accepted since start — the self-test uses it
    /// as evidence that real data actually flowed.</summary>
    internal int SnapshotCount { get; private set; }

    internal void Start()
    {
        _ = Task.Run(() => RunAsync(_cts.Token));
    }

    private async Task RunAsync(CancellationToken token)
    {
        bool streamHealthy = true;

        while (!token.IsCancellationRequested)
        {
            try
            {
                if (_runtime is null) ReloadRuntime();
                if (_runtime is null)
                {
                    // No Host has ever run. Wait rather than spin.
                    await Task.Delay(TimeSpan.FromSeconds(2), token).ConfigureAwait(false);
                    continue;
                }

                if (streamHealthy)
                {
                    await StreamAsync(token).ConfigureAwait(false);
                    // A stream that ended on its own is a failure until proven
                    // otherwise; the backoff below decides how patient to be.
                    throw new IOException("event stream ended");
                }

                await Task.Delay(DegradedPollInterval, token).ConfigureAwait(false);
                if (await FetchStatusAsync(token).ConfigureAwait(false)) streamHealthy = true;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                _consecutiveStreamFailures++;
                streamHealthy = false;
                Connected = false;
                TransportStateChanged?.Invoke($"stream failed ({_consecutiveStreamFailures}): {ex.GetType().Name} {ex.Message}");

                // A dead Host usually means a REBUILT Host: the web server comes
                // back on a new port and writes a new runtime.json, so re-read it
                // before reconnecting instead of retrying a stale origin forever.
                ReloadRuntime();

                TimeSpan wait = ReconnectBackoff[Math.Min(_consecutiveStreamFailures - 1, ReconnectBackoff.Length - 1)];
                try
                {
                    await Task.Delay(wait, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    private void ReloadRuntime()
    {
        RuntimeFile? loaded = RuntimeFile.Load();
        if (loaded is null) return;
        if (_runtime is null || _runtime.Origin != loaded.Origin || _runtime.Token != loaded.Token)
        {
            TransportStateChanged?.Invoke($"runtime origin={loaded.Origin}");
        }

        _runtime = loaded;
    }

    /// <summary>Consumes the SSE stream until it ends or the token fires.</summary>
    private async Task StreamAsync(CancellationToken token)
    {
        RuntimeFile? runtime = _runtime;
        if (runtime is null) return;

        using var request = new HttpRequestMessage(HttpMethod.Get, runtime.Origin + EventsPath);
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + runtime.Token);
        request.Headers.TryAddWithoutValidation("Accept", "text/event-stream");

        using HttpResponseMessage response = await _http
            .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token)
            .ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            throw new IOException($"events HTTP {(int)response.StatusCode}");
        }

        Connected = true;
        _consecutiveStreamFailures = 0;
        TransportStateChanged?.Invoke("stream connected");

        await using Stream body = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
        var reader = new StreamReader(body, Encoding.UTF8);
        var parser = new SseParser();
        var buffer = new char[8192];

        // The Host pushes a full snapshot per change and nothing else, so there is
        // no event id / Last-Event-ID resume to honour: every frame is complete
        // state, and a reconnect simply gets a fresh one immediately.
        while (!token.IsCancellationRequested)
        {
            int read = await reader.ReadAsync(buffer, token).ConfigureAwait(false);
            if (read <= 0) break;

            foreach (string frame in parser.Feed(new string(buffer, 0, read)))
            {
                Accept(frame);
            }
        }
    }

    /// <summary>Parses one SSE data payload and forwards it if it is a snapshot
    /// that is newer than the last accepted one.</summary>
    internal bool Accept(string payload)
    {
        if (string.IsNullOrWhiteSpace(payload)) return false;

        NotchSnapshot? snapshot;
        try
        {
            snapshot = JsonSerializer.Deserialize<NotchSnapshot>(payload, NotchJson.Options);
        }
        catch (JsonException)
        {
            return false;
        }

        if (snapshot is null) return false;

        // Both the stream and the safety poll can deliver the same snapshot; the
        // Host's generatedAt (Date.now()) is the sequence number that keeps the
        // UI from redrawing — and, later, replaying animations — for nothing.
        if (snapshot.GeneratedAt <= _lastGeneratedAt) return false;

        _lastGeneratedAt = snapshot.GeneratedAt;
        LastSnapshot = snapshot;
        SnapshotCount++;
        SnapshotReceived?.Invoke(snapshot);
        return true;
    }

    /// <summary>
    /// One synchronous <c>GET /status</c>, used by the self-test. It goes through
    /// the same runtime file, the same Bearer header and the same DTO as the
    /// streaming path, so a self-test against a running Host proves the whole
    /// handshake — auth rejections, a renamed route and a drifted DTO all fail
    /// here rather than silently producing an empty capsule.
    /// </summary>
    internal static string? FetchStatusOnce(int timeoutMs = 4000)
    {
        RuntimeFile? runtime = RuntimeFile.Load();
        if (runtime is null) return null;

        using var http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(timeoutMs) };
        using var request = new HttpRequestMessage(HttpMethod.Get, runtime.Origin + StatusPath);
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + runtime.Token);

        try
        {
            using HttpResponseMessage response = http.Send(request);
            if (!response.IsSuccessStatusCode) return null;
            using var reader = new StreamReader(response.Content.ReadAsStream());
            return reader.ReadToEnd();
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Sends one REAL <c>POST /dsh-notch/answer</c> for an ask id that cannot be
    /// pending, and returns the status code. The Host validates the body shape
    /// before it looks the id up (src/http.ts:166-175), so a well-formed body
    /// must come back 404 ("not pending") and a malformed one 400 — which makes
    /// this a non-invasive contract test of what the page's answers become: no
    /// question is answered and no state is written.
    /// Returns null when no Host is reachable.
    /// </summary>
    internal static int? ProbeAnswerRoute(int timeoutMs = 4000)
    {
        RuntimeFile? runtime = RuntimeFile.Load();
        if (runtime is null) return null;

        using var http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(timeoutMs) };
        using var request = new HttpRequestMessage(HttpMethod.Post, runtime.Origin + AnswerPath);
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + runtime.Token);
        request.Content = new StringContent(
            NotchMessages.Answer("dsh-notch-win-selftest-not-pending", new List<NotchAnswerItem>
            {
                new() { Id = "selftest", Selected = { "selftest" } },
            }),
            Encoding.UTF8,
            "application/json");

        try
        {
            using HttpResponseMessage response = http.Send(request);
            return (int)response.StatusCode;
        }
        catch
        {
            return null;
        }
    }

    private async Task<bool> FetchStatusAsync(CancellationToken token)
    {
        RuntimeFile? runtime = _runtime;
        if (runtime is null) return false;

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, runtime.Origin + StatusPath);
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + runtime.Token);

            using HttpResponseMessage response = await _http.SendAsync(request, token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return false;

            string body = await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);
            return Accept(body);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Marks one session, or every session, as seen.</summary>
    internal async Task<bool> MarkSeenAsync(string? sessionId)
    {
        string json = sessionId is null
            ? "{\"all\":true}"
            : $"{{\"sessionId\":{JsonSerializer.Serialize(sessionId)}}}";
        return await PostAsync(SeenPath, json).ConfigureAwait(false);
    }

    /// <summary>Asks any open DSH page to jump to this session. The Host holds
    /// the wish for 60 s (board.ts:139-145).</summary>
    internal async Task<bool> RequestFocusAsync(string sessionId)
    {
        return await PostAsync(FocusPath, $"{{\"sessionId\":{JsonSerializer.Serialize(sessionId)}}}")
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Answers a pending AskUserQuestion. This is the one request whose payload is
    /// built from user input rather than from a session id, so it goes through
    /// <see cref="NotchMessages.Answer"/> — the same function the data self-test
    /// drives — instead of being assembled inline here.
    ///
    /// The Host (src/http.ts:166-178) needs both ids: the ask id to find the
    /// pending question, and one item per question, or it answers 400/404.
    /// </summary>
    internal async Task<bool> AnswerAsync(string askId, List<NotchAnswerItem> answers)
    {
        return await PostAsync(AnswerPath, NotchMessages.Answer(askId, answers)).ConfigureAwait(false);
    }

    private async Task<bool> PostAsync(string path, string json)
    {
        RuntimeFile? runtime = _runtime;
        if (runtime is null) return false;

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, runtime.Origin + path);
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + runtime.Token);
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");

            using HttpResponseMessage response = await _http.SendAsync(request, _cts.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                TransportStateChanged?.Invoke($"POST {path} -> {(int)response.StatusCode}");
            }

            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            TransportStateChanged?.Invoke($"POST {path} failed: {ex.GetType().Name} {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Brings the DSH window forward so "回焦" is visible, the counterpart of
    /// upstream <c>activateDSH()</c> (RootView.swift:1082-1093).
    ///
    /// Upstream can look the app up by bundle identifier. Windows has no such
    /// registry, so this walks top-level windows and picks the first one whose
    /// process looks like the DSH host. Failing to find it is not an error: the
    /// focus wish is still recorded on the Host, and it is consumed the next
    /// time a DSH page polls. There is no process to activate for a browser tab.
    /// </summary>
    internal static bool TryActivateDshWindow()
    {
        try
        {
            IntPtr best = IntPtr.Zero;
            NativeMethods.EnumWindows((hwnd, _) =>
            {
                if (!NativeMethods.IsWindowVisible(hwnd)) return true;

                NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
                if (pid == 0) return true;

                string processName;
                try
                {
                    processName = Process.GetProcessById((int)pid).ProcessName;
                }
                catch
                {
                    return true;
                }

                if (!processName.Contains("dsh", StringComparison.OrdinalIgnoreCase)
                    && !processName.Contains("electron", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }

                // A real top-level window has a non-empty title and no owner.
                int length = NativeMethods.GetWindowTextLength(hwnd);
                if (length <= 0 || NativeMethods.GetWindow(hwnd, NativeMethods.GW_OWNER) != IntPtr.Zero) return true;

                best = hwnd;
                return false; // stop at the first match
            }, IntPtr.Zero);

            if (best == IntPtr.Zero) return false;
            return NativeMethods.SetForegroundWindow(best);
        }
        catch
        {
            return false;
        }
    }

    public void Dispose()
    {
        try { _cts.Cancel(); } catch { /* already disposed */ }
        _cts.Dispose();
        _http.Dispose();
    }
}

/// <summary>
/// Builds the JSON the page receives. Written by hand rather than by
/// serialising DTO types so that the outbound shape is visible in one place —
/// it is a wire contract with the HTML, not an internal object graph.
/// </summary>
internal static class NotchMessages
{
    private const string Num = "0.###";

    private static string N(double value) =>
        value.ToString(Num, CultureInfo.InvariantCulture);

    internal static string Geometry(
        bool expanded, int width, int height, int radius, string edge, bool hovered, double scale,
        int? contentHeight, bool settled, bool motion)
    {
        var sb = new StringBuilder(192);
        sb.Append("{\"type\":\"geometry\"")
          .Append(",\"expanded\":").Append(expanded ? "true" : "false")
          .Append(",\"width\":").Append(width)
          .Append(",\"height\":").Append(height)
          .Append(",\"radius\":").Append(radius)
          .Append(",\"edge\":\"").Append(edge).Append('"')
          .Append(",\"hovered\":").Append(hovered ? "true" : "false")
          .Append(",\"scale\":").Append(N(scale))
          // The page only measures its content once the bloom has landed: a
          // measurement taken mid-animation would re-target the capsule it was
          // measured for.
          .Append(",\"settled\":").Append(settled ? "true" : "false")
          // Reduce Motion is a host fact (SPI_GETCLIENTAREAANIMATION), so the page
          // is told instead of guessing: with it off there is no flight, no spin,
          // and the counts appear in place (STATUS-MOTION.md:5).
          .Append(",\"motion\":").Append(motion ? "true" : "false");
        if (contentHeight is int ch) sb.Append(",\"contentHeight\":").Append(ch);
        sb.Append('}');
        return sb.ToString();
    }

    internal static string Hover(bool hovered) =>
        hovered ? "{\"type\":\"hover\",\"hovered\":true}" : "{\"type\":\"hover\",\"hovered\":false}";

    /// <summary>
    /// Body of <c>POST /dsh-notch/answer</c>: <c>{ id, answers: [...] }</c>
    /// (src/http.ts:167).
    ///
    /// Serialised through the DTO rather than hand-built like the geometry and
    /// snapshot messages above, because the strings here originate in the page
    /// and can contain quotes, newlines and — with a pasted answer — anything
    /// else. A hand-rolled builder that forgot one escape would silently corrupt
    /// an answer instead of failing loudly.
    /// </summary>
    internal static string Answer(string askId, List<NotchAnswerItem> answers)
    {
        return JsonSerializer.Serialize(
            new { id = askId, answers },
            AnswerJson);
    }

    private static readonly JsonSerializerOptions AnswerJson = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    internal static string Snapshot(NotchSnapshot snapshot, NotchCounts counts)
    {
        var sb = new StringBuilder(1024);
        sb.Append("{\"type\":\"snapshot\"")
          .Append(",\"generatedAt\":").Append(snapshot.GeneratedAt)
          .Append(",\"counts\":{")
          .Append("\"busy\":").Append(counts.Busy)
          .Append(",\"completed\":").Append(counts.Completed)
          .Append(",\"failed\":").Append(counts.Failed)
          .Append(",\"decision\":").Append(counts.Decision)
          .Append(",\"rows\":").Append(counts.Rows)
          .Append("},\"rows\":[");

        for (int i = 0; i < snapshot.Rows.Count; i++)
        {
            if (i > 0) sb.Append(',');
            AppendRow(sb, snapshot.Rows[i]);
        }

        sb.Append("]}");
        return sb.ToString();
    }

    private static void AppendRow(StringBuilder sb, NotchRow row)
    {
        sb.Append("{\"id\":").Append(JsonSerializer.Serialize(row.Id))
          .Append(",\"title\":").Append(JsonSerializer.Serialize(row.Title))
          .Append(",\"child\":").Append(row.Child ? "true" : "false")
          .Append(",\"busy\":").Append(row.Busy ? "true" : "false")
          .Append(",\"unread\":").Append(row.Unread ? "true" : "false")
          .Append(",\"needsAction\":").Append(row.NeedsAction ? "true" : "false")
          .Append(",\"failed\":").Append(row.IsFailedResult ? "true" : "false");

        if (row.LastTurn is NotchLastTurn last)
        {
            sb.Append(",\"lastTurn\":{\"at\":").Append(last.At)
              .Append(",\"kind\":").Append(JsonSerializer.Serialize(last.Kind))
              .Append(",\"failed\":").Append(last.Failed ? "true" : "false")
              .Append('}');
        }

        if (row.Approval is NotchApproval approval)
        {
            sb.Append(",\"approval\":{\"id\":").Append(JsonSerializer.Serialize(approval.Id))
              .Append(",\"toolName\":").Append(JsonSerializer.Serialize(approval.ToolName));
            if (approval.Reason is string reason) sb.Append(",\"reason\":").Append(JsonSerializer.Serialize(reason));
            sb.Append('}');
        }

        if (row.Ask is NotchAsk ask)
        {
            sb.Append(",\"ask\":{\"id\":").Append(JsonSerializer.Serialize(ask.Id))
              .Append(",\"questions\":[");
            for (int i = 0; i < ask.Questions.Count; i++)
            {
                if (i > 0) sb.Append(',');
                AppendQuestion(sb, ask.Questions[i]);
            }

            sb.Append("]}");
        }

        sb.Append('}');
    }

    private static void AppendQuestion(StringBuilder sb, NotchQuestion question)
    {
        sb.Append("{\"id\":").Append(JsonSerializer.Serialize(question.Id))
          .Append(",\"question\":").Append(JsonSerializer.Serialize(question.Question));

        if (question.Detail is string detail) sb.Append(",\"detail\":").Append(JsonSerializer.Serialize(detail));
        if (question.Header is string header) sb.Append(",\"header\":").Append(JsonSerializer.Serialize(header));
        if (question.MultiSelect is bool multi) sb.Append(",\"multiSelect\":").Append(multi ? "true" : "false");

        if (question.Options is List<NotchOption> options)
        {
            sb.Append(",\"options\":[");
            for (int i = 0; i < options.Count; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append("{\"label\":").Append(JsonSerializer.Serialize(options[i].Label));
                if (options[i].Description is string description)
                {
                    sb.Append(",\"description\":").Append(JsonSerializer.Serialize(description));
                }

                sb.Append('}');
            }

            sb.Append(']');
        }

        sb.Append('}');
    }
}

/// <summary>Named pipes are not needed here; this is just a small diagnostic sink
/// shared by the transport and the window.</summary>
internal static class NotchLog
{
    private static readonly object Gate = new();

    internal static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                File.AppendAllText(
                    Path.Combine(Path.GetTempPath(), "dsh-notch-win.log"),
                    $"{DateTime.Now:O} {message}{Environment.NewLine}");
            }
        }
        catch
        {
            // diagnostics must never take the capsule down
        }
    }
}
