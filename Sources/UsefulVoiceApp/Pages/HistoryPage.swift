import SwiftUI
import AppKit
import UsefulVoiceCore

struct HistoryPage: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    @EnvironmentObject private var toasts: AppToastCenter

    @State private var query = ""
    @State private var language: String?
    @State private var expandedID: UUID?
    @State private var showClearConfirm = false
    @State private var correctionRecord: DictationRecord?
    @State private var correctionObserved = ""
    @State private var correctionCorrected = ""

    private static let columnWidth: CGFloat = 1100

    var body: some View {
        // Filter and group once per render, never inside a row: rows are lazy and
        // only read their own record, so 1,000 entries stay cheap.
        _ = viewModel.recent.count
        let all = viewModel.historyStore.all()
        let languages = Set(all.compactMap(\.language)).sorted()
        let records = filtered(languages: languages)
        let groups = grouped(records)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header(isEmpty: all.isEmpty)
                if !all.isEmpty { toolbar(languages: languages, shown: records.count, total: all.count) }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .pageColumn(maxWidth: Self.columnWidth)

            if records.isEmpty {
                emptyState(hasRecords: !all.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(groups)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .confirmationDialog(
            "Delete all transcripts? This cannot be undone.",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all transcripts", role: .destructive) {
                viewModel.historyStore.clear()
                expandedID = nil
                language = nil
                viewModel.refreshRecent()
                toasts.show("Library cleared", kind: .info)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $correctionRecord) { record in correctionSheet(record) }
    }

    private func filtered(languages: [String]) -> [DictationRecord] {
        let found = viewModel.historyStore.search(query)
        // A filter whose language no longer exists (deleted entries) shows everything.
        guard let language, languages.contains(language) else { return found }
        return found.filter { $0.language == language }
    }

    private func header(isEmpty: Bool) -> some View {
        CommandPageHeader(title: "Library") {
            BrandedMenuButton(help: "Library options") {
                Button("Delete all transcripts", role: .destructive) { showClearConfirm = true }
                    .disabled(isEmpty)
            }
        }
    }

    private func toolbar(languages: [String], shown: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            PremiumSearchField(placeholder: "Search transcripts", text: $query)
            if languages.count > 1 {
                Menu {
                    Picker("Language", selection: $language) {
                        Text("All languages").tag(String?.none)
                        ForEach(languages, id: \.self) { code in
                            Text(code).tag(String?.some(code))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 6) {
                        Text(language ?? "All languages")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.inkFaint)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .clickableCursor()
            }
            Text(shown == total ? "\(total)" : "\(shown) of \(total)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.inkMuted)
                .fixedSize()
        }
    }

    private func emptyState(hasRecords: Bool) -> some View {
        CommandEmptyState(
            icon: hasRecords ? "magnifyingglass" : "text.page",
            title: hasRecords ? "No matching transcripts" : "No transcripts yet",
            detail: hasRecords ? "Try a shorter word." : "Your next dictation will appear here."
        )
        .padding(32)
    }

    private func list(_ groups: [(day: Date, records: [DictationRecord])]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.day) { group in
                    Section {
                        ForEach(group.records) { record in
                            row(record, expanded: expandedID == record.id)
                        }
                    } header: {
                        Text(dayTitle(group.day))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .pageColumn(maxWidth: Self.columnWidth)
        }
    }

    private func row(_ record: DictationRecord, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(meta(record))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { copy(record.text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(PremiumIconButtonStyle())
                    .help("Copy transcript")
                    .accessibilityLabel("Copy transcript")
                Button {
                    viewModel.sendToScratchpad(record)
                    toasts.show("Sent to notes")
                } label: { Image(systemName: "note.text.badge.plus") }
                    .buttonStyle(PremiumIconButtonStyle())
                    .help("Send to notes")
                    .accessibilityLabel("Send to notes")
                BrandedMenuButton(help: "More actions") {
                    Button("Learn correction") { beginCorrection(record) }
                    Button("Reprocess") {
                        viewModel.reprocessHistoryWithLanguageMemory(record)
                        toasts.show("Reprocessing…", kind: .info)
                    }
                    Divider()
                    Button("Delete", role: .destructive) { delete(record) }
                }
                Button { toggle(record.id) } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(PremiumIconButtonStyle())
                .help(expanded ? "Collapse" : "Expand")
                .accessibilityLabel(expanded ? "Collapse" : "Expand")
            }

            if expanded {
                Text(record.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                expandedDetails(record)
            } else {
                Text(record.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(record.id) }
                    .clickableCursor()
            }
        }
        .padding(14)
        .background(
            expanded ? Theme.surface : Theme.sunken.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(expanded ? Theme.lineStrong : Theme.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func expandedDetails(_ record: DictationRecord) -> some View {
        if let raw = record.rawText, !raw.isEmpty, raw != record.text {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    compareBlock("Original", raw)
                    compareBlock("Formatted", record.text)
                }
                VStack(spacing: 12) {
                    compareBlock("Original", raw)
                    compareBlock("Formatted", record.text)
                }
            }
        }
        WrappingHStack(horizontalSpacing: 18, verticalSpacing: 6) {
            detailLine("Provider", record.provider)
            if let model = record.modelDeployment, !model.isEmpty { detailLine("Model", model) }
            if let mode = record.mode { detailLine("Mode", mode == .formatted ? "Formatted" : "Raw") }
            detailLine("Dictionary matches", "\(memoryCount(record))")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compareBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Theme.inkMuted)
            Text(value).foregroundStyle(Theme.ink).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }

    private func toggle(_ id: UUID) {
        expandedID = expandedID == id ? nil : id
    }

    private func meta(_ record: DictationRecord) -> String {
        let words = record.text.split(whereSeparator: \.isWhitespace).count
        var parts = [time(record.createdAt)]
        if let language = record.language { parts.append(language) }
        if let duration = record.durationSeconds { parts.append(durationText(duration)) }
        parts.append(words == 1 ? "1 word" : "\(words) words")
        return parts.joined(separator: " · ")
    }

    private func correctionSheet(_ record: DictationRecord) -> some View {
        let preview = viewModel.languageMemory.previewLearnCorrection(
            observed: correctionObserved,
            corrected: correctionCorrected
        )
        return VStack(alignment: .leading, spacing: 18) {
            Text("Teach the dictionary")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(Theme.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("Heard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                TextField("What Useful Voice heard", text: $correctionObserved).premiumInputChrome()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Write instead").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                TextField("Correct spelling", text: $correctionCorrected).premiumInputChrome()
            }

            if !preview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Will learn")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 8) {
                            Text(pair.observed)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.inkMuted)
                            Text(pair.corrected)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.brand)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Spacer()
                Button("Cancel") { correctionRecord = nil }
                    .clickableCursor()
                Button("Save and learn") {
                    let result = viewModel.languageMemory.learnCorrection(
                        observed: correctionObserved,
                        corrected: correctionCorrected
                    )
                    viewModel.refreshLanguageMemory()
                    correctionRecord = nil
                    if result.pairs.isEmpty {
                        toasts.show("Nothing new to learn", kind: .info)
                    } else {
                        toasts.show(result.replacementCount <= 1
                                    ? "Correction learned"
                                    : "\(result.replacementCount) corrections learned")
                    }
                }
                .buttonStyle(.brandPrimary)
                .tint(Theme.brand)
                .clickableCursor()
                .disabled(
                    correctionObserved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || correctionCorrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.surface)
    }

    private func beginCorrection(_ record: DictationRecord) {
        // Prefer a short teaching pair: if raw differs from final, start from
        // that. Otherwise put the final text in both fields so the user can
        // edit only the wrong span.
        let raw = record.rawText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let final = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, raw != final {
            correctionObserved = raw
            correctionCorrected = final
        } else {
            correctionObserved = final
            correctionCorrected = final
        }
        correctionRecord = record
    }

    private func delete(_ record: DictationRecord) {
        viewModel.historyStore.delete(id: record.id)
        if expandedID == record.id { expandedID = nil }
        viewModel.refreshRecent()
        toasts.show("Transcript deleted", kind: .info)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toasts.show("Copied")
    }

    private func grouped(_ records: [DictationRecord]) -> [(day: Date, records: [DictationRecord])] {
        let groups = Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.createdAt) }
        return groups.map { ($0.key, $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private func durationText(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        return String(format: "%.1f min", seconds / 60)
    }

    private func memoryCount(_ record: DictationRecord) -> Int {
        (record.memoryHitIDs?.count ?? 0) +
        (record.replacementRuleIDs?.count ?? 0) +
        (record.snippetIDs?.count ?? 0)
    }
}
