import type { AppCategory } from './appCategory.js';

/**
 * Seed tables for the app category registry. Mirrors
 * `Sources/UsefulVoiceCore/AppAwareness/AppCategorySeeds.swift` rule for rule.
 *
 * Ids are macOS bundle identifiers and Windows executable names in one table: the two
 * namespaces cannot collide (`com.apple.mail` against `outlook.exe`), and lookup is
 * case-insensitive. An id marked "unverified" is from memory and could not be checked
 * against the vendor's own app; a wrong entry only means that app falls back to Other.
 *
 * Where an app is general-purpose, the category is the one whose writing rules fit what
 * people mostly type there:
 * - Claude and ChatGPT (desktop apps, claude.ai, chatgpt.com) are assistants used for
 *   conversation, so they are Work chat (casual, no code rewriting, no email layout).
 * - Coding agents are Coding: Claude Code runs in a terminal (so it is already Coding),
 *   claude.ai/code, chatgpt.com/codex and the Codex desktop app are Coding by address.
 * - Discord is Personal chat, even though servers are sometimes work.
 * - The Dia browser is not listed: its bundle id could not be confirmed from a public source.
 */

export const EMAIL_APPS: readonly string[] = [
  'com.apple.mail', // Mail
  'com.microsoft.Outlook', // Outlook for Mac
  'com.readdle.smartemail-Mac', // Spark (unverified)
  'com.superhuman.electron', // Superhuman
  'org.mozilla.thunderbird', // Thunderbird
  'outlook.exe', // Outlook (classic)
  'olk.exe', // Outlook (new)
  'hxoutlook.exe', // Mail (legacy Windows app)
  'thunderbird.exe',
  'spark.exe', // unverified
  'superhuman.exe', // unverified
];

export const WORK_CHAT_APPS: readonly string[] = [
  'com.tinyspeck.slackmacgap', // Slack
  'com.microsoft.teams2', // Microsoft Teams (new)
  'com.microsoft.teams', // Microsoft Teams (classic)
  'Mattermost.Desktop', // Mattermost
  'com.anthropic.claudefordesktop', // Claude desktop (see the note above)
  'com.openai.chat', // ChatGPT desktop (unverified)
  'slack.exe',
  'ms-teams.exe', // Teams (new)
  'teams.exe', // Teams (classic)
  'mattermost.exe',
  'claude.exe', // Claude desktop
  'chatgpt.exe', // ChatGPT desktop (unverified)
];

export const PERSONAL_CHAT_APPS: readonly string[] = [
  'net.whatsapp.WhatsApp', // WhatsApp
  'desktop.WhatsApp', // WhatsApp (older Electron build, unverified)
  'com.apple.MobileSMS', // Messages
  'ru.keepcoder.Telegram', // Telegram
  'org.telegram.desktop', // Telegram Desktop
  'org.whispersystems.signal-desktop', // Signal
  'com.hnc.Discord', // Discord
  'com.facebook.archon', // Messenger (unverified)
  'whatsapp.exe',
  'whatsapp.root.exe',
  'telegram.exe',
  'signal.exe',
  'discord.exe',
  'messenger.exe', // unverified
];

export const CODING_APPS: readonly string[] = [
  'com.apple.Terminal',
  'com.googlecode.iterm2', // iTerm2
  'dev.warp.Warp-Stable', // Warp
  'com.mitchellh.ghostty', // Ghostty
  'net.kovidgoyal.kitty', // kitty
  'org.alacritty', // Alacritty
  'com.github.wez.wezterm', // WezTerm
  'com.microsoft.VSCode', // VS Code
  'com.microsoft.VSCodeInsiders',
  'com.vscodium', // VSCodium
  'com.todesktop.230313mzl4w4u92', // Cursor
  'com.exafunction.windsurf', // Windsurf
  'dev.zed.Zed', // Zed
  'dev.zed.Zed-Preview',
  'com.apple.dt.Xcode',
  'com.google.android.studio', // Android Studio
  'com.openai.codex', // Codex desktop app (also the id of the macOS ChatGPT desktop app, per the Homebrew casks)
  'windowsterminal.exe',
  'openconsole.exe', // Windows Terminal's console host
  'wt.exe',
  'powershell.exe',
  'pwsh.exe',
  'cmd.exe',
  'conhost.exe',
  'mintty.exe', // Git Bash
  'warp.exe',
  'wezterm-gui.exe',
  'alacritty.exe',
  'code.exe', // VS Code
  'code - insiders.exe',
  'vscodium.exe',
  'cursor.exe',
  'windsurf.exe',
  'zed.exe', // unverified
  'devenv.exe', // Visual Studio
  'idea64.exe', // JetBrains IDEs
  'pycharm64.exe',
  'webstorm64.exe',
  'goland64.exe',
  'rider64.exe',
  'clion64.exe',
  'datagrip64.exe',
  'rubymine64.exe',
  'phpstorm64.exe',
  'studio64.exe', // Android Studio
  'codex.exe', // Codex desktop app (unverified)
];

/** Every JetBrains IDE on macOS has a bundle id starting with this (`com.jetbrains.intellij`, ...). */
export const CODING_APP_PREFIXES: readonly string[] = ['com.jetbrains.'];

export const DOCS_NOTES_APPS: readonly string[] = [
  'com.apple.Notes',
  'notion.id', // Notion
  'md.obsidian', // Obsidian
  'net.shinyfrog.bear', // Bear
  'com.apple.iWork.Pages',
  'com.microsoft.Word',
  'com.lukilabs.lukiapp', // Craft
  'com.microsoft.onenote.mac', // OneNote (unverified)
  'winword.exe',
  'onenote.exe',
  'notion.exe',
  'obsidian.exe',
  'craft.exe', // unverified
];

/** Web browsers on macOS, by bundle id. */
export const BROWSER_BUNDLE_IDS: readonly string[] = [
  'com.apple.Safari',
  'com.apple.SafariTechnologyPreview',
  'com.google.Chrome',
  'com.google.Chrome.beta',
  'com.google.Chrome.dev',
  'com.google.Chrome.canary',
  'org.chromium.Chromium',
  'company.thebrowser.Browser', // Arc
  'com.microsoft.edgemac',
  'com.microsoft.edgemac.Beta',
  'com.microsoft.edgemac.Dev',
  'com.brave.Browser',
  'com.brave.Browser.beta',
  'com.brave.Browser.nightly',
  'org.mozilla.firefox',
  'org.mozilla.firefoxdeveloperedition',
  'org.mozilla.nightly', // Firefox Nightly
  'app.zen-browser.zen', // Zen
  'com.kagi.kagimacOS', // Orion
  'com.operasoftware.Opera',
  'com.vivaldi.Vivaldi',
];

/** Web browsers on Windows, by executable name. */
export const BROWSER_EXECUTABLES: readonly string[] = [
  'chrome.exe',
  'msedge.exe',
  'brave.exe',
  'firefox.exe',
  'opera.exe',
  'vivaldi.exe',
  'arc.exe',
  'chromium.exe',
];

/** The seeded categories, each a list of ids. Order does not matter: ids are unique. */
export const APP_SEEDS: readonly { category: AppCategory; ids: readonly string[] }[] = [
  { category: 'email', ids: EMAIL_APPS },
  { category: 'workChat', ids: WORK_CHAT_APPS },
  { category: 'personalChat', ids: PERSONAL_CHAT_APPS },
  { category: 'coding', ids: CODING_APPS },
  { category: 'docsNotes', ids: DOCS_NOTES_APPS },
];

/**
 * One web address rule. `host` is lower case without `www.`. `subdomains` also matches
 * every subdomain. `pathPrefix` (lower case, leading slash) matches that path and
 * anything below it. Rules are tried in order and the first match wins, so a path rule
 * sits before the bare host rule for the same site.
 */
export interface URLRule {
  host: string;
  subdomains: boolean;
  pathPrefix: string | null;
  category: AppCategory;
}

function rule(
  host: string,
  category: AppCategory,
  options: { subdomains?: boolean; path?: string } = {},
): URLRule {
  return { host, subdomains: options.subdomains ?? false, pathPrefix: options.path ?? null, category };
}

export const URL_RULES: readonly URLRule[] = [
  // Coding agents on the web, before the general assistant rules for the same hosts.
  rule('claude.ai', 'coding', { path: '/code' }),
  rule('chatgpt.com', 'coding', { path: '/codex' }),
  // Email.
  rule('mail.google.com', 'email'),
  rule('outlook.live.com', 'email'),
  rule('outlook.office.com', 'email'),
  rule('outlook.office365.com', 'email'),
  rule('outlook.cloud.microsoft', 'email'),
  // Work chat.
  rule('slack.com', 'workChat', { subdomains: true }),
  rule('teams.microsoft.com', 'workChat'),
  rule('teams.live.com', 'workChat'),
  rule('teams.cloud.microsoft', 'workChat'),
  rule('chat.google.com', 'workChat'),
  rule('claude.ai', 'workChat'),
  rule('chatgpt.com', 'workChat'),
  rule('chat.openai.com', 'workChat'),
  // Personal chat.
  rule('web.whatsapp.com', 'personalChat'),
  rule('web.telegram.org', 'personalChat'),
  rule('discord.com', 'personalChat', { path: '/channels' }),
  rule('discord.com', 'personalChat', { path: '/app' }),
  rule('messenger.com', 'personalChat'),
  // Docs and notes.
  rule('notion.so', 'docsNotes', { subdomains: true }),
  rule('notion.site', 'docsNotes', { subdomains: true }),
  rule('docs.google.com', 'docsNotes', { path: '/document' }),
];
