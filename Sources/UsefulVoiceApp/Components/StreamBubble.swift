import AppKit
import SwiftUI
import UsefulVoiceCore

/// One dictation: the lifted bubble, its meta row, and its actions.
///
/// Actions show on hover and on keyboard focus. The list is one tab stop: arrow keys
/// move the focus from bubble to bubble and Enter opens the action menu (see
/// `StreamTimeline`).
struct StreamBubble: View {
    let record: DictationRecord
    @ObservedObject var store: StreamStore

    @State private var hovering = false
    @State private var lineCount = 0
    @State private var noteOpen = false
    @State private var moreOpen = false
    @State private var selection: (range: NSRange, rect: CGRect)?
    @State private var teach: Teach?

    private struct Teach {
        let range: NSRange
        let rect: CGRect
        let heard: String
    }

    private static let collapsedLines = 4

    private var isFocused: Bool { store.focusedID == record.id }
    private var isSelected: Bool { store.selection.contains(record.id) }
    private var isExpanded: Bool { store.expanded.contains(record.id) }
    private var isFresh: Bool { store.freshID == record.id }
    private var original: String? {
        guard let raw = record.rawText, !raw.isEmpty, raw != record.text else { return nil }
        return raw
    }
    private var showsOriginal: Bool { original != nil && store.originalShown.contains(record.id) }
    private var excerpt: String? {
        guard !isExpanded, !showsOriginal, !store.query.isEmpty else { return nil }
        return StreamText.excerpt(of: record.text, matching: store.query)
    }
    private var rtl: Bool { StreamFormat.isRTL(record.text) }
    private var actionsVisible: Bool {
        hovering || isFocused || noteOpen || moreOpen || teach != nil || store.menuID == record.id
    }

    private var spec: StreamTextSpec {
        var spec: StreamTextSpec
        if showsOriginal, let original, let diff = StreamText.diff(original: original, final: record.text) {
            spec = diff
        } else {
            let text = excerpt ?? record.text
            spec = StreamTextSpec(
                text: text,
                spans: StreamText.matches(of: store.query, in: text).map { .init(range: $0, style: .match) },
                rtl: rtl)
        }
        if let teach { spec.spans.append(.init(range: teach.range, style: .teach)) }
        return spec
    }

    var body: some View {
        StreamHugLayout(minWidth: 300, maxWidth: 640) { bubble }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            StreamTextView(
                spec: spec,
                lineLimit: isExpanded || showsOriginal ? nil : Self.collapsedLines,
                onSelectionEnd: { range, rect in
                    selection = (range, rect)
                    if store.teachSelectID == record.id { beginTeach() }
                },
                onShiftClick: { store.shiftClick(record.id) },
                // A click drops the old selection. It must not move focus: that would end
                // a drag-selection in the text view.
                onPlainClick: { selection = nil },
                onLineCount: { lineCount = $0 })
                .popover(isPresented: Binding(get: { teach != nil }, set: { if !$0 { teach = nil } }),
                         attachmentAnchor: .rect(.rect(teach?.rect ?? .zero)), arrowEdge: .bottom) {
                    if let teach {
                        StreamTeachPopover(
                            heard: teach.heard,
                            onSave: { corrected in
                                self.teach = nil
                                store.learn(observed: teach.heard, corrected: corrected)
                            },
                            onCorrectOne: { _ in
                                self.teach = nil
                                store.show("Correcting one dictation is not stored yet", kind: .info)
                            })
                    }
                }
            if store.teachSelectID == record.id { selectHint }
            if excerpt != nil || (lineCount > Self.collapsedLines && !showsOriginal) { showAllButton }
            metaRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .liftCard()
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.lineStrong, lineWidth: 1)
            .opacity(hovering && !isSelected && !isFocused ? 1 : 0))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.ink, lineWidth: 2)
            .opacity(isSelected || isFocused ? 1 : 0))
        .overlay(alignment: .bottomTrailing) { actions }
        .overlay(alignment: .leading) { selectedBadge }
        .themeShadow(isFresh ? .raise : .none)
        .onHover { hovering = $0 }
        .brandAnimation(BrandMotion.control, value: hovering)
        .brandAnimation(BrandMotion.control, value: isSelected)
        .popover(isPresented: Binding(get: { store.menuID == record.id },
                                      set: { if !$0, store.menuID == record.id { store.menuID = nil } }),
                 arrowEdge: .bottom) {
            StreamMenuList(items: menuItems(all: true), close: { store.menuID = nil })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation, \(metaText)")
    }

    // MARK: Parts

    private var metaText: String {
        var parts = [StreamFormat.time(record.createdAt)]
        // Isolate the language name so a right-to-left name cannot reorder the line.
        if let language = StreamFormat.language(forCode: record.language) { parts.append("\u{2068}\(language.name)\u{2069}") }
        parts.append(StreamFormat.words(DictationOutcome.wordCount(of: record.text)))
        if let seconds = record.durationSeconds { parts.append(StreamFormat.duration(seconds)) }
        return "\u{2066}" + parts.joined(separator: " \u{00B7} ") + "\u{2069}"
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(metaText)
                .font(.uv(.meta).monospacedDigit())
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
            if showsOriginal {
                Text("\u{00B7}").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                Button("Hide original") { store.toggleOriginal(record.id) }
                    .buttonStyle(.plain)
                    .font(.uv(.meta, .medium))
                    .foregroundStyle(Theme.ink)
                    .underline(true, color: Theme.lineStrong)
                    .clickableCursor()
            }
            // Room for the action strip, so it never covers the meta text.
            Color.clear.frame(width: 132, height: 24)
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var showAllButton: some View {
        Button { store.toggleExpanded(record.id) } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "Show less" : "Show all")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.uv(.label, .semibold))
            }
            .font(.uv(.ui, .semibold))
            .foregroundStyle(Theme.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }

    private var selectHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.uv(.ui))
            Text("Select the words it got wrong")
                .font(.uv(.meta, .medium))
            Spacer(minLength: 12)
            Button("Cancel") { store.teachSelectID = nil }
                .buttonStyle(.plain)
                .font(.uv(.meta, .semibold))
                .foregroundStyle(Theme.ink)
                .clickableCursor()
        }
        .foregroundStyle(Theme.inkMuted)
    }

    @ViewBuilder
    private var selectedBadge: some View {
        if isSelected {
            ZStack {
                Circle().fill(Theme.ink)
                Image(systemName: "checkmark")
                    .font(.uv(.label, .bold))
                    .foregroundStyle(Theme.brandInk)
            }
            .frame(width: 18, height: 18)
            .offset(x: -26)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            iconButton("doc.on.doc", "Copy") { store.copy([record]) }
            iconButton("note.text.badge.plus", "Add to note") { noteOpen = true }
                .popover(isPresented: $noteOpen, arrowEdge: .bottom) {
                    StreamNotePicker(scratchpad: store.viewModel.scratchpad, onPick: { note in
                        noteOpen = false
                        store.addToNote([record], note: note)
                    }, onNew: {
                        noteOpen = false
                        store.addToNewNote([record])
                    })
                }
            iconButton("text.badge.checkmark", "Teach a fix") { teachTapped() }
            iconButton("ellipsis", "More") { moreOpen = true }
                .popover(isPresented: $moreOpen, arrowEdge: .bottom) {
                    StreamMenuList(items: menuItems(all: false), close: { moreOpen = false })
                }
        }
        .padding(.trailing, 12)
        .padding(.bottom, 4)
        .opacity(actionsVisible ? 1 : 0)
        .allowsHitTesting(actionsVisible)
        .brandAnimation(BrandMotion.control, value: actionsVisible)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(PremiumIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func menuItems(all: Bool) -> [StreamMenuItem] {
        var items: [StreamMenuItem] = []
        if all {
            items.append(.init(id: "copy", title: "Copy", icon: "doc.on.doc") { store.copy([record]) })
            items.append(.init(id: "note", title: "Add to note", icon: "note.text.badge.plus") { noteOpen = true })
            items.append(.init(id: "teach", title: "Teach a fix", icon: "text.badge.checkmark") { teachTapped() })
        }
        items.append(.init(id: "reprocess", title: "Reprocess", icon: "arrow.triangle.2.circlepath") {
            store.reprocess(record)
        })
        if original != nil {
            items.append(.init(id: "original", title: showsOriginal ? "Hide original" : "Show original",
                               icon: "clock.arrow.circlepath") { store.toggleOriginal(record.id) })
        }
        items.append(.init(id: "delete", title: "Delete", icon: "trash", destructive: true) {
            store.requestDelete(record)
        })
        return items
    }

    /// Words already selected: teach at once. Nothing selected: wait for a selection.
    private func teachTapped() {
        if selection != nil {
            beginTeach()
        } else {
            store.teachSelectID = record.id
        }
    }

    private func beginTeach() {
        store.teachSelectID = nil
        guard let selection else { return }
        let text = spec.text as NSString
        guard NSMaxRange(selection.range) <= text.length else { return }
        let heard = text.substring(with: selection.range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return }
        teach = Teach(range: selection.range, rect: selection.rect, heard: heard)
    }
}

/// Sizes its one child to its own content, never wider than `maxWidth` or narrower than
/// `minWidth`, so a bubble hugs its text. (A flexible frame would always fill.)
private struct StreamHugLayout: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: max(size.width, min(minWidth, width)), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
