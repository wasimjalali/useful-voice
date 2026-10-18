import Foundation

/// Finds the physical key that types a given letter in the current keyboard layout.
///
/// A synthetic Cmd-V must press the key that types "v" where the user's layout puts
/// it. Virtual key 9 is the physical ANSI V key: on Dvorak it types another letter,
/// so Cmd plus key 9 fires a different shortcut. The layout lookup itself
/// (UCKeyTranslate) lives in the app; this is the search over it.
public enum KeyCodeSearch {
    /// The lowest virtual key code in 0..<128 for which `translate` returns exactly
    /// `character` (compared case-insensitively), or nil when no key types it.
    public static func keyCode(producing character: Character,
                               translate: (UInt16) -> String?) -> UInt16? {
        let wanted = String(character).lowercased()
        for code in UInt16(0)..<128 {
            if translate(code)?.lowercased() == wanted { return code }
        }
        return nil
    }
}
