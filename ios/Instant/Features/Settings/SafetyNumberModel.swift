import Foundation
import Observation

@MainActor
@Observable
public final class SafetyNumberModel {
    public private(set) var safetyNumber: String?
    public private(set) var keysChanged = false
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let api: InstantAPIProtocol
    private let fingerprints: PeerFingerprintStoring
    private let currentUserId: Int
    private let peerUserId: Int

    public init(
        api: InstantAPIProtocol,
        fingerprints: PeerFingerprintStoring,
        currentUserId: Int,
        peerUserId: Int
    ) {
        self.api = api
        self.fingerprints = fingerprints
        self.currentUserId = currentUserId
        self.peerUserId = peerUserId
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let (theirs, mine) = try await api.keys(forUserId: peerUserId)
            guard !theirs.isEmpty else {
                errorMessage = "They haven't set up Instant yet."
                return
            }

            let theirKeys = theirs.map(\.publicKey)
            safetyNumber = SafetyNumber.safetyNumber(mine: mine.map(\.publicKey), theirs: theirKeys)

            let current = SafetyNumber.fingerprint(of: theirKeys)
            if let remembered = fingerprints.fingerprint(userId: currentUserId, peerUserId: peerUserId) {
                keysChanged = remembered != current
            }
            // Remember the new value either way: the warning is for this
            // sighting, and nagging about the same change forever is noise.
            fingerprints.remember(current, userId: currentUserId, peerUserId: peerUserId)
        } catch {
            errorMessage = "Could not load their keys."
        }
    }
}
