import Combine
import Foundation

enum PHAuthorizationStatus { case notDetermined, denied, restricted, authorized, limited }
enum PHAssetMediaType { case image, video }
struct PHAssetMediaSubtype: OptionSet {
    let rawValue: Int
    static let photoLive = Self(rawValue: 1)
}
final class PHAsset {
    let localIdentifier: String
    let mediaType: PHAssetMediaType
    let mediaSubtypes: PHAssetMediaSubtype
    init(_ id: String, type: PHAssetMediaType = .image, subtypes: PHAssetMediaSubtype = []) {
        localIdentifier = id
        mediaType = type
        mediaSubtypes = subtypes
    }
}
final class UIImage: NSObject {
    var cgImage: StubCGImage? { StubCGImage() }
    let size = CGSize(width: 10, height: 10)
    let scale: CGFloat = 1
}
struct StubCGImage { let bytesPerRow = 40; let height = 10 }
final class PHLivePhoto {}
final class AVAsset {}
typealias PHImageRequestID = Int32
let PHImageResultIsDegradedKey = "degraded"
enum StubDeliveryMode { case opportunistic, highQualityFormat, automatic }
enum StubResizeMode { case fast }
enum StubContentMode { case aspectFit }
class PHImageRequestOptions {
    var deliveryMode = StubDeliveryMode.opportunistic
    var resizeMode = StubResizeMode.fast
    var isNetworkAccessAllowed = false
}
final class PHLivePhotoRequestOptions: PHImageRequestOptions {}
final class PHVideoRequestOptions: PHImageRequestOptions {}

final class PHCachingImageManager {
    static var latest: PHCachingImageManager!
    var requests: [(id: PHImageRequestID, identifier: String)] = []
    var cancelled: Set<PHImageRequestID> = []
    var callbacks: [PHImageRequestID: (UIImage?, [String: Any]?) -> Void] = [:]
    private var nextID: PHImageRequestID = 0
    init() { Self.latest = self }
    func startCachingImages(for: [PHAsset], targetSize: CGSize, contentMode: StubContentMode, options: PHImageRequestOptions) {}
    func stopCachingImages(for: [PHAsset], targetSize: CGSize, contentMode: StubContentMode, options: PHImageRequestOptions) {}
    func cancelImageRequest(_ id: PHImageRequestID) { cancelled.insert(id) }
    func requestImage(for asset: PHAsset, targetSize: CGSize, contentMode: StubContentMode, options: PHImageRequestOptions, resultHandler: @escaping (UIImage?, [String: Any]?) -> Void) -> PHImageRequestID {
        nextID += 1
        requests.append((nextID, asset.localIdentifier))
        callbacks[nextID] = resultHandler
        return nextID
    }
    func requestLivePhoto(for: PHAsset, targetSize: CGSize, contentMode: StubContentMode, options: PHLivePhotoRequestOptions, resultHandler: @escaping (PHLivePhoto?, [String: Any]?) -> Void) -> PHImageRequestID {
        nextID += 1; return nextID
    }
    func requestAVAsset(forVideo: PHAsset, options: PHVideoRequestOptions, resultHandler: @escaping (AVAsset?, Any?, [String: Any]?) -> Void) -> PHImageRequestID {
        nextID += 1; return nextID
    }
}

final class PhotoLibraryService {
    static let shared = PhotoLibraryService()
    var authorizationStatus = PHAuthorizationStatus.authorized
    var library: [PHAsset] = []
    var requestedLimits: [Int] = []
    var pauseSampling = false
    var samplingContinuation: CheckedContinuation<Void, Never>?
    func requestAuthorization() async -> PHAuthorizationStatus { authorizationStatus }
    func libraryOverview() async -> PhotoLibraryOverview { .init() }
    func randomEligibleSample(cooldowns: [String: Date], limit: Int, excluding: Set<String> = [], now: Date = Date()) async -> PhotoSample {
        await sample(library, cooldowns: cooldowns, limit: limit, excluding: excluding, now: now)
    }
    func randomEligibleSample(from identifiers: [String], cooldowns: [String: Date], limit: Int, excluding: Set<String> = [], now: Date = Date()) async -> PhotoSample {
        await sample(assets(for: identifiers), cooldowns: cooldowns, limit: limit, excluding: excluding, now: now)
    }
    private func sample(_ assets: [PHAsset], cooldowns: [String: Date], limit: Int, excluding: Set<String>, now: Date) async -> PhotoSample {
        requestedLimits.append(limit)
        if pauseSampling {
            await withCheckedContinuation { samplingContinuation = $0 }
        }
        let eligible = assets.filter { !excluding.contains($0.localIdentifier) && (cooldowns[$0.localIdentifier] ?? .distantPast) <= now }
        return PhotoSample(identifiers: eligible.prefix(limit).map(\.localIdentifier), accessibleCount: assets.count, eligibleCount: eligible.count, nextEligibleDate: nil)
    }
    func assets(for identifiers: [String]) -> [PHAsset] {
        identifiers.compactMap { identifier in library.first { $0.localIdentifier == identifier } }
    }
    func prepareDeletionSize(for: PHAsset) {}
    func deletionMetrics(for identifiers: [String]) async -> DeletionMetrics { .init(assets: []) }
    func deleteAssets(with identifiers: [String]) async throws {
        library.removeAll { identifiers.contains($0.localIdentifier) }
    }
}

@MainActor
final class OfflineCacheService: ObservableObject {
    static let shared = OfflineCacheService()
    @Published var snapshot = OfflineCacheSnapshot()
    var cachedIdentifiers: [String] = []
    func prepare(assets: [PHAsset]) async throws {
        cachedIdentifiers = assets.map(\.localIdentifier)
        snapshot.cachedCount = cachedIdentifiers.count
    }
    func removeCachedItems(with identifiers: [String]) {
        cachedIdentifiers.removeAll { identifiers.contains($0) }
        snapshot.cachedCount = cachedIdentifiers.count
    }
    func clear() { cachedIdentifiers = []; snapshot = .init() }
}
