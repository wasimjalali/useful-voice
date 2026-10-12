/**
 * Links into the public releases repo, github.com/wasimjalali/useful-voice-releases.
 *
 * The repos do not exist yet, so every link stays hidden while `RELEASES_REPO_LIVE`
 * is false. Flip it in the PR that publishes the repos, not before.
 */
export const RELEASES_REPO_LIVE = false;

export interface ReleaseLink {
  title: string;
  url: string;
}

/** The Settings rows, in order. Empty while the switch is off. `live` is for tests. */
export function releaseLinks(live: boolean = RELEASES_REPO_LIVE): ReleaseLink[] {
  if (!live) return [];
  return [
    { title: 'Report a bug', url: 'https://github.com/wasimjalali/useful-voice-releases/issues/new' },
    { title: "What's new", url: 'https://github.com/wasimjalali/useful-voice-releases/releases' },
    { title: 'Privacy', url: 'https://voice.usefulbuild.com/privacy' },
  ];
}
