import SwiftUI
import AppKit
import UsefulVoiceCore

struct HistoryPage: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    @EnvironmentObject private var toasts: AppToastCenter

    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var showClearConfirm = false
    @State private var correctionRecord: DictationRecord?
    @State private var correctionObserved = ""
    @State private var correctionCorrected = ""

    private var records: [DictationRecord] {
        _ = viewModel.recent.count
        return viewModel.historyStore.search(query)
    }

    private var selectedRecord: DictationRecord? {
        if let selectedID, let selected = records.first(where: { $0.id == selectedID }) {
            return selected
        }
        return records.first
    }

    var body: some View {
        FillRemainingHeightLayout(spacing: 22) {
            header
            workspace
        }
        .padding(32)
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface)
        .confirmationDialog(
            "Delete all transcripts? This cannot be undone.",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all transcripts", role: .destructive) {
                viewModel.historyStore.clear()
                selectedID = nil
                viewModel.refreshRecent()
                toasts.show("Library cleared", kind: .info)
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $correctionRecord) { record in correctionSheet(record) }
    }

    private var header: some View {
        CommandPageHeader(
            title: "Library"
        ) {
            BrandedMenuButton(help: "Library options") {
                Button("Delete all transcripts", role: .destructive) { showClearConfirm = true }
                    .disabled(viewModel.historyStore.all().isEmpty)
            }
        }
    }

    private var workspace: some View {
        HStack(alignment: .top, spacing: 18) {
            transcriptList.frame(width: 300)
            transcriptDetail.frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
    }

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: 12) {
            PremiumSearchField(placeholder: "Search transcripts", text: $query)

            if records.isEmpty {
                CommandEmptyState(
                    icon: query.isEmpty ? "text.page" : "magnifyingglass",
                    title: query.isEmpty ? "No transcripts yet" : "No matching transcripts",
                    detail: query.isEmpty
                        ? "Your next dictation will appear here automatically."
                        : "Try a shorter word or a different spelling."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(grouped(records), id: \.day) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(dayTitle(group.day))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 4)
                                VStack(spacing: 4) {
                                    ForEach(group.records) { record in
                                        transcriptRow(record)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxHeight: .infinity)
    }

    private func transcriptRow(_ record: DictationRecord) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                selectedID = record.id
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(time(record.createdAt))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(selectedRecord?.id == record.id ? Theme.brand : Theme.muted)
                        Spacer()
                        if let duration = record.durationSeconds {
                            Text(durationText(duration))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Text(record.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .clickableCursor()

            Button {
                copy(record.text)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(PremiumIconButtonStyle())
            .help("Copy transcript")
        }
        .padding(10)
        .background(
            selectedRecord?.id == record.id ? Theme.surface : Color.clear,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selectedRecord?.id == record.id ? Theme.line : Color.clear, lineWidth: 1)
        )
    }

    private var transcriptDetail: some View {
        Group {
            if let record = selectedRecord {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailHeader(record)
                        Text(record.text)
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Divider().overlay(Theme.line)
                        detailActions(record)
                        technicalDetails(record)
                    }
                    .padding(24)
                }
            } else {
                CommandEmptyState(
                    icon: "text.page",
                    title: "Select a transcript",
                    detail: "Choose an item from the library to read or reuse it."
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func detailHeader(_ record: DictationRecord) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fullDate(record.createdAt))
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.ink)
                Text([record.language, record.durationSeconds.map(durationText)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Copy") { copy(record.text) }
                .buttonStyle(.bordered)
                .tint(Theme.brand)
                .clickableCursor()
        }
    }

    private func detailActions(_ record: DictationRecord) -> some View {
        WrappingHStack(horizontalSpacing: 10, verticalSpacing: 8) {
            Button("Learn correction") { beginCorrection(record) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .clickableCursor()
            Button("Send to notes") {
                viewModel.sendToScratchpad(record)
                toasts.show("Sent to notes")
            }
            .buttonStyle(.bordered)
            .tint(Theme.brand)
            .clickableCursor()
            Button("Reprocess") {
                viewModel.reprocessHistoryWithLanguageMemory(record)
                toasts.show("Reprocessing…", kind: .info)
            }
            .buttonStyle(.bordered)
            .tint(Theme.brand)
            .clickableCursor()
            Button("Delete", role: .destructive) { delete(record) }
                .buttonStyle(.borderless)
                .clickableCursor()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func technicalDetails(_ record: DictationRecord) -> some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 12) {
                if let raw = record.rawText, raw != record.text, !raw.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Original transcript")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                        Text(raw)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                    }
                }
                detailLine("Provider", record.provider)
                if let model = record.modelDeployment, !model.isEmpty { detailLine("Model", model) }
                detailLine("Dictionary matches", "\(memoryCount(record))")
            }
            .padding(.top, 10)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.muted)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).foregroundStyle(Theme.ink).textSelection(.enabled)
        }
        .font(.system(size: 12))
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
                Text("Heard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("What Useful Voice heard", text: $correctionObserved).premiumInputChrome()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Write instead").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("Correct spelling", text: $correctionCorrected).premiumInputChrome()
            }

            if !preview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Will learn")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 8) {
                            Text(pair.observed)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.muted)
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
                .buttonStyle(.borderedProminent)
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
        if selectedID == record.id { selectedID = nil }
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
    private func fullDate(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

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
