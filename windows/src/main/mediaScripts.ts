import {
  TOUCH_TOLERANCE_MS,
  type HeldSession,
  type MediaSession,
  type PauseResult,
  type ResumeResult,
} from '../core/media/mediaPausePolicy.js';

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
$uvWaitMs = 3000
function Invoke-UvAwait($operation, [Type]$resultType) {
  $task = $uvAsTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
  if (-not $task.Wait($uvWaitMs)) { throw 'a media request timed out' }
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
$uvWaitMs = 3000
$uvOwn = '${ownAppId}'
foreach ($s in @(Get-UvMediaSessions)) {
  try {
    $id = [string]$s.SourceAppUserModelId
    if ($id -eq $uvOwn) { continue }
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Playing') { continue }
    $tl = Get-UvTimeline $s
    Write-Output ('UVPLAYING:' + (Get-UvB64 $id) + ':' + $tl[0] + ':' + $tl[1])
  } catch { Write-Output 'UVSKIP:-' }
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

/** How long one WinRT call may take inside a pause: 1.5 s, or 1 s once the app is quitting. */
export const PAUSE_WAIT_MS = 1500;
export const PAUSE_WAIT_QUITTING_MS = 1000;

/**
 * Pause each listed session that is still Playing. Prints, per session, either
 * `UVPAUSED:<base64 id>:<position ms>:<updated ms>` (Windows answered true; the timeline is
 * read at once, and the caller reads it again after a settle) or `UVREFUSED:<base64 id>`
 * (Windows answered false). A session that was no longer Playing prints nothing.
 */
export function pauseScript(ids: string[], options: { quitting?: boolean } = {}): string {
  const encoded = encodeSessionIds(ids);
  // base64 and commas only: nothing in `encoded` can end the quote it sits in.
  if (!/^[A-Za-z0-9+/=,]+$/.test(encoded)) throw new Error('the encoded ids have unexpected characters');
  const wait = options.quitting ? PAUSE_WAIT_QUITTING_MS : PAUSE_WAIT_MS;
  return `
$uvWaitMs = ${wait}
$uvWanted = @('${encoded}'.Split(',') | ForEach-Object { ConvertTo-UvId $_ })
foreach ($s in @(Get-UvMediaSessions)) {
  $id = ''
  try {
    $id = [string]$s.SourceAppUserModelId
    if ($uvWanted -notcontains $id) { continue }
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Playing') { continue }
    if (Invoke-UvAwait ($s.TryPauseAsync()) ([bool])) {
      $tl = Get-UvTimeline $s
      Write-Output ('UVPAUSED:' + (Get-UvB64 $id) + ':' + $tl[0] + ':' + $tl[1])
    } else {
      Write-Output ('UVREFUSED:' + (Get-UvB64 $id))
    }
  } catch {
    # The await outran its cap or threw: the pause may still have landed. Name the session,
    # so the caller keeps it held as unconfirmed instead of forgetting it.
    if ($id) { Write-Output ('UVSKIP:' + (Get-UvB64 $id)) } else { Write-Output 'UVSKIP:-' }
  }
}
`;
}

/** Print `UVTIMELINE:<base64 id>:<position ms>:<updated ms>` for each listed session, whatever its state. */
export function timelineScript(ids: string[]): string {
  const encoded = encodeSessionIds(ids);
  if (!/^[A-Za-z0-9+/=,]+$/.test(encoded)) throw new Error('the encoded ids have unexpected characters');
  return `
$uvWaitMs = 3000
$uvWanted = @('${encoded}'.Split(',') | ForEach-Object { ConvertTo-UvId $_ })
foreach ($s in @(Get-UvMediaSessions)) {
  try {
    $id = [string]$s.SourceAppUserModelId
    if ($uvWanted -notcontains $id) { continue }
    $tl = Get-UvTimeline $s
    Write-Output ('UVTIMELINE:' + (Get-UvB64 $id) + ':' + $tl[0] + ':' + $tl[1])
  } catch { Write-Output 'UVSKIP:-' }
}
`;
}

const NUMBER = /^-?\d{1,18}$/;

/**
 * `base64:confirmed:position:updated:requestedAt`, comma separated. `confirmed` is 1 or 0;
 * position and updated are `n` when the pause gave no reading.
 */
function encodeHeld(held: HeldSession[]): string {
  if (held.length === 0 || held.length > MAX_IDS) throw new Error('a resume needs between 1 and 64 sessions');
  return held
    .map((session) => {
      if (session.id.length === 0 || session.id.length > MAX_ID_LENGTH) throw new Error('a session id is empty or too long');
      const id = Buffer.from(session.id, 'utf8').toString('base64');
      const requested = String(Math.round(session.requestedAt));
      if (!NUMBER.test(requested)) throw new Error('a request time is not a plain number');
      const confirmed = session.confirmed ? '1' : '0';
      if (!session.settled) return `${id}:${confirmed}:n:n:${requested}`;
      const position = String(Math.round(session.settled.position));
      const updated = String(Math.round(session.settled.updated));
      if (!NUMBER.test(position) || !NUMBER.test(updated)) throw new Error('a timeline reading is not a plain number');
      return `${id}:${confirmed}:${position}:${updated}:${requested}`;
    })
    .join(',');
}

/**
 * Play each listed session that is Paused and passes the same rule as `resumeVerdict`:
 *  - confirmed by our pause: played unless its timeline moved more than the tolerance past
 *    the reading the pause took (`UVTOUCHED`);
 *  - not confirmed (the answer was lost): played only if its last update is at or after the
 *    moment we asked and within the tolerance of it, else `UVUNCONFIRMED`.
 * A play Windows refuses prints `UVREFUSED`. Ends with `UVRESUMED:<n>`.
 */
export function resumeScript(held: HeldSession[]): string {
  const encoded = encodeHeld(held);
  // base64, digits, minus, colons and commas only: nothing can end the quote it sits in.
  if (!/^[A-Za-z0-9+/=,:n-]+$/.test(encoded)) throw new Error('the encoded sessions have unexpected characters');
  return `
$uvWaitMs = 3000
$uvWanted = @{}
foreach ($token in '${encoded}'.Split(',')) {
  $p = $token.Split(':')
  $uvWanted[(ConvertTo-UvId $p[0])] = @($p[1], $p[2], $p[3], $p[4])
}
$uvResumed = 0
foreach ($s in @(Get-UvMediaSessions)) {
  $id = ''
  try {
    $id = [string]$s.SourceAppUserModelId
    if (-not $uvWanted.ContainsKey($id)) { continue }
    if ($s.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Paused') { continue }
    $w = $uvWanted[$id]
    $now = Get-UvTimeline $s
    if ($w[0] -eq '1') {
      if ($w[1] -ne 'n') {
        if ([math]::Abs($now[0] - [long]$w[1]) -gt ${TOUCH_TOLERANCE_MS} -or ($now[1] - [long]$w[2]) -gt ${TOUCH_TOLERANCE_MS}) { Write-Output ('UVTOUCHED:' + (Get-UvB64 $id)); continue }
      }
    } else {
      $since = $now[1] - [long]$w[3]
      if ($since -lt 0 -or $since -gt ${TOUCH_TOLERANCE_MS}) { Write-Output ('UVUNCONFIRMED:' + (Get-UvB64 $id)); continue }
    }
    if (Invoke-UvAwait ($s.TryPlayAsync()) ([bool])) { $uvResumed++ } else { Write-Output ('UVREFUSED:' + (Get-UvB64 $id)) }
  } catch {
    # The await outran its cap or threw: it may still be paused. Name it, so quit can say so.
    if ($id) { Write-Output ('UVSKIP:' + (Get-UvB64 $id)) } else { Write-Output 'UVSKIP:-' }
  }
}
Write-Output ('UVRESUMED:' + $uvResumed)
`;
}

function decodeId(encoded: string): string | null {
  const id = Buffer.from(encoded, 'base64').toString('utf8');
  return id.length > 0 && id.length <= MAX_ID_LENGTH ? id : null;
}

function parseSessions(stdout: string, tag: 'UVPLAYING' | 'UVPAUSED' | 'UVTIMELINE'): MediaSession[] {
  const found = new Map<string, MediaSession>();
  const line = new RegExp(`^${tag}:([A-Za-z0-9+/]+={0,2}):(-?\\d{1,18}):(-?\\d{1,18})$`);
  for (const raw of stdout.split(/\r?\n/)) {
    const match = line.exec(raw.trim());
    if (!match) continue;
    const id = decodeId(match[1] as string);
    if (id === null || found.has(id)) continue;
    found.set(id, { id, position: Number(match[2]), updated: Number(match[3]) });
  }
  return [...found.values()];
}

/** The ids a `UV<TAG>:<base64 id>` line names, in order, without repeats. */
function parseIds(stdout: string, tag: 'UVREFUSED' | 'UVTOUCHED' | 'UVUNCONFIRMED' | 'UVSKIP'): string[] {
  const ids = new Set<string>();
  for (const raw of stdout.split(/\r?\n/)) {
    const match = new RegExp(`^${tag}:([A-Za-z0-9+/]+={0,2})$`).exec(raw.trim());
    const id = match ? decodeId(match[1] as string) : null;
    if (id !== null) ids.add(id);
  }
  return [...ids];
}

/** The sessions `listPlayingScript` reports. Anything else in the output is ignored. */
export function parsePlayingOutput(stdout: string): MediaSession[] {
  return parseSessions(stdout, 'UVPLAYING');
}

/** What `pauseScript` reported: sessions Windows paused (with a timeline) and ones it refused. */
export function parsePauseOutput(stdout: string): PauseResult {
  return {
    confirmed: parseSessions(stdout, 'UVPAUSED'),
    refused: parseIds(stdout, 'UVREFUSED'),
    // `UVSKIP:-` (no id known) is not base64, so it matches nothing here.
    skipped: parseIds(stdout, 'UVSKIP'),
  };
}

/** The timelines `timelineScript` reports. */
export function parseTimelineOutput(stdout: string): MediaSession[] {
  return parseSessions(stdout, 'UVTIMELINE');
}

/**
 * What `resumeScript` reported about the sessions it did not play. Throws when the closing
 * `UVRESUMED:<n>` line is missing: without it the script did not run to the end (it failed,
 * or its output was cut), and "nothing was refused" would be a lie.
 */
export function parseResumeOutput(stdout: string): ResumeResult {
  if (!/^UVRESUMED:\d+$/m.test(stdout.replace(/\r/g, ''))) throw new Error('the resume script did not finish');
  return {
    refused: parseIds(stdout, 'UVREFUSED'),
    touched: parseIds(stdout, 'UVTOUCHED'),
    unconfirmed: parseIds(stdout, 'UVUNCONFIRMED'),
    skipped: parseIds(stdout, 'UVSKIP'),
  };
}
