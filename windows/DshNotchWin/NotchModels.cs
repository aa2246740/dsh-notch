using System.Text.Json;
using System.Text.Json.Serialization;

namespace DshNotchWin;

// ---------------------------------------------------------------------------
// Wire contract with the Host plugin. Mirrors src/types.ts one-for-one; the
// names must stay in sync with the Host, which is the upstream文件 kept
// unmodified (PLAN.md §2: the Host layer needs zero porting).
// ---------------------------------------------------------------------------

internal sealed class NotchOption
{
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    [JsonPropertyName("description")] public string? Description { get; set; }
}

internal sealed class NotchQuestion
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("question")] public string Question { get; set; } = "";
    [JsonPropertyName("detail")] public string? Detail { get; set; }
    [JsonPropertyName("header")] public string? Header { get; set; }
    [JsonPropertyName("options")] public List<NotchOption>? Options { get; set; }
    [JsonPropertyName("multiSelect")] public bool? MultiSelect { get; set; }
}

/// <summary>
/// One answer to one question, i.e. the wire shape of NotchAnswerItem
/// (src/types.ts:56-60). The macOS helper builds these as loose dictionaries
/// (RootView.swift:505-515); this is the same three fields with the same
/// omission rule — "custom" is absent, not empty, when the user picked an option.
/// </summary>
internal sealed class NotchAnswerItem
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";

    /// <summary>Labels of the chosen options. Cleared for a single-select
    /// question whose answer was typed instead.</summary>
    [JsonPropertyName("selected")] public List<string> Selected { get; set; } = new();

    [JsonPropertyName("custom")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Custom { get; set; }
}

internal sealed class NotchApproval
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("toolName")] public string ToolName { get; set; } = "";
    [JsonPropertyName("reason")] public string? Reason { get; set; }
}

internal sealed class NotchAsk
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("questions")] public List<NotchQuestion> Questions { get; set; } = new();
}

internal sealed class NotchLastTurn
{
    /// <summary>Unix milliseconds (the Host sends Date.now()).</summary>
    [JsonPropertyName("at")] public long At { get; set; }

    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("failed")] public bool Failed { get; set; }
}

internal sealed class NotchRow
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("child")] public bool Child { get; set; }
    [JsonPropertyName("busy")] public bool Busy { get; set; }
    [JsonPropertyName("unread")] public bool Unread { get; set; }
    [JsonPropertyName("lastTurn")] public NotchLastTurn? LastTurn { get; set; }
    [JsonPropertyName("approval")] public NotchApproval? Approval { get; set; }
    [JsonPropertyName("ask")] public NotchAsk? Ask { get; set; }

    /// <summary>Ports NotchRow.needsAction (Client.swift:50).</summary>
    [JsonIgnore] public bool NeedsAction => Approval is not null || Ask is not null;

    /// <summary>
    /// Ports NotchRow.isFailedResult (Client.swift:52): a red lamp is a finished
    /// unsuccessful turn, never a session that is still running.
    /// </summary>
    [JsonIgnore] public bool IsFailedResult => LastTurn?.Failed == true && !Busy && !NeedsAction;
}

internal sealed class NotchSnapshot
{
    [JsonPropertyName("ok")] public bool Ok { get; set; }

    /// <summary>Unix milliseconds.</summary>
    [JsonPropertyName("generatedAt")] public long GeneratedAt { get; set; }

    [JsonPropertyName("sidebarSyncedAt")] public long? SidebarSyncedAt { get; set; }
    [JsonPropertyName("origin")] public string Origin { get; set; } = "";
    [JsonPropertyName("rows")] public List<NotchRow> Rows { get; set; } = new();
}

/// <summary>
/// Four-state tallies the capsule UI is built from. Derived exactly like the
/// macOS BoardModel (RootView.swift:133-156):
///   busy            = rows.filter { $0.busy && !$0.needsAction }.count
///   completedUnread = rows.filter { $0.unread &amp;&amp; !$0.busy &amp;&amp; lastTurn?.failed != true &amp;&amp; !$0.needsAction }
///   failed          = rows.filter(\.isFailedResult)
///   decision        = rows.contains(where: \.needsAction) ? 1 : 0
/// Note that a row waiting for input is excluded from the running count — the
/// upstream comment (docs/motion-continuity.md:25) is explicit about it.
/// </summary>
internal sealed class NotchCounts
{
    [JsonPropertyName("busy")] public int Busy { get; set; }
    [JsonPropertyName("completed")] public int Completed { get; set; }
    [JsonPropertyName("failed")] public int Failed { get; set; }
    [JsonPropertyName("decision")] public int Decision { get; set; }
    [JsonPropertyName("rows")] public int Rows { get; set; }

    /// <summary>
    /// Number of status disks the compact capsule has to show, i.e. the sum the
    /// upstream <c>OrbitLayout.total</c> converges to. Fractional mid-animation
    /// values round to the nearest disk; see RestHeightFromLamps.
    /// </summary>
    [JsonIgnore] public int Lamps => (Busy > 0 ? 1 : 0) + (Completed > 0 ? 1 : 0)
        + (Failed > 0 ? 1 : 0) + (Decision > 0 ? 1 : 0);

    internal static NotchCounts From(List<NotchRow> rows)
    {
        var counts = new NotchCounts { Rows = rows.Count };
        foreach (NotchRow row in rows)
        {
            if (row.NeedsAction)
            {
                counts.Decision = 1;
            }
            else if (row.Busy)
            {
                counts.Busy++;
            }

            if (row.Unread && !row.Busy && row.LastTurn?.Failed != true && !row.NeedsAction)
            {
                counts.Completed++;
            }

            if (row.IsFailedResult) counts.Failed++;
        }

        return counts;
    }
}

/// <summary>
/// Shared JSON options. The Host emits camelCase and omits absent fields; both
/// directions are tolerated so a Host-side rename to PascalCase could not
/// silently produce empty rows.
/// </summary>
internal static class NotchJson
{
    internal static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
    };
}
