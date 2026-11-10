using System.Security.Cryptography;
using System.Text.Json;
using YamlDotNet.Core;
using YamlDotNet.Core.Events;
using YamlDotNet.Serialization;

if (args.Length != 1)
{
    Console.Error.WriteLine("Expected one YAML definition path.");
    return 1;
}

try
{
    if (new FileInfo(args[0]).Length is 0 or > 65536)
    {
        throw new InvalidDataException();
    }
    var bytes = await File.ReadAllBytesAsync(args[0]);
    if (bytes.Length is 0 or > 65536)
    {
        throw new InvalidDataException();
    }

    var text = new System.Text.UTF8Encoding(false, true).GetString(bytes);
    var parser = new Parser(new StringReader(text));
    var documents = 0;
    var depth = 0;
    while (parser.MoveNext())
    {
        if (parser.Current is DocumentStart && ++documents > 1)
        {
            throw new InvalidDataException();
        }
        if (parser.Current is AnchorAlias ||
            parser.Current is NodeEvent node && (!node.Anchor.IsEmpty || !node.Tag.IsEmpty))
        {
            throw new InvalidDataException();
        }
        if (parser.Current is SequenceStart or MappingStart && ++depth > 16)
        {
            throw new InvalidDataException();
        }
        if (parser.Current is SequenceEnd or MappingEnd)
        {
            depth--;
        }
    }

    var yaml = new DeserializerBuilder()
        .WithAttemptingUnquotedStringTypeDeserialization()
        .WithDuplicateKeyChecking()
        .Build()
        .Deserialize<object>(text);
    var json = new SerializerBuilder().JsonCompatible().Build().Serialize(yaml);
    using var definition = JsonDocument.Parse(json);
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
        definition = definition.RootElement
    }));
    return 0;
}
catch (Exception)
{
    // Parser diagnostics can contain values from a rejected secret-bearing definition.
    Console.Error.WriteLine("The definition must be one restricted UTF-8 YAML document without duplicate keys, tags or anchors.");
    return 1;
}
