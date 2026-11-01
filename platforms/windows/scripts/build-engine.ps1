# Fetch agent-desktop at the pinned commit and build its CLI (Windows adapter, UI Automation) with --locked.
# The pin is the same file the Linux build reads (platforms/linux/engine.pin): one commit on every platform.
# Output: platforms/windows/engine/agent-desktop.exe
# Usage: build-engine.ps1 [-Profile release]
param([string]$Profile = 'release', [switch]$Install)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot            # platforms/windows
$pinFile = Join-Path (Split-Path -Parent $here) 'linux\engine.pin'
$pin = @{}
Get-Content $pinFile | Where-Object { $_ -match '^\s*(\w+)=(.+)$' } | ForEach-Object { $pin[$Matches[1]] = $Matches[2].Trim() }
$repo = $pin['repo']; $commit = $pin['commit']
if (-not $repo -or -not $commit) { throw "engine.pin has no repo/commit" }
$src = Join-Path $here 'third_party\agent-desktop'
$out = Join-Path $here 'engine'
# An application path, not the name: PowerShell command names are case-insensitive, so a function called
# Git would shadow git.exe and call itself forever.
$cmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$git = if ($cmd) { $cmd.Source } else { 'C:\mingit\cmd\git.exe' }
function Invoke-Git { & $git @args; if ($LASTEXITCODE -ne 0) { throw "git $args failed" } }
if (-not (Test-Path (Join-Path $src '.git'))) {
  New-Item -ItemType Directory -Force (Split-Path $src) | Out-Null
  Invoke-Git clone -q $repo $src
}
if ((& $git -C $src rev-parse HEAD) -ne $commit) {
  Invoke-Git -C $src fetch -q origin
  Invoke-Git -C $src checkout -q --detach $commit
}
if ((& $git -C $src rev-parse HEAD) -ne $commit) { throw "engine: HEAD is not the pinned $commit" }
if (& $git -C $src status --porcelain) { throw 'engine: pinned checkout is dirty' }
$env:Path = "$env:USERPROFILE\.cargo\bin;" + $env:Path
Push-Location $src
try {
  cargo build --locked --profile $Profile -p agent-desktop
  if ($LASTEXITCODE -ne 0) { throw 'engine build failed' }
} finally { Pop-Location }
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item -Force (Join-Path $src "target\$Profile\agent-desktop.exe") (Join-Path $out 'agent-desktop.exe')
Set-Content -NoNewline -Path (Join-Path $out 'COMMIT') -Value $commit
Copy-Item -Force (Join-Path $src 'LICENSE') (Join-Path $out 'LICENSE')
if (Test-Path (Join-Path $src 'NOTICE')) { Copy-Item -Force (Join-Path $src 'NOTICE') (Join-Path $out 'NOTICE') }
Write-Output "engine built: $out\agent-desktop.exe ($commit)"
if ($Install) {
  # Where a release build looks for it (and only there).
  $dest = Join-Path $env:LOCALAPPDATA 'BaneySpaces\engine'
  New-Item -ItemType Directory -Force $dest | Out-Null
  Copy-Item -Force (Join-Path $out '*') $dest
  Write-Output "engine installed: $dest"
}
