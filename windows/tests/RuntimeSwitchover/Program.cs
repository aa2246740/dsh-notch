using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using DshNotchWin;

string runtime = Path.Combine(Path.GetTempPath(), "notch-runtime-switch-" + Guid.NewGuid().ToString("n") + ".json");
Environment.SetEnvironmentVariable("DSH_NOTCH_RUNTIME_FILE", runtime);

try
{
    await ReplacementDuringBackoff();
    await ReplacementDuringDegradedWait();
    await SameOriginComesBack();
    Console.WriteLine("runtime switchover=PASS");
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex);
    return 1;
}
finally
{
    try { File.Delete(runtime); } catch { /* the assertion above is the result */ }
}

static void WriteRuntime(string runtime, TestServer server) =>
    File.WriteAllText(runtime, JsonSerializer.Serialize(new
    {
        origin = server.Origin,
        token = "runtime-switch-test",
        pid = Environment.ProcessId,
        writtenAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
    }));

static async Task WaitUntil(Func<bool> ready, TimeSpan budget, string failure)
{
    DateTime started = DateTime.UtcNow;
    while (!ready())
    {
        if (DateTime.UtcNow - started > budget) throw new TimeoutException(failure);
        await Task.Delay(50).ConfigureAwait(false);
    }
}

static ArmedClient Arm(string runtime, TestServer server, long generation)
{
    WriteRuntime(runtime, server);
    var client = new NotchClient();
    var connected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var failed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    client.SnapshotReceived += snapshot =>
    {
        if (snapshot.GeneratedAt == generation) connected.TrySetResult();
    };
    client.TransportStateChanged += state =>
    {
        if (state.StartsWith("stream failed", StringComparison.Ordinal)) failed.TrySetResult();
    };
    client.Start();
    return new ArmedClient(client, connected.Task, failed.Task);
}

async Task ReplacementDuringBackoff()
{
    await using var a = new TestServer(1);
    await using var b = new TestServer(2);
    ArmedClient armed = Arm(runtime, a, 1);
    using NotchClient client = armed.Client;
    await armed.Connected.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    a.Stop();
    await armed.Failed.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    await Task.Delay(350).ConfigureAwait(false);
    WriteRuntime(runtime, b);
    await WaitUntil(
        () => client.LastSnapshot?.GeneratedAt == 2 && client.Origin == b.Origin && b.Requests > 0,
        TimeSpan.FromSeconds(5),
        $"backoff switch failed origin={client.Origin} snap={client.LastSnapshot?.GeneratedAt} bRequests={b.Requests}").ConfigureAwait(false);
    Console.WriteLine("replacement during backoff=PASS");
}

async Task ReplacementDuringDegradedWait()
{
    await using var a = new TestServer(1);
    await using var b = new TestServer(2);
    ArmedClient armed = Arm(runtime, a, 1);
    using NotchClient client = armed.Client;
    await armed.Connected.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    a.Stop();
    await armed.Failed.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    await Task.Delay(900).ConfigureAwait(false);
    if (client.Origin != a.Origin || b.Requests != 0)
    {
        throw new InvalidOperationException($"switched before the replacement file existed origin={client.Origin} bRequests={b.Requests}");
    }

    WriteRuntime(runtime, b);
    await WaitUntil(
        () => client.LastSnapshot?.GeneratedAt == 2 && client.Origin == b.Origin && b.Requests > 0,
        TimeSpan.FromSeconds(6),
        $"degraded-wait switch failed origin={client.Origin} snap={client.LastSnapshot?.GeneratedAt} bRequests={b.Requests}").ConfigureAwait(false);
    Console.WriteLine("replacement during degraded wait=PASS");
}

async Task SameOriginComesBack()
{
    await using var host = new TestServer(4);
    ArmedClient armed = Arm(runtime, host, 4);
    using NotchClient client = armed.Client;
    await armed.Connected.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    int port = new Uri(host.Origin).Port;
    host.Stop();
    await armed.Failed.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
    await using var again = new TestServer(5, port);
    await WaitUntil(
        () => client.LastSnapshot?.GeneratedAt == 5 && client.Origin == host.Origin,
        TimeSpan.FromSeconds(8),
        $"same-origin recovery failed origin={client.Origin} snap={client.LastSnapshot?.GeneratedAt}").ConfigureAwait(false);
    Console.WriteLine("same-origin recovery=PASS");
}

readonly record struct ArmedClient(NotchClient Client, Task Connected, Task Failed);

sealed class TestServer : IAsyncDisposable
{
    readonly HttpListener listener = new();
    readonly CancellationTokenSource stop = new();
    readonly long generation;
    int requests;
    public int Requests => requests;
    public string Origin { get; }

    public TestServer(long generation, int fixedPort = 0)
    {
        this.generation = generation;
        using var socket = new TcpListener(IPAddress.Loopback, 0);
        socket.Start();
        int port = fixedPort > 0 ? fixedPort : ((IPEndPoint)socket.LocalEndpoint).Port;
        socket.Stop();
        Origin = $"http://127.0.0.1:{port}";
        listener.Prefixes.Add(Origin + "/");
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                listener.Start();
                break;
            }
            catch (HttpListenerException) when (fixedPort > 0 && attempt < 20)
            {
                Thread.Sleep(50);
            }
        }
        _ = Task.Run(AcceptLoop);
    }

    async Task AcceptLoop()
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                HttpListenerContext context = await listener.GetContextAsync().ConfigureAwait(false);
                Interlocked.Increment(ref requests);
                _ = Serve(context);
            }
        }
        catch (Exception) when (stop.IsCancellationRequested || !listener.IsListening)
        {
        }
    }

    async Task Serve(HttpListenerContext context)
    {
        try
        {
            string json = JsonSerializer.Serialize(new
            {
                ok = true,
                generatedAt = generation,
                origin = Origin,
                rows = Array.Empty<object>(),
            });
            bool stream = context.Request.Url!.AbsolutePath.EndsWith("events", StringComparison.Ordinal);
            context.Response.ContentType = stream ? "text/event-stream" : "application/json";
            byte[] bytes = Encoding.UTF8.GetBytes(stream ? "data: " + json + "\n\n" : json);
            await context.Response.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
            await context.Response.OutputStream.FlushAsync().ConfigureAwait(false);
            if (stream) await Task.Delay(Timeout.Infinite, stop.Token).ConfigureAwait(false);
        }
        catch (Exception) when (stop.IsCancellationRequested)
        {
        }
        finally
        {
            try { context.Response.Close(); } catch { /* client already gone */ }
        }
    }

    public void Stop()
    {
        if (stop.IsCancellationRequested) return;
        stop.Cancel();
        listener.Close();
    }

    public ValueTask DisposeAsync()
    {
        Stop();
        stop.Dispose();
        return ValueTask.CompletedTask;
    }
}
