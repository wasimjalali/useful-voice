import Testing
@testable import UsefulVoiceCore

@Suite struct ResponsiveLayoutRulesTests {
    @Test func headerStacksBeforeEitherSideCanBeClipped() {
        let axis = ResponsiveLayoutRules.headerAxis(
            availableWidth: 560,
            accessoryWidth: 230,
            minimumTitleWidth: 340,
            spacing: 18
        )

        #expect(axis == .vertical)
    }

    @Test func headerStaysHorizontalWhenBothSidesFit() {
        let axis = ResponsiveLayoutRules.headerAxis(
            availableWidth: 780,
            accessoryWidth: 230,
            minimumTitleWidth: 340,
            spacing: 18
        )

        #expect(axis == .horizontal)
    }

    @Test func actionRowsKeepEveryActionInSourceOrder() {
        let rows = ResponsiveLayoutRules.rows(
            availableWidth: 300,
            itemWidths: [118, 96, 82, 48],
            spacing: 10
        )

        #expect(rows == [[0, 1], [2, 3]])
        #expect(rows.flatMap { $0 } == [0, 1, 2, 3])
    }

    @Test func remainingHeightReservesSpaceForFixedContent() {
        let remaining = ResponsiveLayoutRules.remainingHeight(
            totalHeight: 520,
            fixedHeight: 76,
            spacing: 22
        )

        #expect(remaining == 422)
    }
}
