import SwiftUI
import UsefulVoiceCore

struct MemoryTermRow: View {
    let term: MemoryTerm
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(term.phrase)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if !hints.isEmpty {
                    Text("Also fixes " + hints.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if term.notes == "Learned from correction" {
                MemoryChip(text: "Learned")
            }
            MemoryMeta(language: term.language, usageCount: term.usageCount)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(PremiumIconButtonStyle())
                .help("Remove word")
        }
        .memoryRowChrome()
    }

    private var hints: [String] { term.pronunciations + term.aliases }
}

struct ReplacementRuleRow: View {
    let rule: ReplacementRule
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Text(rule.match)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkFaint)
                Text(rule.replacement)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if !rule.isEnabled { MemoryChip(text: "Paused") }
            MemoryMeta(language: rule.language, usageCount: rule.usageCount)
            Button(action: onToggleEnabled) {
                Image(systemName: rule.isEnabled ? "pause" : "play.fill")
            }
            .buttonStyle(PremiumIconButtonStyle())
            .help(rule.isEnabled ? "Pause fix" : "Resume fix")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(PremiumIconButtonStyle())
                .help("Remove fix")
        }
        .opacity(rule.isEnabled ? 1 : 0.58)
        .memoryRowChrome()
    }
}

struct MemorySnippetRow: View {
    let snippet: MemorySnippet
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.trigger)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(snippet.expansion)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            if !snippet.isEnabled { MemoryChip(text: "Paused") }
            MemoryMeta(language: snippet.language, usageCount: snippet.usageCount)
            Button(action: onToggleEnabled) {
                Image(systemName: snippet.isEnabled ? "pause" : "play.fill")
            }
            .buttonStyle(PremiumIconButtonStyle())
            .help(snippet.isEnabled ? "Pause snippet" : "Resume snippet")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(PremiumIconButtonStyle())
                .help("Remove snippet")
        }
        .opacity(snippet.isEnabled ? 1 : 0.58)
        .memoryRowChrome()
    }
}

/// Language (when scoped) and usage count, shared by every row.
private struct MemoryMeta: View {
    let language: MemoryLanguage
    let usageCount: Int

    var body: some View {
        HStack(spacing: 8) {
            if language != .auto { MemoryChip(text: language.displayName) }
            if usageCount > 0 {
                Text(usageCount == 1 ? "1 use" : "\(usageCount) uses")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

private struct MemoryChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.inkMuted)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.sunken, in: Capsule())
    }
}

private extension View {
    func memoryRowChrome() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct MemorySuggestionRow: View {
    let suggestion: MemorySuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Text(suggestion.proposed)
                .foregroundStyle(Theme.ink)
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
                .clickableCursor()
            Button("Add", action: onAccept)
                .buttonStyle(.bordered)
                .tint(Theme.brand)
                .clickableCursor()
        }
    }
}
