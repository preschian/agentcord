# Logs Cursor turn start/end for AgentCord. Always fail-open.
$ErrorActionPreference = "SilentlyContinue"
function Done {
    [Console]::Out.Write("{}")
    exit 0
}
$raw = [Console]::In.ReadToEnd()
$cut = $raw.IndexOf("{")
if ($cut -gt 0) { $raw = $raw.Substring($cut) }
try { $p = $raw | ConvertFrom-Json } catch { Done }
$ev = [string]$p.hook_event_name
if ([string]::IsNullOrWhiteSpace($ev)) { $ev = [string]$p.hookEventName }
$kind = switch ($ev) {
    "beforeSubmitPrompt" { "start" }
    "stop" { "end" }
    default { Done }
}
$id = [string]$p.conversation_id
if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$p.conversationId }
$cwd = ""
if ($null -ne $p.workspace_roots -and $p.workspace_roots.Count -gt 0) {
    $cwd = [string]$p.workspace_roots[0]
}
$ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$dir = Join-Path $env:APPDATA "AgentCord"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$obj = @{ e = $kind; ms = $ms; id = $id; cwd = $cwd }
$line = ($obj | ConvertTo-Json -Compress)
Add-Content -LiteralPath (Join-Path $dir "cursor-turns.jsonl") -Value $line -Encoding utf8
Done
