import AVFoundation
import Photos
import UIKit

/// Preloads the currently selected batch, including iCloud-backed media, and
/// keeps display-ready results in memory until the next batch begins.
@MainActor
final class MediaPreloadService {
    static let shared = MediaPreloadService()

    private static let displayTargetSize = CGSize(width: 1600, height: 2000)

    private let manager = PHCachingImageManager()
    private var cachedImages: [String: UIImage] = [:]
    private var cachedLivePhotos: [String: PHLivePhoto] = [:]
    private var cachedVideoAssets: [String: AVAsset] = [:]

    private var imageRequests: [String: PHImageRequestID] = [:]
    private var livePhotoRequests: [String: PHImageRequestID] = [:]
    private var videoRequests: [String: PHImageRequestID] = [:]

    private var imageCompletions: [String: [(UIImage?) -> Void]] = [:]
    private var livePhotoCompletions: [String: [(PHLivePhoto?) -> Void]] = [:]
    private var videoCompletions: [String: [(AVAsset?) -> Void]] = [:]

    private var activeAssets: [PHAsset] = []
    private var activeIdentifiers: Set<String> = []
    private var batchGeneration = 0

    private init() {}

    func prepareBatch(_ assets: [PHAsset]) {
        batchGeneration &+= 1
        stopCurrentBatch()

        activeAssets = assets
        activeIdentifiers = Set(assets.map(\.localIdentifier))
        guard !assets.isEmpty else { return }

        manager.startCachingImages(
            for: assets,
            targetSize: Self.displayTargetSize,
            contentMode: .aspectFit,
            options: imageOptions()
        )

        // Requests are issued in browsing order, so PhotoKit can begin with the
        // next items while still scheduling the remainder of the 15-item batch.
        for asset in assets {
            loadImage(for: asset) { _ in }

            if asset.mediaSubtypes.contains(.photoLive) {
                loadLivePhoto(for: asset) { _ in }
            } else if asset.mediaType == .video {
                loadVideoAsset(for: asset) { _ in }
            }
        }
    }

    func loadImage(for asset: PHAsset, completion: @escaping (UIImage?) -> Void) {
        let identifier = asset.localIdentifier
        if let cachedImage = cachedImages[identifier] {
            completion(cachedImage)
            return
        }

        imageCompletions[identifier, default: []].append(completion)
        guard imageRequests[identifier] == nil else { return }
        let requestGeneration = batchGeneration

        let requestID = manager.requestImage(
            for: asset,
            targetSize: Self.displayTargetSize,
            contentMode: .aspectFit,
            options: imageOptions()
        ) { [weak self] image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !isDegraded else { return }

            Task { @MainActor in
                self?.finishImageRequest(
                    identifier: identifier,
                    image: image,
                    generation: requestGeneration
                )
            }
        }
        imageRequests[identifier] = requestID
    }

    func loadLivePhoto(
        for asset: PHAsset,
        completion: @escaping (PHLivePhoto?) -> Void
    ) {
        let identifier = asset.localIdentifier
        if let cachedLivePhoto = cachedLivePhotos[identifier] {
            completion(cachedLivePhoto)
            return
        }

        livePhotoCompletions[identifier, default: []].append(completion)
        guard livePhotoRequests[identifier] == nil else { return }
        let requestGeneration = batchGeneration

        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        let requestID = manager.requestLivePhoto(
            for: asset,
            targetSize: Self.displayTargetSize,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] livePhoto, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !isDegraded else { return }

            Task { @MainActor in
                self?.finishLivePhotoRequest(
                    identifier: identifier,
                    livePhoto: livePhoto,
                    generation: requestGeneration
                )
            }
        }
        livePhotoRequests[identifier] = requestID
    }

    func loadVideoAsset(
        for asset: PHAsset,
        completion: @escaping (AVAsset?) -> Void
    ) {
        let identifier = asset.localIdentifier
        if let cachedVideoAsset = cachedVideoAssets[identifier] {
            completion(cachedVideoAsset)
            return
        }

        videoCompletions[identifier, default: []].append(completion)
        guard videoRequests[identifier] == nil else { return }
        let requestGeneration = batchGeneration

        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = true

        let requestID = manager.requestAVAsset(
            forVideo: asset,
            options: options
        ) { [weak self] videoAsset, _, _ in
            Task { @MainActor in
                self?.finishVideoRequest(
                    identifier: identifier,
                    videoAsset: videoAsset,
                    generation: requestGeneration
                )
            }
        }
        videoRequests[identifier] = requestID
    }

    private func imageOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }

    private func finishImageRequest(
        identifier: String,
        image: UIImage?,
        generation: Int
    ) {
        guard generation == batchGeneration else { return }
        imageRequests[identifier] = nil
        if activeIdentifiers.contains(identifier), let image {
            cachedImages[identifier] = image
        }
        let completions = imageCompletions.removeValue(forKey: identifier) ?? []
        completions.forEach { $0(image) }
    }

    private func finishLivePhotoRequest(
        identifier: String,
        livePhoto: PHLivePhoto?,
        generation: Int
    ) {
        guard generation == batchGeneration else { return }
        livePhotoRequests[identifier] = nil
        if activeIdentifiers.contains(identifier), let livePhoto {
            cachedLivePhotos[identifier] = livePhoto
        }
        let completions = livePhotoCompletions.removeValue(forKey: identifier) ?? []
        completions.forEach { $0(livePhoto) }
    }

    private func finishVideoRequest(
        identifier: String,
        videoAsset: AVAsset?,
        generation: Int
    ) {
        guard generation == batchGeneration else { return }
        videoRequests[identifier] = nil
        if activeIdentifiers.contains(identifier), let videoAsset {
            cachedVideoAssets[identifier] = videoAsset
        }
        let completions = videoCompletions.removeValue(forKey: identifier) ?? []
        completions.forEach { $0(videoAsset) }
    }

    private func stopCurrentBatch() {
        if !activeAssets.isEmpty {
            manager.stopCachingImages(
                for: activeAssets,
                targetSize: Self.displayTargetSize,
                contentMode: .aspectFit,
                options: imageOptions()
            )
        }

        for requestID in imageRequests.values {
            manager.cancelImageRequest(requestID)
        }
        for requestID in livePhotoRequests.values {
            manager.cancelImageRequest(requestID)
        }
        for requestID in videoRequests.values {
            manager.cancelImageRequest(requestID)
        }

        activeAssets = []
        activeIdentifiers = []
        cachedImages = [:]
        cachedLivePhotos = [:]
        cachedVideoAssets = [:]
        imageRequests = [:]
        livePhotoRequests = [:]
        videoRequests = [:]
        imageCompletions = [:]
        livePhotoCompletions = [:]
        videoCompletions = [:]
    }
}
