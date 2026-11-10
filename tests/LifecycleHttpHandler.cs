#nullable enable
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Hexagon.LifecycleTests;

public sealed class LifecycleHttpHandler : HttpMessageHandler
{
    public Dictionary<string, byte[]> Blobs { get; } = new();
    public Dictionary<string, string> Etags { get; } = new();
    public Dictionary<string, Tuple<int, byte[]>> Routes { get; } = new();
    public List<string> Requests { get; } = new();
    public List<Dictionary<string, string>> Headers { get; } = new();
    public string? LeaseId { get; set; }
    public int WriteFailure { get; set; }
    private int revision;

    public void Route(string method, string uri, int status, string json) =>
        Routes[method + " " + new Uri(uri).AbsoluteUri] = Tuple.Create(status, Encoding.UTF8.GetBytes(json));

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var uri = request.RequestUri!;
        var key = request.Method + " " + uri.AbsoluteUri;
        Requests.Add(key);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var header in request.Headers) headers[header.Key] = string.Join(",", header.Value);
        Headers.Add(headers);
        if (Routes.TryGetValue(key, out var route)) return Reply(route.Item1, route.Item2);
        if (uri.Host == "management.azure.com") return Reply(404, Encoding.UTF8.GetBytes("{}"));
        var path = uri.AbsolutePath;
        if (request.Method == HttpMethod.Head && uri.Query == "?restype=container") return Reply(200, Array.Empty<byte>());
        if (uri.Query == "?comp=lease")
        {
            var action = headers["x-ms-lease-action"];
            if (action == "acquire")
            {
                if (LeaseId != null) return Reply(409, Array.Empty<byte>());
                LeaseId = headers["x-ms-proposed-lease-id"];
                var acquired = Reply(201, Array.Empty<byte>());
                acquired.Headers.TryAddWithoutValidation("x-ms-lease-id", LeaseId);
                return acquired;
            }
            if (LeaseId == null || headers["x-ms-lease-id"] != LeaseId) return Reply(412, Array.Empty<byte>());
            if (action == "release") LeaseId = null;
            return Reply(200, Array.Empty<byte>());
        }
        if (request.Method == HttpMethod.Put)
        {
            if (WriteFailure != 0) return Reply(WriteFailure, Array.Empty<byte>());
            if (headers.ContainsKey("If-None-Match") && Blobs.ContainsKey(path)) return Reply(412, Array.Empty<byte>());
            if (headers.TryGetValue("If-Match", out var expected) && (!Etags.TryGetValue(path, out var actual) || expected != actual)) return Reply(412, Array.Empty<byte>());
            Blobs[path] = await request.Content!.ReadAsByteArrayAsync(cancellationToken);
            Etags[path] = "\"revision-" + ++revision + "\"";
            var created = Reply(201, Array.Empty<byte>());
            created.Headers.TryAddWithoutValidation("ETag", Etags[path]);
            return created;
        }
        if (!Blobs.TryGetValue(path, out var bytes)) return Reply(404, Array.Empty<byte>());
        var found = Reply(200, bytes);
        found.Headers.TryAddWithoutValidation("ETag", Etags[path]);
        return found;
    }

    private static HttpResponseMessage Reply(int status, byte[] bytes) => new((HttpStatusCode)status) { Content = new ByteArrayContent(bytes) };
}
