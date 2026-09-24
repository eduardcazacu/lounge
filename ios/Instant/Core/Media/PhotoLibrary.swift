#if canImport(UIKit)
import Foundation
import Photos
import Synchronization
import UIKit

/// A composed capture on its way to the person's own library: the picture or
/// the clip exactly as it would be sent, with the look, the drawing and the
/// captions already in the pixels.
public enum SavedMedia: Sendable, Equatable {
    case photo(UIImage)
    /// The encoded file, which is the same HEVC the recipient would get.
    case video(Data)
}

/// Behind a protocol, like every other seam the models talk to: a test must
/// not need a photo library, and a UI test must not need permission for one.
public protocol PhotoLibraryWriting: Sendable {
    func save(_ media: SavedMedia) async throws
}

public enum PhotoLibraryError: Error, Equatable {
    /// Permission was refused, or has been turned off since.
    case refused
    case failed
}

/// The real library, asked for **add-only** permission.
///
/// Add-only is the whole of what saving needs, and it is the one kind of
/// access that does not let the app read a single photo the person has not
/// handed it. The library it already reads — the picker on a phone with no
/// camera — needs no permission at all.
public struct SystemPhotoLibrary: PhotoLibraryWriting {
    public init() {}

    public func save(_ media: SavedMedia) async throws {
        guard await Self.permitted() else { throw PhotoLibraryError.refused }
        do {
            switch media {
            case .photo(let image):
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            case .video(let data):
                // Photos takes a video as a file, so the encoded bytes go
                // back to the scratch directory for as long as the save
                // takes — the same directory, and the same rules, as every
                // other clip the app writes.
                let url = CaptureScratch.newURL(pathExtension: "mp4")
                defer { CaptureScratch.remove(url) }
                try data.write(to: url)
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: url, options: nil)
                }
            }
        } catch {
            throw PhotoLibraryError.failed
        }
    }

    private static func permitted() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let asked = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return asked == .authorized || asked == .limited
        default:
            return false
        }
    }
}

/// Keeps what it was asked to save, for tests and for the stubbed UI-test
/// launches — where a permission prompt nobody can tap would hang the run.
public final class StubPhotoLibrary: PhotoLibraryWriting {
    private let stored = Mutex<[SavedMedia]>([])
    /// Set to have every save fail, as a refused library does.
    private let refusal: (any Error)?

    public init(error: (any Error)? = nil) {
        refusal = error
    }

    public var saved: [SavedMedia] {
        stored.withLock { $0 }
    }

    public func save(_ media: SavedMedia) async throws {
        if let refusal { throw refusal }
        stored.withLock { $0.append(media) }
    }
}
#endif
