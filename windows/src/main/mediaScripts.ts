import { TOUCH_TOLERANCE_MS, type HeldSession, type MediaSession } from '../core/media/mediaPausePolicy.js';

/**
 * The PowerShell behind "Pause media while dictating".
 *
 * Windows lists every app that is playing media (Spotify, a YouTube tab in Edge or Chrome,
 * a podcast app) as a session of the Global System Media Transport Controls. The scripts
 * below ask that list which sessions are Playing, pause the ones named, and later play the
 * same ones again.
 *   https://learn.microsoft.com/uwp/api/windows.media.control.globalsystemmediatransportcontrolssessionmanager
 *
 * Pausing is two calls on purpose. `list-playing` only reads, and the caller records what it
 * found before `pause` is sent, so a pause that lands but whose answer is lost can still be
 * undone. `resume` plays a session only if it is still Paused and its timeline has not moved
 * since the pause.
 *
 * They run in Windows PowerShell 5.1, which can load the WinRT type by name but cannot
 * `await` an `IAsyncOperation`; the documented reflection route is `AsTask` from
 * `System.WindowsRuntimeSystemExtensions`, called once per result type.
 *
 * Nothing here imports Electron, so the builders and the parsers are tested on any platform.
 * Ids reach a script only as base64, never as text: a session id is chosen by whatever app
 * is playing, so it is untrusted.
 */

/** Long enough for any real list; a script is never built from more than this. */
const MAX_IDS = 64;
const MAX_ID_LENGTH = 512;

/**
 * Defines the helpers every script uses. The media host runs it once at start; a one-shot
 * process runs it in front of the body. No backtick may appear (these are template
 * literals), so the generic name `IAsyncOperation`1` is built from [char]96.
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
function Get-UvB64([string]$text) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
function Get-UvTimeline($session) {
  try {
    $t = $session.GetTimelineProperties()
    return @([long][math]::Round($t.Position.TotalMilliseconds), [long]$t.LastUpdatedTime.ToUnixTimeMilliseconds())
  } catch { return @([long]0, [long]0) }
}
`;

const OWN_ID = /^[A-Za-z0-9._-]{1,128}$/;

/**
 * Print `UVPLAYING:<base64 id>:<position ms>:<updated ms>` for every session that is Playing.
 * Changes nothing. The app's own sessions are skipped (`ownAppId`), and a session that throws
 * is skipped without stopping the rest.
 */
export function listPlayingScript(ownAppId = 'ai.useful.voice'): string {
  if (!OWN_ID.test(ownAppId)) throw new Error('the app id has characters a script may not carry');
  return `
$uvOwn = '${ownAppId}'
foreach ($s in @(Get-UvMediaSessions)) {
  try {
    $id = [string]$s.SourceAppUserModelId
    if ($id -eq $uvOwn) { continue }
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Playing') { continue }
    $tl = Get-UvTimeline $s
    Write-Output ('UVPLAYING:' + (Get-UvB64 $id) + ':' + $tl[0] + ':' + $tl[1])
  } catch { Write-Output 'UVSKIP:session' }
}
`;
}

/** The ids as `base64,base64,...`: the only form in which they enter a script. */
export function encodeSessionIds(ids: string[]): string {
  if (ids.length === 0 || ids.length > MAX_IDS) throw new Error('a request needs between 1 and 64 session ids');
  return ids
    .map((id) => {
      if (id.length === 0 || id.length > MAX_ID_LENGTH) throw new Error('a session id is empty or too long');
      return Buffer.from(id, 'utf8').toString('base64');
    })
    .join(',');
}

/**
 * Pause each listed session that is still Playing. After a short settle (apps publish their
 * timeline a moment after a pause) print `UVPAUSED:<base64 id>:<position ms>:<updated ms>`
 * for each that paused: what a later resume compares against.
 */
export function pauseScript(ids: string[]): string {
  const encoded = encodeSessionIds(ids);
  // base64 and commas only: nothing in `encoded` can end the quote it sits in.
  if (!/^[A-Za-z0-9+/=,]+$/.test(encoded)) throw new Error('the encoded ids have unexpected characters');
  return `
$uvWanted = @('${encoded}'.Split(',') | ForEach-Object { ConvertTo-UvId $_ })
$uvDone = @()
foreach ($s in @(Get-UvMediaSessions)) {
  try {
    $id = [string]$s.SourceAppUserModelId
    if ($uvWanted -notcontains $id) { continue }
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Playing') { continue }
    if (Invoke-UvAwait ($s.TryPauseAsync()) ([bool])) { $uvDone += $s }
  } catch { Write-Output 'UVSKIP:session' }
}
if ($uvDone.Count -gt 0) { Start-Sleep -Milliseconds 200 }
foreach ($s in $uvDone) {
  try {
    $tl = Get-UvTimeline $s
    Write-Output ('UVPAUSED:' + (Get-UvB64 ([string]$s.SourceAppUserModelId)) + ':' + $tl[0] + ':' + $tl[1])
  } catch { Write-Output 'UVSKIP:session' }
}
`;
}

const NUMBER = /^-?\d{1,18}$/;

/** `base64:position:updated` (or `base64:n:n` when the pause gave no reading), comma separated. */
function encodeHeld(held: HeldSession[]): string {
  if (held.length === 0 || held.length > MAX_IDS) throw new Error('a resume needs between 1 and 64 sessions');
  return held
    .map((session) => {
      if (session.id.length === 0 || session.id.length > MAX_ID_LENGTH) throw new Error('a session id is empty or too long');
      const id = Buffer.from(session.id, 'utf8').toString('base64');
      if (!session.settled) return `${id}:n:n`;
      const position = String(Math.round(session.settled.position));
      const updated = String(Math.round(session.settled.updated));
      if (!NUMBER.test(position) || !NUMBER.test(updated)) throw new Error('a timeline reading is not a plain number');
      return `${id}:${position}:${updated}`;
    })
    .join(',');
}

/**
 * Play each listed session that is still Paused and whose timeline has not moved more than
 * the tolerance since the pause (a session the person touched is left alone). Prints
 * `UVRESUMED:<n>`.
 */
export function resumeScript(held: HeldSession[]): string {
  const encoded = encodeHeld(held);
  // base64, digits, minus, colons and commas only: nothing can end the quote it sits in.
  if (!/^[A-Za-z0-9+/=,:n-]+$/.test(encoded)) throw new Error('the encoded sessions have unexpected characters');
  return `
$uvWanted = @{}
foreach ($token in '${encoded}'.Split(',')) {
  $p = $token.Split(':')
  $uvWanted[(ConvertTo-UvId $p[0])] = @($p[1], $p[2])
}
$uvResumed = 0
foreach ($s in @(Get-UvMediaSessions)) {
  try {
    $id = [string]$s.SourceAppUserModelId
    if (-not $uvWanted.ContainsKey($id)) { continue }
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Paused') { continue }
    $w = $uvWanted[$id]
    if ($w[0] -ne 'n') {
      $now = Get-UvTimeline $s
      if ([math]::Abs($now[0] - [long]$w[0]) -gt ${TOUCH_TOLERANCE_MS} -or ($now[1] - [long]$w[1]) -gt ${TOUCH_TOLERANCE_MS}) { Write-Output 'UVTOUCHED'; continue }
    }
    if (Invoke-UvAwait ($s.TryPlayAsync()) ([bool])) { $uvResumed++ }
  } catch { Write-Output 'UVSKIP:session' }
}
Write-Output ('UVRESUMED:' + $uvResumed)
`;
}

function parseSessions(stdout: string, tag: 'UVPLAYING' | 'UVPAUSED'): MediaSession[] {
  const found = new Map<string, MediaSession>();
  const line = new RegExp(`^${tag}:([A-Za-z0-9+/]+={0,2}):(-?\\d{1,18}):(-?\\d{1,18})$`);
  for (const raw of stdout.split(/\r?\n/)) {
    const match = line.exec(raw.trim());
    if (!match) continue;
    const id = Buffer.from(match[1] as string, 'base64').toString('utf8');
    if (id.length === 0 || id.length > MAX_ID_LENGTH || found.has(id)) continue;
    found.set(id, { id, position: Number(match[2]), updated: Number(match[3]) });
  }
  return [...found.values()];
}

/** The sessions `listPlayingScript` reports. Anything else in the output is ignored. */
export function parsePlayingOutput(stdout: string): MediaSession[] {
  return parseSessions(stdout, 'UVPLAYING');
}

/** The sessions `pauseScript` reports as paused, with their timeline after the pause. */
export function parsePausedOutput(stdout: string): MediaSession[] {
  return parseSessions(stdout, 'UVPAUSED');
}
