import { describe, expect, it } from 'vitest';
import { RELEASES_REPO_LIVE, releaseLinks } from '../src/core/releaseLinks.js';

// The failure to guard against: a link to a repo that does not exist yet shipping in a
// build. So the off state is checked first and hardest.
describe('release links', () => {
  it('ships off until the repos exist', () => {
    expect(RELEASES_REPO_LIVE).toBe(false);
    expect(releaseLinks()).toEqual([]);
  });

  it('off hides every link', () => {
    expect(releaseLinks(false)).toEqual([]);
  });

  it('on shows three https links in order', () => {
    const links = releaseLinks(true);
    expect(links.map((l) => l.title)).toEqual(['Report a bug', "What's new", 'Privacy']);
    for (const l of links) expect(new URL(l.url).protocol).toBe('https:');
  });

  it('on points at the releases repo and the privacy page', () => {
    const urls = releaseLinks(true).map((l) => l.url);
    expect(urls).toEqual([
      'https://github.com/wasimjalali/useful-voice-releases/issues/new',
      'https://github.com/wasimjalali/useful-voice-releases/releases',
      'https://voice.usefulbuild.com/privacy',
    ]);
  });
});
