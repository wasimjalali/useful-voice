# End to end test of install.ps1, run by the release-windows workflow on a clean
# windows-latest runner. It runs the one-liner exactly as a user would
# (`irm <url>/install.ps1 | iex`) against a local copy of the release, served as GitHub
# serves assets (e2e/installer/serve.mjs):
#
#   1. A tampered installer is refused by Windows PowerShell 5.1 (what Windows ships), and
#      nothing is installed.
#   2. The real installer installs per-user under Windows PowerShell 5.1: one uninstall
#      entry, the release's version, the exe on disk.
#   3. The same one-liner works again from PowerShell 7 (a reinstall over the first).
#
# Usage: pwsh e2e/installer/install-script.ps1 <publish-local dir> <out dir>
# <publish-local dir> is release.mjs output made with --base-url http://127.0.0.1:8719.
param(
  [Parameter(Mandatory)] [string]$Publish,
  [Parameter(Mandatory)] [string]$Out
)
$ErrorActionPreference = 'Stop'
$Port = 8719
$Base = "http://127.0.0.1:$Port"
$Publish = (Resolve-Path $Publish).Path
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$report = Join-Path $Out 'install-script-report.txt'
$serveLog = Join-Path $Out 'install-script-requests.log'
$serve = Join-Path $PSScriptRoot 'serve.mjs'
$version = (Get-Content (Join-Path $PSScriptRoot '..\..\package.json') -Raw | ConvertFrom-Json).version

function Say([string]$line) { $line | Tee-Object -FilePath $report -Append }

function Get-UvEntries {
  $roots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )
  foreach ($root in $roots) {
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
      $p = Get-ItemProperty $_.PSPath
      if ($p.DisplayName -like 'Useful Voice*') {
        [pscustomobject]@{ Root = $root; Key = $_.PSChildName; DisplayVersion = $p.DisplayVersion; InstallLocation = $p.InstallLocation; InstallDir = $(if ($p.UninstallString -match '^"([^"]+)"') { Split-Path -Parent $Matches[1] } else { $p.InstallLocation }) }
      }
    }
  }
}

function Start-Server([string]$dir) {
  $proc = Start-Process -FilePath 'node' -ArgumentList @($serve, $dir, $Port, $serveLog) -PassThru -NoNewWindow
  for ($i = 0; $i -lt 50; $i++) {
    # A server that died (port still held by the last one) must not pass for this one.
    if ($proc.HasExited) { throw "the release server exited with $($proc.ExitCode)" }
    try { Invoke-WebRequest -Uri "$Base/install.ps1" -Method Head -UseBasicParsing | Out-Null; return $proc } catch { Start-Sleep -Milliseconds 200 }
  }
  throw "the release server did not start on $Base"
}

# Runs the one-liner in a fresh shell and returns its exit code and output.
function Invoke-OneLiner([string]$shell) {
  $outFile = Join-Path $Out "oneliner-$shell-$([Guid]::NewGuid().ToString('N')).txt"
  # A child Windows PowerShell inherits PowerShell 7's PSModulePath and then cannot load its
  # own modules. A user's console starts with Windows PowerShell's default, so test with that.
  $savedModulePath = $env:PSModulePath
  if ($shell -eq 'powershell.exe') {
    $env:PSModulePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\system32\WindowsPowerShell\v1.0\Modules"
  }
  try {
    $proc = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "irm $Base/install.ps1 | iex") `
      -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err" -PassThru -NoNewWindow
  } finally {
    $env:PSModulePath = $savedModulePath
  }
  if (-not $proc.WaitForExit(600000)) { Stop-Process -Id $proc.Id -Force; throw "$shell one-liner did not finish within 10 minutes" }
  $text = (Get-Content $outFile -Raw) + (Get-Content "$outFile.err" -Raw)
  [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $text }
}

function Stop-App { Get-Process -Name 'Useful Voice' -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2 }

Say "install.ps1 end to end, Useful Voice $version, $(Get-Date -Format o)"
Say "Windows PowerShell: $((powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))  PowerShell 7: $($PSVersionTable.PSVersion)"
if (@(Get-UvEntries).Count -ne 0) { throw 'the runner already has a Useful Voice uninstall entry' }

# 1. Tampered installer: one byte appended, same install.ps1 (and so the same expected hash).
$tampered = Join-Path $env:RUNNER_TEMP 'publish-tampered'
Copy-Item $Publish $tampered -Recurse -Force
$installerName = (Get-ChildItem $tampered -Filter 'Useful-Voice-*-x64.exe').Name
[IO.File]::AppendAllText((Join-Path $tampered $installerName), 'x')
$server = Start-Server $tampered
try {
  $r = Invoke-OneLiner 'powershell.exe'
} finally { Stop-Process -Id $server.Id -Force; $server.WaitForExit() }
Say "== 1. tampered installer, Windows PowerShell 5.1: exit $($r.ExitCode)"
Say $r.Output
if ($r.ExitCode -eq 0) { throw 'install.ps1 exited 0 on a tampered installer' }
if ($r.Output -notmatch 'does not match this release') { throw 'install.ps1 did not report the hash mismatch' }
if (@(Get-UvEntries).Count -ne 0) { throw 'a tampered installer left an uninstall entry' }
Say 'OK: refused, nothing installed'

# 2. The real installer, Windows PowerShell 5.1.
$server = Start-Server $Publish
try {
  $r = Invoke-OneLiner 'powershell.exe'
  Say "== 2. real installer, Windows PowerShell 5.1: exit $($r.ExitCode)"
  Say $r.Output
  if ($r.ExitCode -ne 0) { throw "install.ps1 failed under Windows PowerShell 5.1 (exit $($r.ExitCode))" }
  $entries = @(Get-UvEntries)
  Say ($entries | Format-List | Out-String)
  if ($entries.Count -ne 1 -or $entries[0].Root -notlike 'HKCU:*') { throw "expected one per-user uninstall entry, found $($entries.Count)" }
  if ($entries[0].DisplayVersion -ne $version) { throw "expected version $version, found $($entries[0].DisplayVersion)" }
  $exe = Join-Path $entries[0].InstallDir 'Useful Voice.exe'
  if (-not (Test-Path -LiteralPath $exe)) { throw "installed exe missing at $exe" }
  Start-Sleep -Seconds 3
  $running = @(Get-Process -Name 'Useful Voice' -ErrorAction SilentlyContinue)
  Say "app processes after install: $($running.Count)"
  if ($running.Count -eq 0) { throw 'install.ps1 did not start the app' }
  Stop-App
  Say 'OK: installed and started'

  # 3. Again from PowerShell 7, over the first install.
  $r = Invoke-OneLiner 'pwsh'
  Say "== 3. real installer again, PowerShell 7: exit $($r.ExitCode)"
  Say $r.Output
  if ($r.ExitCode -ne 0) { throw "install.ps1 failed under PowerShell 7 (exit $($r.ExitCode))" }
  $entries = @(Get-UvEntries)
  if ($entries.Count -ne 1 -or $entries[0].DisplayVersion -ne $version) { throw "expected one $version entry after the reinstall, found $($entries.Count)" }
  Stop-App
  Say 'OK: reinstalled'

  # Informational, for the SmartScreen notes in docs/distribution.md: does a file fetched
  # the way install.ps1 fetches it carry the mark of the web?
  $probe = Join-Path $env:RUNNER_TEMP 'motw-probe.exe'
  Invoke-WebRequest -Uri "$Base/$installerName" -OutFile $probe -UseBasicParsing
  $zone = Get-Item -LiteralPath $probe -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
  Say "Invoke-WebRequest download has a Zone.Identifier stream: $([bool]$zone)"
} finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Stop-App
}
Say 'PASS'
