import Foundation
import Photos

struct PhotoSample: Sendable {
    let identifiers: [String]
    let accessibleCount: Int
    let eligibleCount: Int
    let nextEligibleDate: Date?
}

enum DeletedMediaCategory: Sendable {
    case photo
    case screenshot
    case video
}

struct AssetDeletionMetric: Sendable {
    let category: DeletedMediaCategory
    let byteCount: Int64?
}

struct DeletionMetrics: Sendable {
    let assets: [AssetDeletionMetric]
}

struct PhotoLibraryOverview: Equatable, Sendable {
    var photoCount = 0
    var screenshotCount = 0
    var videoCount = 0
    var totalCount: Int { photoCount + screenshotCount + videoCount }
}

final class PhotoLibraryService {
    static let shared = PhotoLibraryService()

    private init() {}

    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Count metadata only; do not download images or scan just the offline sample.
    func libraryOverview() async -> PhotoLibraryOverview {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.includeHiddenAssets = false
                options.includeAllBurstAssets = false
                options.predicate = NSPredicate(
                    format: "mediaType == %d OR mediaType == %d",
                    PHAssetMediaType.image.rawValue,
                    PHAssetMediaType.video.rawValue
                )
                let library = PHAssetCollection.fetchAssetCollections(
                    with: .smartAlbum,
                    subtype: .smartAlbumUserLibrary,
                    options: nil
                ).firstObject
                let assets: PHFetchResult<PHAsset>
                if let library {
                    // Use the system's main library, not a union of shared albums.
                    assets = PHAsset.fetchAssets(in: library, options: options)
                } else {
                    // Limited access may not expose the smart album itself.
                    options.includeAssetSourceTypes = .typeUserLibrary
                    assets = PHAsset.fetchAssets(with: options)
                }
                var overview = PhotoLibraryOverview()
                assets.enumerateObjects { asset, _, _ in
                    if asset.mediaType == .video {
                        overview.videoCount += 1
                    } else if asset.mediaSubtypes.contains(.photoScreenshot) {
                        overview.screenshotCount += 1
                    } else {
                        // Live Photos belong to photos; screenshots are exclusive.
                        overview.photoCount += 1
                    }
                }
                continuation.resume(returning: overview)
            }
        }
    }

    /// Uses reservoir sampling so a very large library does not need to be copied
    /// into memory merely to choose 15 random identifiers.
    func randomEligibleSample(
        cooldowns: [String: Date],
        limit: Int,
        excluding excludedIdentifiers: Set<String> = [],
        now: Date = Date()
    ) async -> PhotoSample {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.includeHiddenAssets = false

                let result = PHAsset.fetchAssets(with: options)
                var sample: [String] = []
                var accessibleCount = 0
                var eligibleCount = 0
                var nextEligibleDate: Date?

                result.enumerateObjects { asset, _, _ in
                    guard asset.mediaType == .image || asset.mediaType == .video else {
                        return
                    }

                    // Synced-from-computer and shared-album items are not reliably
                    // deletable. Main-library assets include normal photos, videos,
                    // screenshots, Live Photos, GIFs and screen recordings.
                    guard asset.sourceType.contains(.typeUserLibrary) else {
                        return
                    }

                    accessibleCount += 1
                    let identifier = asset.localIdentifier
                    guard !excludedIdentifiers.contains(identifier) else { return }

                    if let eligibleAgainAt = cooldowns[identifier], eligibleAgainAt > now {
                        if nextEligibleDate == nil || eligibleAgainAt < nextEligibleDate! {
                            nextEligibleDate = eligibleAgainAt
                        }
                        return
                    }

                    eligibleCount += 1
                    if sample.count < limit {
                        sample.append(identifier)
                    } else {
                        let replacementIndex = Int.random(in: 0..<eligibleCount)
                        if replacementIndex < limit {
                            sample[replacementIndex] = identifier
                        }
                    }
                }

                sample.shuffle()
                continuation.resume(
                    returning: PhotoSample(
                        identifiers: sample,
                        accessibleCount: accessibleCount,
                        eligibleCount: eligibleCount,
                        nextEligibleDate: nextEligibleDate
                    )
                )
            }
        }
    }

    /// Samples only from a prepared offline package. Missing assets are ignored,
    /// while the original package order is preserved only long enough to perform
    /// an unbiased reservoir sample.
    func randomEligibleSample(
        from identifiers: [String],
        cooldowns: [String: Date],
        limit: Int,
        now: Date = Date()
    ) async -> PhotoSample {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = PHAsset.fetchAssets(
                    withLocalIdentifiers: identifiers,
                    options: nil
                )
                var assetsByIdentifier: [String: PHAsset] = [:]
                result.enumerateObjects { asset, _, _ in
                    assetsByIdentifier[asset.localIdentifier] = asset
                }

                var sample: [String] = []
                var accessibleCount = 0
                var eligibleCount = 0
                var nextEligibleDate: Date?

                for identifier in identifiers {
                    guard let asset = assetsByIdentifier[identifier],
                          asset.mediaType == .image || asset.mediaType == .video else {
                        continue
                    }
                    accessibleCount += 1

                    if let eligibleAgainAt = cooldowns[identifier], eligibleAgainAt > now {
                        if nextEligibleDate == nil || eligibleAgainAt < nextEligibleDate! {
                            nextEligibleDate = eligibleAgainAt
                        }
                        continue
                    }

                    eligibleCount += 1
                    if sample.count < limit {
                        sample.append(identifier)
                    } else {
                        let replacementIndex = Int.random(in: 0..<eligibleCount)
                        if replacementIndex < limit {
                            sample[replacementIndex] = identifier
                        }
                    }
                }

                sample.shuffle()
                continuation.resume(
                    returning: PhotoSample(
                        identifiers: sample,
                        accessibleCount: accessibleCount,
                        eligibleCount: eligibleCount,
                        nextEligibleDate: nextEligibleDate
                    )
                )
            }
        }
    }

    func assets(for identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }
        return identifiers.compactMap { assetsByIdentifier[$0] }
    }

    func assets(createdOn date: Date) async -> [PHAsset] {
        let calendar = Calendar.autoupdatingCurrent
        let startDate = calendar.startOfDay(for: date)
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) else {
            return []
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.includeHiddenAssets = false
                options.predicate = NSPredicate(
                    format: "creationDate >= %@ AND creationDate < %@",
                    startDate as NSDate,
                    endDate as NSDate
                )
                options.sortDescriptors = [
                    NSSortDescriptor(key: "creationDate", ascending: true)
                ]

                let result = PHAsset.fetchAssets(with: options)
                var assets: [PHAsset] = []
                assets.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in
                    guard asset.mediaType == .image || asset.mediaType == .video,
                          asset.sourceType.contains(.typeUserLibrary) else {
                        return
                    }
                    assets.append(asset)
                }
                continuation.resume(returning: assets)
            }
        }
    }

    func deleteAssets(with identifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? PhotoLibraryError.deletionDidNotComplete
                    )
                }
            }
        }
    }

    /// Calculates the size before deletion, because a successful PhotoKit change
    /// makes the original assets unavailable to this app.
    func deletionMetrics(for identifiers: [String]) async -> DeletionMetrics {
        let selectedAssets = assets(for: identifiers)
        var metrics: [AssetDeletionMetric] = []
        metrics.reserveCapacity(selectedAssets.count)

        for asset in selectedAssets {
            let category: DeletedMediaCategory
            if asset.mediaType == .video {
                category = .video
            } else if asset.mediaSubtypes.contains(.photoScreenshot) {
                category = .screenshot
            } else {
                category = .photo
            }

            let byteCount = await resourceByteCount(for: asset)
            metrics.append(AssetDeletionMetric(category: category, byteCount: byteCount))
        }

        return DeletionMetrics(assets: metrics)
    }

    private func resourceByteCount(for asset: PHAsset) async -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset).filter {
            $0.type != .adjustmentData
        }
        guard !resources.isEmpty else { return nil }

        var total: Int64 = 0
        for resource in resources {
            if let streamedSize = await streamedByteCount(for: resource) {
                total += streamedSize
            } else {
                return nil
            }
        }
        return total
    }

    /// Public-API fallback for iOS versions where PhotoKit does not expose a
    /// resource size. Data arrives in chunks and is never retained in memory.
    private func streamedByteCount(for resource: PHAssetResource) async -> Int64? {
        await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            var byteCount: Int64 = 0

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options
            ) { data in
                byteCount += Int64(data.count)
            } completionHandler: { error in
                continuation.resume(returning: error == nil ? byteCount : nil)
            }
        }
    }
}

enum PhotoLibraryError: LocalizedError {
    case deletionDidNotComplete

    var errorDescription: String? {
        switch self {
        case .deletionDidNotComplete:
            return "删除没有完成，请稍后重试。"
        }
    }
}
