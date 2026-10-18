/**
 * The PowerShell behind "Pause media while dictating".
 *
 * Windows lists every app that is playing media (Spotify, a YouTube tab in Edge or Chrome,
 * a podcast app) as a session of the Global System Media Transport Controls. The scripts
 * below ask that list which sessions are Playing, pause those, and later play the same ones
 * again if each is still Paused.
 *   https://learn.microsoft.com/uwp/api/windows.media.control.globalsystemmediatransportcontrolssessionmanager
 *
 * They run in Windows PowerShell 5.1, which can load the WinRT type by name but cannot
 * `await` an `IAsyncOperation`; the documented reflection route is `AsTask` from
 * `System.WindowsRuntimeSystemExtensions`, called once per result type.
 *
 * Nothing here imports Electron, so the builders and the parser are tested on any platform.
 * Ids reach a script only as base64, never as text: a session id is chosen by whatever app
 * is playing, so it is untrusted.
 */

/** Long enough for any real list; a script is never built from more than this. */
const MAX_IDS = 64;
const MAX_ID_LENGTH = 512;

/**
 * Defines `Invoke-UvAwait` and `Get-UvMediaSessions`. The media host runs it once at start;
 * a one-shot process runs it in front of the body. No backtick may appear (these are
 * template literals), so the generic name `IAsyncOperation`1` is built from [char]96.
 */
export const MEDIA_PRELUDE = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
$uvAsyncName = 'IAsyncOperation' + [char]96 + '1'
$uvAsTask = @([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq $uvAsyncName })[0]
function Invoke-UvAwait($operation, [Type]$resultType) {
  $task = $uvAsTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
  if (-not $task.Wait(3000)) { throw 'a media request timed out' }
  return $task.Result
}
function Get-UvMediaSessions {
  $managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
  $manager = Invoke-UvAwait ($managerType::RequestAsync()) $managerType
  return @($manager.GetSessions())
}
function ConvertTo-UvId([string]$text) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($text)) }
`;

const OWN_ID = /^[A-Za-z0-9._-]{1,128}$/;

/**
 * Pause every session that is Playing and print `UVPAUSED:<base64 id>` for each one that
 * accepted. The app's own sessions are skipped (`ownAppId`), and a session that throws is
 * skipped without stopping the rest.
 */
export function pausePlayingScript(ownAppId = 'ai.useful.voice'): string {
  if (!OWN_ID.test(ownAppId)) throw new Error('the app id has characters a script may not carry');
  return `
$uvOwn = '${ownAppId}'
foreach ($s in @(Get-UvMediaSessions)) {
  try {
    $id = [string]$s.SourceAppUserModelId
    if ($id -eq $uvOwn) { continue }
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Playing') { continue }
    if (Invoke-UvAwait ($s.TryPauseAsync()) ([bool])) {
      Write-Output ('UVPAUSED:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($id)))
    }
  } catch { Write-Output 'UVSKIP:session' }
}
`;
}

/** The ids as `base64,base64,...`: the only form in which they enter a script. */
export function encodeSessionIds(ids: string[]): string {
  if (ids.length === 0 || ids.length > MAX_IDS) throw new Error('a resume needs between 1 and 64 session ids');
  return ids
    .map((id) => {
      if (id.length === 0 || id.length > MAX_ID_LENGTH) throw new Error('a session id is empty or too long');
      return Buffer.from(id, 'utf8').toString('base64');
    })
    .join(',');
}

/**
 * Play each listed session that is still Paused and print `UVRESUMED:<n>`. A session the
 * person already played, stopped or closed is left alone.
 */
export function resumeScript(ids: string[]): string {
  const encoded = encodeSessionIds(ids);
  // base64 and commas only: nothing in `encoded` can end the quote it sits in.
  if (!/^[A-Za-z0-9+/=,]+$/.test(encoded)) throw new Error('the encoded ids have unexpected characters');
  return `
$uvWanted = @('${encoded}'.Split(',') | ForEach-Object { ConvertTo-UvId $_ })
$uvResumed = 0
foreach ($s in @(Get-UvMediaSessions)) {
  try {
    $id = [string]$s.SourceAppUserModelId
    if ($uvWanted -notcontains $id) { continue }
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Paused') { continue }
    if (Invoke-UvAwait ($s.TryPlayAsync()) ([bool])) { $uvResumed++ }
  } catch { Write-Output 'UVSKIP:session' }
}
Write-Output ('UVRESUMED:' + $uvResumed)
`;
}

/** The ids `pausePlayingScript` reports, from its output. Anything else in the output is ignored. */
export function parsePausedOutput(stdout: string): string[] {
  const ids = new Set<string>();
  for (const raw of stdout.split(/\r?\n/)) {
    const match = /^UVPAUSED:([A-Za-z0-9+/]+={0,2})$/.exec(raw.trim());
    if (!match) continue;
    const id = Buffer.from(match[1] as string, 'base64').toString('utf8');
    if (id.length > 0 && id.length <= MAX_ID_LENGTH) ids.add(id);
  }
  return [...ids];
}
