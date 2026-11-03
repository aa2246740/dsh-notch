using System.Text.Json;
using System.Text.Json.Serialization;

namespace DshNotchWin;

/// <summary>Which screen edge the capsule is snapped to.</summary>
internal enum ScreenEdge
{
    Left,
    Right,
}

/// <summary>
/// Persisted capsule position.
///
/// The capsule is always attached to a screen edge and only slides vertically,
/// so the position is just (edge, top). Storing the edge rather than a free
/// coordinate means a saved position can never end up floating in the middle of
/// the desktop, and the rounded corners can be mirrored to match.
///
/// Lives beside the Host plugin's runtime file so everything this feature owns
/// is in one directory: %USERPROFILE%\.dsh\dsh-notch\window.json
/// </summary>
internal sealed class WindowPlacement
{
    /// <summary>Test/automation override, mirroring the upstream
    /// DSH_NOTCH_RUNTIME_FILE escape hatch.</summary>
    internal const string EnvOverride = "DSH_NOTCH_WINDOW_FILE";

    [JsonPropertyName("edge")]
    public string? Edge { get; set; }

    /// <summary>X of the snapped screen edge — identifies the monitor, so the
    /// capsule returns to the same display.</summary>
    [JsonPropertyName("edgeX")]
    public int EdgeX { get; set; }

    [JsonPropertyName("top")]
    public int Top { get; set; }

    [JsonPropertyName("savedAt")]
    public long SavedAt { get; set; }

    // Legacy format (a freely dragged capsule, before edge snapping). Read so an
    // already-chosen position survives the upgrade instead of snapping back.
    // Never written, and omitted from the file when null.
    [JsonPropertyName("topRightX")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? LegacyTopRightX { get; set; }

    [JsonPropertyName("topRightY")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? LegacyTopRightY { get; set; }

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    internal static string FilePath()
    {
        string? overridden = Environment.GetEnvironmentVariable(EnvOverride);
        if (!string.IsNullOrWhiteSpace(overridden)) return overridden;

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".dsh",
            "dsh-notch",
            "window.json");
    }

    internal static WindowPlacement? Load()
    {
        try
        {
            string path = FilePath();
            if (!File.Exists(path)) return null;

            WindowPlacement? placement =
                JsonSerializer.Deserialize<WindowPlacement>(File.ReadAllText(path));
            if (placement is null) return null;

            bool hasEdge = !string.IsNullOrWhiteSpace(placement.Edge);
            bool hasLegacy = placement.LegacyTopRightX.HasValue && placement.LegacyTopRightY.HasValue;
            return hasEdge || hasLegacy ? placement : null;
        }
        catch
        {
            // A corrupt file must never stop the capsule from starting; falling
            // back to the computed anchor is always safe.
            return null;
        }
    }

    /// <summary>Best-effort persist. Never throws: failing to remember a drag is
    /// not a reason to disturb the running overlay.</summary>
    internal static void Save(ScreenEdge edge, int edgeX, int top)
    {
        try
        {
            string path = FilePath();
            string? dir = Path.GetDirectoryName(Path.GetFullPath(path));
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            var placement = new WindowPlacement
            {
                Edge = edge == ScreenEdge.Left ? "left" : "right",
                EdgeX = edgeX,
                Top = top,
                SavedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            };

            File.WriteAllText(path, JsonSerializer.Serialize(placement, Options) + Environment.NewLine);
        }
        catch
        {
            // ignored on purpose
        }
    }

    internal static void Clear()
    {
        try
        {
            string path = FilePath();
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
            // ignored on purpose
        }
    }
}
