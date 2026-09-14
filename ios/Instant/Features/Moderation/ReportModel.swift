#if canImport(UIKit)
import Foundation
import Observation
import UIKit

/// Reporting someone, optionally with the photo that prompted it.
@MainActor
@Observable
public final class ReportModel {
    public let reportedUserId: Int
    public let reportedName: String
    public let instantId: String?

    /// Nil until chosen: a report with a guessed-at reason is worse than none.
    public var reason: ReportReason?
    public var details = ""
    /// Off by default. Attaching the photo is the one way an instant leaves
    /// end-to-end encryption, so it has to be a choice rather than a default.
    public var includesPhoto = false
    public var alsoBlock = true

    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?

    /// The photo being looked at, when reporting from the viewer.
    private let photo: UIImage?
    private let api: ModerationAPIProtocol
    private let encodeEvidence: @Sendable (UIImage) throws -> Data

    public init(
        reportedUserId: Int,
        reportedName: String,
        instantId: String? = nil,
        photo: UIImage? = nil,
        api: ModerationAPIProtocol,
        encodeEvidence: @escaping @Sendable (UIImage) throws -> Data = ReportModel.encodeForModerators
    ) {
        self.reportedUserId = reportedUserId
        self.reportedName = reportedName
        self.instantId = instantId
        self.photo = photo
        self.api = api
        self.encodeEvidence = encodeEvidence
    }

    public var canAttachPhoto: Bool { photo != nil }

    public var canSubmit: Bool { reason != nil && !isSubmitting }

    /// Returns whether the report went through. On failure the sheet stays up
    /// with the reason and details intact, so nothing has to be typed twice.
    public func submit() async -> Bool {
        guard let reason, !isSubmitting else { return false }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        var evidence: Data?
        if includesPhoto, let photo {
            do {
                evidence = try encodeEvidence(photo)
            } catch {
                errorMessage = "Couldn't attach the photo. Turn off \"Include this photo\" to send the report without it."
                return false
            }
        }

        do {
            try await api.report(ReportDraft(
                reportedUserId: reportedUserId,
                instantId: instantId,
                reason: reason,
                details: details,
                alsoBlock: alsoBlock,
                evidence: evidence
            ))
            return true
        } catch let error as APIError {
            errorMessage = error.message
            return false
        } catch {
            errorMessage = "Couldn't send the report. Check your connection and try again."
            return false
        }
    }

    /// Big enough for a moderator to judge, small enough to sit well under the
    /// server's 3MB limit.
    public nonisolated static func encodeForModerators(_ image: UIImage) throws -> Data {
        try ImagePipeline.encode(
            image,
            options: EncodeOptions(
                maxWidth: 1080,
                maxHeight: 1920,
                targetBytes: 600_000,
                qualityLevels: [0.85, 0.75, 0.6],
                minLongEdge: 720
            )
        )
    }
}
#endif
