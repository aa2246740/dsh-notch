using System.Text;

namespace DshNotchWin;

/// <summary>
/// Incremental parser for the <c>text/event-stream</c> wire format, as used by
/// the Host's <c>GET /dsh-notch/events</c>.
///
/// It is deliberately a pure state machine with no socket in sight: a streaming
/// HTTP body can split anywhere, so "did the frame arrive intact?" has to be
/// testable without a server. <c>--selftest-core</c> feeds it split, merged and
/// multi-line frames (see Program.cs).
///
/// Supported, because a real stream may contain them:
///   * LF and CRLF line endings;
///   * one frame split across arbitrary chunk boundaries;
///   * several <c>data:</c> lines in one frame, joined with "\n";
///   * unknown fields (<c>event:</c>, <c>id:</c>, <c>retry:</c>) — ignored;
///   * comment lines starting with ':' — ignored.
/// The Host only ever emits one <c>data:</c> line, so this is defensive.
/// </summary>
internal sealed class SseParser
{
    private readonly List<string> _data = new();
    private readonly StringBuilder _line = new();

    /// <summary>Feeds one chunk of decoded body text and returns every complete
    /// frame it completed, in order. Incomplete trailing text is buffered.</summary>
    internal List<string> Feed(string chunk)
    {
        var frames = new List<string>();
        if (string.IsNullOrEmpty(chunk)) return frames;

        foreach (char c in chunk)
        {
            if (c != '\n') { _line.Append(c); continue; }

            // Strip the optional CR of a CRLF ending.
            if (_line.Length > 0 && _line[^1] == '\r') _line.Length--;
            HandleLine(_line.ToString(), frames);
            _line.Clear();
        }

        return frames;
    }

    private void HandleLine(string line, List<string> frames)
    {
        if (line.Length == 0)
        {
            // Blank line dispatches. No data lines means it was a pure comment or
            // a keep-alive block, which must NOT be reported as an empty state —
            // an empty payload would otherwise wipe the capsule's rows.
            if (_data.Count == 0) return;

            frames.Add(string.Join("\n", _data));
            _data.Clear();
            return;
        }

        if (line[0] == ':') return; // comment / keep-alive

        int colon = line.IndexOf(':');
        if (colon < 0) return; // field with no value: nothing we use

        string field = line[..colon];
        if (field != "data") return; // event:/id:/retry: carry nothing we consume

        string value = line[(colon + 1)..];

        // Per the spec a single leading space after the colon is stripped.
        if (value.Length > 0 && value[0] == ' ') value = value[1..];
        _data.Add(value);
    }
}
