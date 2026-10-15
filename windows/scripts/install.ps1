# Installs Useful Voice on Windows:
#   irm https://github.com/wasimjalali/useful-voice-releases/releases/latest/download/install.ps1 | iex
#
# The installer is not Authenticode-signed yet. What this script trusts instead is the
# release it was published with: scripts/release.mjs writes that release's installer
# URL and SHA-256 below, and a download that does not match is refused before it runs.
# Updates then arrive in the app (electron-updater, checked against latest.yml).
#
# Keep this file ASCII: Windows PowerShell 5.1 may decode a downloaded script as
# Latin-1. Everything runs inside one script block, so a failure stops here with an
# error and never closes the window that ran `iex`.

& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'

  $Version = '@@VERSION@@'
  $Url = '@@INSTALLER_URL@@'
  $Sha256 = '@@INSTALLER_SHA256@@'

  function Fail([string]$message) {
    throw "Useful Voice install failed: $message"
  }

  if (($Version + $Url + $Sha256).Contains('@@')) {
    Fail "this is the unreleased template; install from a release's install.ps1."
  }
  if ($env:OS -ne 'Windows_NT') { Fail 'Useful Voice for Windows runs on Windows only.' }
  if (-not [Environment]::Is64BitOperatingSystem) { Fail 'Useful Voice needs 64-bit Windows.' }
  # HTTPS only; plain HTTP just for a local test server.
  if (-not ($Url.StartsWith('https://') -or $Url.StartsWith('http://127.0.0.1:'))) {
    Fail "refusing a download that is not HTTPS: $Url"
  }
  if ($Sha256 -notmatch '^[0-9a-f]{64}$') { Fail 'this script carries no valid SHA-256.' }

  # Windows PowerShell 5.1 on older Windows may not offer TLS 1.2 by default.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $work = Join-Path ([IO.Path]::GetTempPath()) ('useful-voice-install-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $installer = Join-Path $work "Useful-Voice-$Version-setup.exe"
    Write-Host "Downloading Useful Voice $Version..."
    try {
      Invoke-WebRequest -Uri $Url -OutFile $installer -UseBasicParsing
    } catch {
      Fail "the download did not complete ($($_.Exception.Message))."
    }

    # .NET rather than Get-FileHash: a Windows PowerShell started from PowerShell 7 inherits a
    # module path where Get-FileHash cannot load.
    $stream = [IO.File]::OpenRead($installer)
    try {
      $sha = [Security.Cryptography.SHA256]::Create()
      $got = (-join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }))
    } finally { $stream.Dispose() }
    if ($got -ne $Sha256) {
      Remove-Item -LiteralPath $installer -Force
      Fail "the download does not match this release (sha256 $got, expected $Sha256). Nothing was installed."
    }

    Write-Host 'Installing...'
    # Per-user install, no administrator prompt. A running copy is closed by the installer.
    $proc = Start-Process -FilePath $installer -ArgumentList '/S' -PassThru
    if (-not $proc.WaitForExit(300000)) {
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      Fail 'the installer did not finish within 5 minutes.'
    }
    if ($proc.ExitCode -ne 0) { Fail "the installer exited with code $($proc.ExitCode)." }

    $exe = Join-Path $env:LOCALAPPDATA 'Programs\Useful Voice\Useful Voice.exe'
    $entry = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
      ForEach-Object { Get-ItemProperty $_.PSPath } |
      Where-Object { $_.DisplayName -like 'Useful Voice*' } |
      Select-Object -First 1
    if ($entry -and $entry.InstallLocation) { $exe = Join-Path $entry.InstallLocation 'Useful Voice.exe' }
    if (-not (Test-Path -LiteralPath $exe)) { Fail "the installer finished but $exe is missing." }

    Write-Host "Installed Useful Voice $Version. Starting it..."
    Start-Process -FilePath $exe
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}
