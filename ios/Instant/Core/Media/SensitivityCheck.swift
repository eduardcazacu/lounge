#if canImport(UIKit)
import Foundation
import SensitiveContentAnalysis
import UIKit

/// Whether a photo should be hidden behind a warning before it is shown.
///
/// The server holds only ciphertext, so the one place an instant can be checked
/// for nudity is on the recipient's device, after decryption — which is exactly
/// what Apple's SensitiveContentAnalysis is for. Behind a protocol so tests can
/// say "this one is sensitive" without a real classifier.
public protocol SensitivityChecking: Sendable {
    func isSensitive(_ image: UIImage) async -> Bool
}

/// Apple's on-device classifier. Nothing leaves the device.
///
/// It only runs when the person has asked for it: Sensitive Content Warnings in
/// Settings, or Communication Safety on a child's device. Otherwise the policy
/// is `.disabled` and every photo is shown as sent — the system setting is the
/// user's choice, and the app does not second-guess it.
public struct SystemSensitivityChecker: SensitivityChecking {
    public init() {}

    public func isSensitive(_ image: UIImage) async -> Bool {
        let analyzer = SCSensitivityAnalyzer()
        guard analyzer.analysisPolicy != .disabled, let cgImage = image.cgImage else {
            return false
        }
        do {
            return try await analyzer.analyzeImage(cgImage).isSensitive
        } catch {
            // A classifier that failed has no opinion. Showing the photo is what
            // would have happened with the setting off.
            return false
        }
    }
}
#endif
