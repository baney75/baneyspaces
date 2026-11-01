# Installs the build toolchain inside the disposable Windows 11 test VM: Rust (MSVC target),
# the Visual Studio Build Tools (C++ workload + Windows SDK) and MinGit. Re-runnable after `reset`.
# Run from Parish1:  ./exec - < platforms/windows/vm/provision-toolchain.ps1   (about 10-20 minutes)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$tmp = 'C:\bs-tools'
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-File($url, $out) { if (-not (Test-Path $out)) { Invoke-WebRequest -UseBasicParsing $url -OutFile $out } }

# MinGit (build-engine.sh needs git).
if (-not (Test-Path 'C:\mingit\cmd\git.exe')) {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
  $asset = $rel.assets | Where-Object { $_.name -match '^MinGit-.*-64-bit\.zip$' } | Select-Object -First 1
  Get-File $asset.browser_download_url "$tmp\mingit.zip"
  Expand-Archive "$tmp\mingit.zip" 'C:\mingit' -Force
}

# Visual Studio Build Tools: the linker and the Windows SDK that the msvc target needs.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$haveVc = (Test-Path $vswhere) -and (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $haveVc) {
  Get-File 'https://aka.ms/vs/17/release/vs_BuildTools.exe' "$tmp\vs_BuildTools.exe"
  $p = Start-Process "$tmp\vs_BuildTools.exe" -Wait -PassThru -ArgumentList @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621')
  if ($p.ExitCode -notin 0, 3010) { throw "vs_BuildTools exit $($p.ExitCode)" }
}

# Rust.
if (-not (Test-Path "$env:USERPROFILE\.cargo\bin\cargo.exe")) {
  Get-File 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' "$tmp\rustup-init.exe"
  & "$tmp\rustup-init.exe" -y --default-toolchain stable --profile minimal | Out-Host
}
Write-Output ("cargo: " + (& "$env:USERPROFILE\.cargo\bin\cargo.exe" --version))
Write-Output 'toolchain ready'
