import AVFoundation
import Photos
import UIKit

/// Maintains a rolling current/next batch window, including iCloud-backed media.
@MainActor
final class MediaPreloadService {
    static let shared = MediaPreloadService()

    private static let displayTargetSize = CGSize(width: 1600, height: 2000)

    private let manager = PHCachingImageManager()
    private let cachedImages = NSCache<NSString, UIImage>()
    private var cachedLivePhotos: [String: PHLivePhoto] = [:]
    private var cachedVideoAssets: [String: AVAsset] = [:]

    private struct Request {
        let id: PHImageRequestID
        let token: UUID
    }
    private var imageRequests: [String: Request] = [:]
    private var livePhotoRequests: [String: Request] = [:]
    private var videoRequests: [String: Request] = [:]

    private var imageCompletions: [String: [(UIImage?) -> Void]] = [:]
    private var livePhotoCompletions: [String: [(PHLivePhoto?) -> Void]] = [:]
    private var videoCompletions: [String: [(AVAsset?) -> Void]] = [:]

    private var activeAssets: [PHAsset] = []
    private var activeIdentifiers: Set<String> = []
    private init() {
        cachedImages.countLimit = 40
        cachedImages.totalCostLimit = 144 * 1024 * 1024
    }

    func prepareBatches(current: [PHAsset], next: [PHAsset]) {
        var seen: Set<String> = []
        let assets = (current + next).filter { seen.insert($0.localIdentifier).inserted }
        let identifiers = Set(assets.map(\.localIdentifier))
        let added = assets.filter { !activeIdentifiers.contains($0.localIdentifier) }
        let removed = activeAssets.filter { !identifiers.contains($0.localIdentifier) }

        if !removed.isEmpty {
            manager.stopCachingImages(
                for: removed,
                targetSize: Self.displayTargetSize,
                contentMode: .aspectFit,
                options: imageOptions()
            )
        }
        activeAssets = assets
        activeIdentifiers = identifiers
        discardRequestsOutsideWindow()
        for asset in removed {
            cachedImages.removeObject(forKey: asset.localIdentifier as NSString)
        }
        cachedLivePhotos = cachedLivePhotos.filter { identifiers.contains($0.key) }
        cachedVideoAssets = cachedVideoAssets.filter { identifiers.contains($0.key) }

        if !added.isEmpty {
            manager.startCachingImages(
                for: added,
                targetSize: Self.displayTargetSize,
                contentMode: .aspectFit,
                options: imageOptions()
            )
        }

        // Issue the current group's previews first, then the next group's.
        // Retained requests and display-ready results survive batch promotion.
        for asset in assets { loadImage(for: asset) { _ in } }
        for group in [current, next] {
            // Limit eager full-media downloads to the first two in each group.
            for asset in group.prefix(2) {
                if asset.mediaSubtypes.contains(.photoLive) {
                    loadLivePhoto(for: asset) { _ in }
                } else if asset.mediaType == .video {
                    loadVideoAsset(for: asset) { _ in }
                }
            }
        }
    }

    func loadImage(for asset: PHAsset, completion: @escaping (UIImage?) -> Void) {
        let identifier = asset.localIdentifier
        if let cachedImage = cachedImages.object(forKey: identifier as NSString) {
            completion(cachedImage)
            if imageRequests[identifier] == nil { return }
        }

        imageCompletions[identifier, default: []].append(completion)
        guard imageRequests[identifier] == nil else { return }
        let token = UUID()

        let requestID = manager.requestImage(
            for: asset,
            targetSize: Self.displayTargetSize,
            contentMode: .aspectFit,
            options: imageOptions()
        ) { [weak self] image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            Task { @MainActor in
                self?.finishImageRequest(
                    identifier: identifier,
                    image: image,
                    token: token,
                    isDegraded: isDegraded
                )
            }
        }
        imageRequests[identifier] = Request(id: requestID, token: token)
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
        let token = UUID()

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
                    token: token
                )
            }
        }
        livePhotoRequests[identifier] = Request(id: requestID, token: token)
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
        let token = UUID()

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
                    token: token
                )
            }
        }
        videoRequests[identifier] = Request(id: requestID, token: token)
    }

    private func imageOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }

    private func finishImageRequest(
        identifier: String,
        image: UIImage?,
        token: UUID,
        isDegraded: Bool
    ) {
        guard imageRequests[identifier]?.token == token else { return }
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height }
                ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cachedImages.setObject(image, forKey: identifier as NSString, cost: cost)
        }
        if isDegraded {
            if let image { imageCompletions[identifier]?.forEach { $0(image) } }
            return
        }
        imageRequests[identifier] = nil
        let completions = imageCompletions.removeValue(forKey: identifier) ?? []
        completions.forEach { $0(image) }
    }

    private func finishLivePhotoRequest(
        identifier: String,
        livePhoto: PHLivePhoto?,
        token: UUID
    ) {
        guard livePhotoRequests[identifier]?.token == token else { return }
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
        token: UUID
    ) {
        guard videoRequests[identifier]?.token == token else { return }
        videoRequests[identifier] = nil
        if activeIdentifiers.contains(identifier), let videoAsset {
            cachedVideoAssets[identifier] = videoAsset
        }
        let completions = videoCompletions.removeValue(forKey: identifier) ?? []
        completions.forEach { $0(videoAsset) }
    }

    private func discardRequestsOutsideWindow() {
        for identifier in Array(imageRequests.keys) where !activeIdentifiers.contains(identifier) {
            if let request = imageRequests.removeValue(forKey: identifier) {
                manager.cancelImageRequest(request.id)
            }
            cachedImages.removeObject(forKey: identifier as NSString)
            let completions = imageCompletions.removeValue(forKey: identifier) ?? []
            completions.forEach { $0(nil) }
        }
        for identifier in Array(livePhotoRequests.keys) where !activeIdentifiers.contains(identifier) {
            if let request = livePhotoRequests.removeValue(forKey: identifier) {
                manager.cancelImageRequest(request.id)
            }
            let completions = livePhotoCompletions.removeValue(forKey: identifier) ?? []
            completions.forEach { $0(nil) }
        }
        for identifier in Array(videoRequests.keys) where !activeIdentifiers.contains(identifier) {
            if let request = videoRequests.removeValue(forKey: identifier) {
                manager.cancelImageRequest(request.id)
            }
            let completions = videoCompletions.removeValue(forKey: identifier) ?? []
            completions.forEach { $0(nil) }
        }
    }
}
