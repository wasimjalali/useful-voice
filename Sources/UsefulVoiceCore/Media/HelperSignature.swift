import Foundation
import Security

/// Checks that the Now Playing library really is the one this app shipped before Apple's perl is
/// asked to load it: perl runs whatever library it is told to, with Apple's identity, so a
/// swapped file would be code running as `com.apple.perl`.
///
/// The library must carry a valid signature (strict, every architecture) made with the same
/// certificate as the app itself. An app that is signed ad hoc (a local development build, no
/// certificate) accepts a library that is also signed ad hoc and valid: there is no identity to
/// compare, and a release build is never signed that way.
enum HelperSignature {
    /// Nil when the library is trusted, otherwise why it is not.
    static func problem(with helper: URL) -> String? {
        var selfCode: SecCode?
        var appCode: SecStaticCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, SecCSFlags(), &appCode) == errSecSuccess, let appCode else {
            return "the app's own signature cannot be read"
        }
        var helperCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helper as CFURL, SecCSFlags(), &helperCode) == errSecSuccess,
              let helperCode else {
            return "the helper library cannot be read"
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures))
        let status = SecStaticCodeCheckValidity(helperCode, flags, nil)
        guard status == errSecSuccess else {
            return "the helper library's signature is not valid (OSStatus \(status))"
        }
        switch (leafCertificate(of: appCode), leafCertificate(of: helperCode)) {
        case (nil, nil):
            return nil   // both ad hoc
        case let (appLeaf?, helperLeaf?):
            return appLeaf == helperLeaf ? nil : "the helper library is signed by a different certificate than the app"
        default:
            return "the helper library and the app are not signed the same way"
        }
    }

    /// The certificate that signed the code, as its DER bytes. Nil for ad hoc signatures.
    private static func leafCertificate(of code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}
