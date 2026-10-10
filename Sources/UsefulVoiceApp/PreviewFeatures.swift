import Foundation

/// Controls whose backend has not shipped yet stay hidden unless
/// `UV_PREVIEW_FEATURES=1`, so a release build never shows a dead control.
enum PreviewFeatures {
    static let enabled = ProcessInfo.processInfo.environment["UV_PREVIEW_FEATURES"] == "1"
}
