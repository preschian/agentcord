// Read-only helpers for local SQLite files the host apps already keep open.
// Microsoft.Data.Sqlite is already a project dependency (T3). Spawning the
// sqlite3 CLI is slower and fails when sqlite3 is not on PATH.

using System.IO;
using Microsoft.Data.Sqlite;

namespace AgentCord;

internal static class LocalSqlite
{
    public static string? QueryText(string dbPath, string sql)
    {
        if (!File.Exists(dbPath)) return null;
        try
        {
            using var conn = OpenReadOnly(dbPath);
            using var cmd = conn.CreateCommand();
            cmd.CommandText = sql;
            var value = cmd.ExecuteScalar();
            return value is null or DBNull ? null : Convert.ToString(value);
        }
        catch
        {
            return null;
        }
    }

    public static byte[]? QueryBytes(string dbPath, string sql)
    {
        if (!File.Exists(dbPath)) return null;
        try
        {
            using var conn = OpenReadOnly(dbPath);
            using var cmd = conn.CreateCommand();
            cmd.CommandText = sql;
            using var reader = cmd.ExecuteReader();
            if (!reader.Read() || reader.IsDBNull(0)) return null;
            if (reader.GetFieldType(0) == typeof(byte[]))
                return (byte[])reader.GetValue(0);
            var text = reader.GetValue(0)?.ToString();
            if (string.IsNullOrEmpty(text)) return null;
            try { return Convert.FromHexString(text.Trim()); }
            catch { return System.Text.Encoding.UTF8.GetBytes(text); }
        }
        catch
        {
            return null;
        }
    }

    public static DateTime? DbStamp(string dbPath)
    {
        DateTime? best = null;
        foreach (var path in new[] { dbPath, dbPath + "-wal" })
        {
            try
            {
                if (!File.Exists(path)) continue;
                var mtime = File.GetLastWriteTimeUtc(path);
                if (best is null || mtime > best) best = mtime;
            }
            catch { }
        }
        return best;
    }

    public static SqliteConnection OpenReadOnly(string dbPath)
    {
        var cs = new SqliteConnectionStringBuilder
        {
            DataSource = dbPath,
            Mode = SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Shared,
        }.ToString();
        var conn = new SqliteConnection(cs);
        conn.Open();
        return conn;
    }
}
