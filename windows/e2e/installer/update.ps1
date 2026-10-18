# End to end test of in-app updates, run by the release-windows workflow on a clean
# windows-latest runner, until there is a Windows machine for a live check.
#
# An older build (same code, version 0.0.9, its feed pointed at 127.0.0.1) is installed
# and started. Its electron-updater reads the release's real latest.yml from a local copy
# of the release (e2e/installer/serve.mjs), downloads the installer, checks its SHA-512 and,
# with UV_UPDATE_INSTALL_WHEN_READY=1, takes the tray's "Restart to update" path. The test
# passes when the uninstall entry shows the new version under the same key, the new exe
# is on disk, and the app started again.
#
# Usage: pwsh e2e/installer/update.ps1 <publish dir> <old build dir> <out dir>
param(
  [Parameter(Mandatory)] [string]$Publish,
  [Parameter(Mandatory)] [string]$Old,
  [Parameter(Mandatory)] [string]$Out
)
$ErrorActionPreference = 'Stop'
$Port = 8720
$Base = "http://127.0.0.1:$Port"
$Publish = (Resolve-Path $Publish).Path
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$report = Join-Path $Out 'update-report.txt'
$serveLog = Join-Path $Out 'update-requests.log'
$version = (Get-Content (Join-Path $PSScriptRoot '..\..\package.json') -Raw | ConvertFrom-Json).version
$diagnostics = Join-Path $env:APPDATA 'Useful Voice\diagnostics.log'

function Say([string]$line) { $line | Tee-Object -FilePath $report -Append }

function Get-UvEntry {
  $all = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    ForEach-Object { $p = Get-ItemProperty $_.PSPath; if ($p.DisplayName -like 'Useful Voice*') { [pscustomobject]@{ Key = $_.PSChildName; DisplayVersion = $p.DisplayVersion; InstallLocation = $p.InstallLocation; InstallDir = $(if ($p.UninstallString -match '^"([^"]+)"') { Split-Path -Parent $Matches[1] } else { Join-Path $env:LOCALAPPDATA 'Programs\Useful Voice' }) } } })
  if ($all.Count -gt 1) { throw "found $($all.Count) Useful Voice uninstall entries" }
  return $all | Select-Object -First 1
}

Say "electron-updater end to end, 0.0.9 -> $version, $(Get-Date -Format o)"
$server = Start-Process -FilePath 'node' -ArgumentList @((Join-Path $PSScriptRoot 'serve.mjs'), $Publish, $Port, $serveLog) -PassThru -NoNewWindow
try {
  # Not $old: PowerShell names are case-insensitive, and that is the [string] parameter $Old.
  $oldInstaller = Get-ChildItem $Old -Filter '*-x64.exe' | Select-Object -First 1
  if (-not $oldInstaller) { throw "no old installer in $Old" }
  # The 0.0.9 installer itself sometimes dies on the runner with an access violation
  # (0xC0000005, exit -1073741819) before this build is involved. Only that exit is retried,
  # at most twice; any other failure stops the run at once.
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $proc = Start-Process -FilePath $oldInstaller.FullName -ArgumentList '/S' -PassThru
    if (-not $proc.WaitForExit(300000)) { throw "old installer did not finish in 5 minutes" }
    if ($proc.ExitCode -eq 0) { break }
    if ($proc.ExitCode -ne -1073741819 -or $attempt -eq 3) { throw "old installer failed (exit $($proc.ExitCode))" }
    Say "old installer crashed with an access violation (attempt $attempt); retrying"
    Start-Sleep -Seconds 5
  }
  $before = Get-UvEntry
  Say "installed: $($before.Key) $($before.DisplayVersion) at $($before.InstallDir)"
  if ($before.DisplayVersion -ne '0.0.9') { throw "expected 0.0.9 installed, found $($before.DisplayVersion)" }
  $exe = Join-Path $before.InstallDir 'Useful Voice.exe'
  Say "app-update.yml of the old build:"
  Say (Get-Content (Join-Path $before.InstallDir 'resources\app-update.yml') -Raw)

  # Only this run's line may satisfy the assertion below.
  Remove-Item (Join-Path $env:APPDATA 'Useful Voice\update.log') -ErrorAction SilentlyContinue
  $env:UV_UPDATE_INSTALL_WHEN_READY = '1'
  Start-Process -FilePath $exe | Out-Null
  Remove-Item Env:\UV_UPDATE_INSTALL_WHEN_READY

  # The first check runs a minute after launch; then download, verify, quit, install.
  $deadline = (Get-Date).AddMinutes(8)
  $after = $before
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $after = Get-UvEntry
    if ($after -and $after.DisplayVersion -eq $version) { break }
  }
  Say "after: $($after.Key) $($after.DisplayVersion)"
  if (-not $after -or $after.DisplayVersion -ne $version) { throw "the app did not update to $version within 8 minutes" }
  if ($after.Key -ne $before.Key) { throw "the update used a different uninstall key: $($before.Key) -> $($after.Key)" }
  $fileVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
  Say "exe product version: $fileVersion"
  if (-not $fileVersion.StartsWith($version)) { throw "the exe on disk is $fileVersion, expected $version" }

  # "Restart to update" relaunches the app (--force-run).
  $running = $null
  for ($i = 0; $i -lt 30 -and -not $running; $i++) {
    Start-Sleep -Seconds 2
    $running = Get-Process -Name 'Useful Voice' -ErrorAction SilentlyContinue
  }
  Say "running after the update: $([bool]$running)"
  if (-not $running) { throw 'the app did not start again after the update' }

  $updateLog = Join-Path $env:APPDATA 'Useful Voice\update.log'
  $installLine = if (Test-Path $updateLog) { Get-Content $updateLog -Raw } else { '' }
  Say "update.log: $installLine"
  if ($installLine -notmatch "installer for $([regex]::Escape($version)) started, restart requested") { throw 'update.log does not record the installer starting' }

  $requests = Get-Content $serveLog -Raw
  if ($requests -notmatch 'GET /latest\.yml 200') { throw 'the updater never fetched latest.yml' }
  if ($requests -notmatch "GET /Useful-Voice-$([regex]::Escape($version))-x64\.exe 200") { throw 'the updater never fetched the installer' }
  Say 'PASS'
} finally {
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  Get-Process -Name 'Useful Voice' -ErrorAction SilentlyContinue | Stop-Process -Force
  if (Test-Path $diagnostics) { Copy-Item $diagnostics (Join-Path $Out 'diagnostics.log') }
  $updateLog = Join-Path $env:APPDATA 'Useful Voice\update.log'
  if (Test-Path $updateLog) { Copy-Item $updateLog (Join-Path $Out 'update.log') }
}
