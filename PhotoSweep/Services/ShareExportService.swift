import Foundation
import Photos

struct ShareExport: Identifiable {
    let id = UUID()
    let fileURLs: [URL]
    let temporaryDirectory: URL
}

@MainActor
final class ShareExportService {
    static let shared = ShareExportService()

    private init() {}

    func export(_ asset: PHAsset) async throws -> ShareExport {
        let resources = resourcesForSharing(asset)
        guard !resources.isEmpty else {
            throw ShareExportError.noShareableResource
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PhotoSweepShare-" + UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        do {
            var fileURLs: [URL] = []
            for (index, resource) in resources.enumerated() {
                let originalName = URL(fileURLWithPath: resource.originalFilename)
                    .lastPathComponent
                let fallbackName = asset.mediaType == .video ? "Video.mov" : "Photo.heic"
                let filename = String(
                    format: "%02d-%@",
                    index + 1,
                    originalName.isEmpty ? fallbackName : originalName
                )
                let destination = directory.appendingPathComponent(filename)
                try await write(resource, to: destination)
                fileURLs.append(destination)
            }

            return ShareExport(
                fileURLs: fileURLs,
                temporaryDirectory: directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func removeTemporaryFiles(at directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func resourcesForSharing(_ asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)

        if asset.mediaType == .video {
            if let video = firstResource(
                in: resources,
                matching: [.fullSizeVideo, .video, .adjustmentBaseVideo]
            ) {
                return [video]
            }
        } else {
            var selected: [PHAssetResource] = []
            if let photo = firstResource(
                in: resources,
                matching: [.fullSizePhoto, .photo, .alternatePhoto, .adjustmentBasePhoto, .photoProxy]
            ) {
                selected.append(photo)
            }

            if asset.mediaSubtypes.contains(.photoLive),
               let pairedVideo = firstResource(
                   in: resources,
                   matching: [.fullSizePairedVideo, .pairedVideo, .adjustmentBasePairedVideo]
               ) {
                selected.append(pairedVideo)
            }

            if !selected.isEmpty {
                return selected
            }
        }

        return resources.first(where: { $0.type != .adjustmentData }).map { [$0] } ?? []
    }

    private func firstResource(
        in resources: [PHAssetResource],
        matching preferredTypes: [PHAssetResourceType]
    ) -> PHAssetResource? {
        for type in preferredTypes {
            if let resource = resources.first(where: { $0.type == type }) {
                return resource
            }
        }
        return nil
    }

    private func write(_ resource: PHAssetResource, to destination: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum ShareExportError: LocalizedError {
    case noShareableResource

    var errorDescription: String? {
        switch self {
        case .noShareableResource:
            return "这个项目没有可分享的文件。"
        }
    }
}
