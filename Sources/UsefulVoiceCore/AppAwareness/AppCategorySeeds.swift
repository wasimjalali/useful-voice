import Foundation

/// Seed tables for the app category registry.
/// `windows/src/core/apps/appCategorySeeds.ts` mirrors this file rule for rule.
///
/// Ids are macOS bundle identifiers and Windows executable names in one table: the two
/// namespaces cannot collide (`com.apple.mail` against `outlook.exe`), and lookup is
/// case-insensitive. An id marked "unverified" is from memory and could not be checked
/// against the vendor's own app; a wrong entry only means that app falls back to Other.
///
/// Where an app is general-purpose, the category is the one whose writing rules fit what
/// people mostly type there:
/// - Claude and ChatGPT (desktop apps, claude.ai, chatgpt.com) are assistants used for
///   conversation, so they are Work chat (casual, no code rewriting, no email layout).
/// - Coding agents are Coding: Claude Code runs in a terminal (so it is already Coding),
///   claude.ai/code and chatgpt.com/codex are Coding by address. The macOS ChatGPT and Codex
///   desktop apps share one bundle id, com.openai.codex (the Homebrew chatgpt and codex-app
///   casks both quit it), so it is Work chat: ChatGPT is never Coding.
/// - Discord is Personal chat, even though servers are sometimes work.
/// - Orca (com.stablyai.orca) runs Claude Code and Codex in terminal panes, so it is Coding.
public enum AppCategorySeeds {
    public static let emailApps: [String] = [
        "com.apple.mail", // Mail
        "com.microsoft.Outlook", // Outlook for Mac
        "com.readdle.smartemail-Mac", // Spark (unverified)
        "com.superhuman.electron", // Superhuman
        "org.mozilla.thunderbird", // Thunderbird
        "outlook.exe", // Outlook (classic)
        "olk.exe", // Outlook (new)
        "hxoutlook.exe", // Mail (legacy Windows app)
        "thunderbird.exe",
        "spark.exe", // unverified
        "superhuman.exe", // unverified
    ]

    public static let workChatApps: [String] = [
        "com.tinyspeck.slackmacgap", // Slack
        "com.microsoft.teams2", // Microsoft Teams (new)
        "com.microsoft.teams", // Microsoft Teams (classic)
        "Mattermost.Desktop", // Mattermost
        "com.anthropic.claudefordesktop", // Claude desktop (see the note above)
        "com.openai.codex", // ChatGPT and Codex desktop apps (see the note above)
        "com.openai.chat", // older ChatGPT desktop builds (unverified)
        "slack.exe",
        "ms-teams.exe", // Teams (new)
        "teams.exe", // Teams (classic)
        "mattermost.exe",
        "claude.exe", // Claude desktop
        "chatgpt.exe", // ChatGPT desktop (unverified)
    ]

    public static let personalChatApps: [String] = [
        "net.whatsapp.WhatsApp", // WhatsApp
        "desktop.WhatsApp", // WhatsApp (older Electron build, unverified)
        "com.apple.MobileSMS", // Messages
        "ru.keepcoder.Telegram", // Telegram
        "org.telegram.desktop", // Telegram Desktop
        "org.whispersystems.signal-desktop", // Signal
        "com.hnc.Discord", // Discord
        "com.facebook.archon", // Messenger (unverified)
        "whatsapp.exe",
        "whatsapp.root.exe", // unverified
        "telegram.exe",
        "signal.exe",
        "discord.exe",
        "messenger.exe", // unverified
    ]

    public static let codingApps: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2", // iTerm2
        "dev.warp.Warp-Stable", // Warp
        "com.mitchellh.ghostty", // Ghostty
        "com.stablyai.orca", // Orca (terminal panes for coding agents)
        "net.kovidgoyal.kitty", // kitty
        "org.alacritty", // Alacritty
        "com.github.wez.wezterm", // WezTerm
        "com.microsoft.VSCode", // VS Code
        "com.microsoft.VSCodeInsiders",
        "com.vscodium", // VSCodium
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", // Windsurf
        "dev.zed.Zed", // Zed
        "dev.zed.Zed-Preview",
        "com.apple.dt.Xcode",
        "com.google.android.studio", // Android Studio
        "windowsterminal.exe",
        "openconsole.exe", // Windows Terminal's console host (TargetName in microsoft/terminal)
        "wt.exe",
        "powershell.exe",
        "pwsh.exe",
        "cmd.exe",
        "conhost.exe",
        "mintty.exe", // Git Bash
        "warp.exe",
        "wezterm-gui.exe",
        "alacritty.exe",
        "code.exe", // VS Code
        "code - insiders.exe", // unverified (VS Code names the exe after nameShort; the Insiders value is not public)
        "vscodium.exe", // nameShort "VSCodium" in VSCodium's build script, exe is nameShort + .exe
        "cursor.exe",
        "windsurf.exe",
        "zed.exe", // unverified
        "devenv.exe", // Visual Studio
        "idea64.exe", // JetBrains IDEs
        "pycharm64.exe",
        "webstorm64.exe",
        "goland64.exe",
        "rider64.exe",
        "clion64.exe",
        "datagrip64.exe",
        "rubymine64.exe",
        "phpstorm64.exe",
        "studio64.exe", // Android Studio
        "codex.exe", // Codex desktop app (unverified)
    ]

    /// Every JetBrains IDE on macOS has a bundle id starting with this (`com.jetbrains.intellij`, ...).
    public static let codingAppPrefixes: [String] = ["com.jetbrains."]

    public static let docsNotesApps: [String] = [
        "com.apple.Notes",
        "notion.id", // Notion
        "md.obsidian", // Obsidian
        "net.shinyfrog.bear", // Bear
        "com.apple.iWork.Pages",
        "com.microsoft.Word",
        "com.lukilabs.lukiapp", // Craft
        "com.microsoft.onenote.mac", // OneNote (unverified)
        "winword.exe",
        "onenote.exe",
        "notion.exe",
        "obsidian.exe",
        "craft.exe", // unverified
    ]

    /// Web browsers on macOS, by bundle id.
    public static let browserBundleIDs: [String] = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "company.thebrowser.Browser", // Arc
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly", // Firefox Nightly
        "app.zen-browser.zen", // Zen
        "com.kagi.kagimacOS", // Orion
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.dia", // Dia
        "at.studio.AsideBrowser", // Aside
    ]

    /// Web browsers on Windows, by executable name.
    public static let browserExecutables: [String] = [
        "chrome.exe",
        "msedge.exe",
        "brave.exe",
        "firefox.exe",
        "opera.exe",
        "vivaldi.exe",
        "arc.exe",
        "chromium.exe",
    ]

    /// The seeded categories, each a list of ids. Order does not matter: ids are unique.
    public static let appSeeds: [(category: AppCategory, ids: [String])] = [
        (.email, emailApps),
        (.workChat, workChatApps),
        (.personalChat, personalChatApps),
        (.coding, codingApps),
        (.docsNotes, docsNotesApps),
    ]

    /// One web address rule. `host` is lower case without `www.`. `subdomains` also matches
    /// every subdomain. `pathPrefix` (lower case, leading slash) matches that path and
    /// anything below it. Rules are tried in order and the first match wins, so a path
    /// rule sits before the bare host rule for the same site.
    public struct URLRule: Equatable, Sendable {
        public let host: String
        public let subdomains: Bool
        public let pathPrefix: String?
        public let category: AppCategory

        init(_ host: String, _ category: AppCategory, subdomains: Bool = false, path: String? = nil) {
            self.host = host
            self.subdomains = subdomains
            self.pathPrefix = path
            self.category = category
        }
    }

    public static let urlRules: [URLRule] = [
        // Coding agents on the web, before the general assistant rules for the same hosts.
        URLRule("claude.ai", .coding, path: "/code"),
        URLRule("chatgpt.com", .coding, path: "/codex"),
        // Email.
        URLRule("mail.google.com", .email),
        URLRule("outlook.live.com", .email),
        URLRule("outlook.office.com", .email),
        URLRule("outlook.office365.com", .email),
        URLRule("outlook.cloud.microsoft", .email),
        // Work chat.
        URLRule("slack.com", .workChat, subdomains: true),
        URLRule("teams.microsoft.com", .workChat),
        URLRule("teams.live.com", .workChat),
        URLRule("teams.cloud.microsoft", .workChat),
        URLRule("chat.google.com", .workChat),
        URLRule("claude.ai", .workChat),
        URLRule("chatgpt.com", .workChat),
        URLRule("chat.openai.com", .workChat),
        // Personal chat.
        URLRule("web.whatsapp.com", .personalChat),
        URLRule("web.telegram.org", .personalChat),
        URLRule("discord.com", .personalChat, path: "/channels"),
        URLRule("discord.com", .personalChat, path: "/app"),
        URLRule("messenger.com", .personalChat),
        // Docs and notes.
        URLRule("notion.so", .docsNotes, subdomains: true),
        URLRule("notion.site", .docsNotes, subdomains: true),
        URLRule("docs.google.com", .docsNotes, path: "/document"),
    ]
}
