import SwiftUI

extension View {
    /// The one way a page sizes and places its content column.
    ///
    /// Every page used to write `.frame(maxWidth: 980, alignment: .topLeading)` followed by
    /// `.frame(maxWidth: .infinity, alignment: .topLeading)`. The first frame capped the
    /// content, the second pinned that capped block to the left edge of the stage, so a wider
    /// window grew empty space on the right instead of moving the content. Centring the
    /// capped column horizontally is what keeps the layout balanced at any window width.
    func pageColumn(maxWidth: CGFloat = 1000) -> some View {
        frame(maxWidth: maxWidth, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}
