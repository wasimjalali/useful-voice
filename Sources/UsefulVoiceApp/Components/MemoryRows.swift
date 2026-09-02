import SwiftUI
import UsefulVoiceCore

struct MemoryTermRow: View {
    let term: MemoryTerm
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "textformat")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 24, height: 24)
                .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                Text(term.phrase)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if !metadata(for: term).isEmpty {
                    Text(metadata(for: term))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                if !term.notes.isEmpty {
                    Text(term.notes)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(PremiumIconButtonStyle())
                .help("Remove word")
        }
        .padding(14)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func metadata(for term: MemoryTerm) -> String {
        var parts: [String] = []
        if term.notes == "Learned from correction" {
            parts.append("Learned")
        }
        if term.usageCount > 0 { parts.append("used \(term.usageCount)×") }
        let hints = term.pronunciations + term.aliases
        if !hints.isEmpty {
            parts.append("also fixes: " + hints.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

struct ReplacementRuleRow: View {
    let rule: ReplacementRule
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: rule.isEnabled ? "arrow.right" : "pause")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(rule.isEnabled ? Theme.brand : Theme.muted)
                .frame(width: 24, height: 24)
                .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(rule.match)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                    Text(rule.replacement)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
                Text(replacementMetadata(rule))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(action: onToggleEnabled) {
                Image(systemName: rule.isEnabled ? "pause" : "play.fill")
            }
            .buttonStyle(PremiumIconButtonStyle())
            .help(rule.isEnabled ? "Pause correction" : "Resume correction")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(PremiumIconButtonStyle())
                .help("Remove correction")
        }
        .opacity(rule.isEnabled ? 1 : 0.58)
        .padding(14)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func replacementMetadata(_ rule: ReplacementRule) -> String {
        var parts = [matchModeTitle(rule.matchMode), languageTitle(rule.language)]
        if rule.usageCount > 0 { parts.append("used \(rule.usageCount) times") }
        if !rule.isEnabled { parts.append("paused") }
        return parts.joined(separator: " · ")
    }
}

struct MemorySnippetRow: View {
    let snippet: MemorySnippet
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.trigger)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(snippet.expansion)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3)
            }
            Spacer()
            Button(action: onToggleEnabled) {
                Image(systemName: snippet.isEnabled ? "pause" : "play.fill")
            }
            .buttonStyle(PremiumIconButtonStyle())
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(PremiumIconButtonStyle())
        }
        .opacity(snippet.isEnabled ? 1 : 0.58)
        .padding(.vertical, 8)
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

private func languageTitle(_ language: MemoryLanguage) -> String {
    switch language {
    case .auto: return "Any language"
    case .en: return "English"
    case .de: return "German"
    }
}

private func priorityTitle(_ priority: MemoryPriority) -> String {
    switch priority {
    case .normal: return "Normal priority"
    case .high: return "High priority"
    case .always: return "Always include"
    }
}

private func matchModeTitle(_ mode: ReplacementMatchMode) -> String {
    switch mode {
    case .exactPhrase: return "Exact phrase"
    case .caseInsensitivePhrase: return "Case-insensitive"
    case .wordBoundaryPhrase: return "Word boundary"
    }
}
