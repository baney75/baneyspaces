# Watches for a window that was not there at the start and becomes SEEN (visible, uncloaked, opaque,
# on screen). Polls fast for $Seconds. Prints every new window once with how long it took to hide.
param([int]$Seconds = 14, [switch]$All)
. { $src = Get-Content C:\readback.ps1 -Raw; Invoke-Expression ($src.Substring(0, $src.IndexOf('[RB]::Run()')).Replace('param([switch]$All)', '').Replace('# This script runs elevated', '#')) }
[RB]::All = [bool]$All; [RB]::Run(); $base = @{}; [RB]::Rows | % { $base[($_ -split ' ')[0]] = 1 }
$new = @{}; $sw = [Diagnostics.Stopwatch]::StartNew(); $polls = 0
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
  [RB]::Run(); $polls++
  foreach ($r in [RB]::Rows) {
    $id = ($r -split ' ')[0]
    if ($base.ContainsKey($id)) { continue }
    $seen = $r -match 'SEEN=True'
    if (-not $new.ContainsKey($id)) { $new[$id] = @{ first = $sw.ElapsedMilliseconds; seen_ms = @(); row = $r } }
    if ($seen) { $new[$id].seen_ms += $sw.ElapsedMilliseconds }
    $new[$id].last = $r
  }
}
"polls=$polls over $Seconds s"
foreach ($k in $new.Keys) { $sm = $new[$k].seen_ms; $span = if ($sm.Count -gt 0) { $sm[-1] - $sm[0] } else { 0 }; "NEW $k first_seen_at=$($new[$k].first)ms visible_polls=$($sm.Count) exposed_ms=$span :: $($new[$k].last)" }
if ($new.Count -eq 0) { 'NEW none' }
