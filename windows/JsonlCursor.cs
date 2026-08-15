// Incremental reader for append-only JSONL transcripts. Session files grow
// while an agent is working; re-reading the whole file on every mtime change
// is the expensive path. The cursor keeps the byte offset and any incomplete
// trailing line so each refresh only parses new bytes. Port of JSONLTail.swift.

using System.IO;

namespace AgentCord;

internal sealed class JsonlCursor
{
    public long Offset;
    public string Leftover = "";

    public void Reset()
    {
        Offset = 0;
        Leftover = "";
    }

    /// <summary>Newly completed lines since the last pull. <c>DidReset</c> is
    /// true when the file shrank (rotated / rewritten) and the caller must drop
    /// any aggregate built from earlier bytes.</summary>
    public (List<string> Lines, bool DidReset) PullLines(string path)
    {
        using var stream = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var size = stream.Length;
        var didReset = false;
        if (size < Offset)
        {
            Reset();
            didReset = true;
        }

        stream.Seek(Offset, SeekOrigin.Begin);
        using var reader = new StreamReader(stream);
        var text = Leftover + reader.ReadToEnd();
        Offset = size;

        var lines = new List<string>();
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '\n') continue;
            var line = text[start..i].TrimEnd('\r');
            if (line.Length > 0) lines.Add(line);
            start = i + 1;
        }
        Leftover = text[start..];
        return (lines, didReset);
    }
}
