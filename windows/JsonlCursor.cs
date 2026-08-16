// Incremental reader for append-only JSONL transcripts. Session files grow
// while an agent is working; re-reading the whole file on every mtime change
// is the expensive path. The cursor keeps the byte offset and any incomplete
// trailing line so each refresh only parses new bytes.
//
// Reads in 8 KB chunks and yields one line at a time. Do not ReadToEnd: a
// 28 MB UTF-8 transcript becomes a ~56 MB UTF-16 string on the large object
// heap, and holding every line in a List doubles that again.

using System.IO;
using System.Text;

namespace AgentCord;

internal sealed class JsonlCursor
{
    private const int BufSize = 8192;

    public long Offset;
    public string Leftover = "";

    public void Reset()
    {
        Offset = 0;
        Leftover = "";
    }

    /// <summary>True when the file has not grown past the last pull. NTFS
    /// mtime can stay put for appends in the same second, so callers must
    /// not treat an unchanged mtime as "nothing new".</summary>
    public bool IsCurrent(string path)
    {
        try { return new FileInfo(path).Length <= Offset; }
        catch { return true; }
    }

    /// <summary>Calls <paramref name="consume"/> for each newly completed
    /// line. <paramref name="onReset"/> runs first when the file shrank
    /// (rotated / rewritten) so the caller can drop stale aggregates before
    /// new lines arrive.</summary>
    public bool PullLines(string path, Action<string> consume, Action? onReset = null)
    {
        using var stream = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var size = stream.Length;
        var didReset = false;
        if (size < Offset)
        {
            Reset();
            didReset = true;
            onReset?.Invoke();
        }

        stream.Seek(Offset, SeekOrigin.Begin);
        var decoder = Encoding.UTF8.GetDecoder();
        var bytes = new byte[BufSize];
        var chars = new char[BufSize];
        var line = Leftover.Length > 0 ? new StringBuilder(Leftover) : new StringBuilder();
        Leftover = "";

        int n;
        while ((n = stream.Read(bytes, 0, bytes.Length)) > 0)
        {
            var written = decoder.GetChars(bytes, 0, n, chars, 0);
            for (var i = 0; i < written; i++)
            {
                var c = chars[i];
                if (c == '\n')
                {
                    if (line.Length > 0 && line[^1] == '\r') line.Length--;
                    if (line.Length > 0) consume(line.ToString());
                    line.Clear();
                }
                else
                {
                    line.Append(c);
                }
            }
        }

        Offset = size;
        Leftover = line.Length > 0 ? line.ToString() : "";
        return didReset;
    }
}
