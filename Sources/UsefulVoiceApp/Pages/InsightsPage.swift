import SwiftUI
import UsefulVoiceCore

/// Usage insights computed from the dictation history. Filled in by the Insights work.
struct InsightsPage: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CommandPageHeader(title: "Insights") { EmptyView() }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .pageColumn()
        }
        .background(Theme.surface)
    }
}
