#nullable enable
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Hexagon.DeliveryTests;

public sealed class DeliveryHttpHandler : HttpMessageHandler
{
    public Dictionary<string, Tuple<int, byte[]>> Routes { get; } = new();
    public Dictionary<string, Dictionary<string, string>> ResponseHeaders { get; } = new();
    public List<string> Requests { get; } = new();
    public List<Dictionary<string, string>> Headers { get; } = new();
    public Dictionary<string, byte[]> RegistryBlobs { get; } = new();
    public Dictionary<string, byte[]> RegistryManifests { get; } = new();
    public List<byte[]> UploadedBodies { get; } = new();
    public bool CorruptDigest { get; set; }
    public string? UploadLocation { get; set; }

    public void Route(string method, string uri, int status, byte[] bytes) =>
        Routes[method + " " + new Uri(uri).AbsoluteUri] = Tuple.Create(status, bytes);

    public void Header(string method, string uri, string name, string value)
    {
        var key = method + " " + new Uri(uri).AbsoluteUri;
        if (!ResponseHeaders.ContainsKey(key)) ResponseHeaders[key] = new(StringComparer.OrdinalIgnoreCase);
        ResponseHeaders[key][name] = value;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var uri = request.RequestUri!;
        var key = request.Method + " " + uri.AbsoluteUri;
        Requests.Add(key);
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var header in request.Headers) headers[header.Key] = string.Join(",", header.Value);
        Headers.Add(headers);
        if (Routes.TryGetValue(key, out var route))
        {
            var reply = Reply(route.Item1, route.Item2);
            if (ResponseHeaders.TryGetValue(key, out var responseHeaders))
                foreach (var header in responseHeaders)
                {
                    if (header.Key.StartsWith("Content-", StringComparison.OrdinalIgnoreCase)) reply.Content.Headers.TryAddWithoutValidation(header.Key, header.Value);
                    else reply.Headers.TryAddWithoutValidation(header.Key, header.Value);
                }
            return reply;
        }
        if (!uri.Host.EndsWith(".azurecr.io", StringComparison.Ordinal)) return Reply(404, Array.Empty<byte>());
        var path = uri.AbsolutePath;
        if (path == "/oauth2/token") return Reply(200, Encoding.UTF8.GetBytes("{\"access_token\":\"fixture-access\"}"));
        if (request.Method == HttpMethod.Head)
        {
            var registry = path.Contains("/manifests/") ? RegistryManifests : RegistryBlobs;
            if (!registry.ContainsKey(path)) return Reply(404, Array.Empty<byte>());
            var result = Reply(200, Array.Empty<byte>());
            result.Headers.TryAddWithoutValidation("Docker-Content-Digest", CorruptDigest ? "sha256:wrong" : path[(path.LastIndexOf('/') + 1)..]);
            return result;
        }
        if (request.Method == HttpMethod.Post && path.EndsWith("/blobs/uploads/", StringComparison.Ordinal))
        {
            var result = Reply(202, Array.Empty<byte>());
            result.Headers.TryAddWithoutValidation("Location", UploadLocation ?? path + "fixture-upload?_state=fixed");
            return result;
        }
        if (request.Method == HttpMethod.Put)
        {
            var body = await request.Content!.ReadAsByteArrayAsync(cancellationToken);
            UploadedBodies.Add(body);
            var manifest = path.Contains("/manifests/", StringComparison.Ordinal);
            var digest = manifest ? path[(path.LastIndexOf('/') + 1)..] : Uri.UnescapeDataString(uri.Query.Split("digest=", StringSplitOptions.None)[1]);
            if (manifest) RegistryManifests[path] = body;
            else RegistryBlobs[path[..path.IndexOf("/blobs/uploads/", StringComparison.Ordinal)] + "/blobs/" + digest] = body;
            var result = Reply(201, Array.Empty<byte>());
            result.Headers.TryAddWithoutValidation("Docker-Content-Digest", CorruptDigest ? "sha256:wrong" : digest);
            return result;
        }
        return Reply(404, Array.Empty<byte>());
    }

    private static HttpResponseMessage Reply(int status, byte[] bytes) => new((HttpStatusCode)status) { Content = new ByteArrayContent(bytes) };
}
