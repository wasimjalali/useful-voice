import Foundation

/// The pasteboard type the app puts on its own paste, so its clipboard snapshot can
/// tell the app's text from the user's. The previous identity used another type,
/// and a paste it left on the clipboard is still the app's.
public enum DeliveryMarker {
    public static let current = "ai.useful.voice.delivery"
    public static let legacy = IdentityMigration.Legacy.deliveryMarker

    /// True when a pasteboard item with these types is the app's own paste.
    public static func marks(types: [String]) -> Bool {
        types.contains(current) || types.contains(legacy)
    }
}
