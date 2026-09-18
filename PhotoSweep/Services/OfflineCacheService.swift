import Combine
import Foundation
import Photos
import UIKit

struct OfflineCacheSnapshot: Equatable {
    var isPreparing = false
    var completedCount = 0
    var targetCount = 0
    var cachedCount = 0
    var failedCount = 0
    var createdAt: Date?

    var progress: Double {
        guard targetCount > 0 else { return 0 }
        return Double(completedCount) / Double(targetCount)
    }
}

private struct OfflineCacheEntry: Codable {
    let assetIdentifier: String
    let filename: String
}

private struct OfflineCacheManifest: Codable {
    let createdAt: Date
    var entries: [OfflineCacheEntry]
}

@MainActor
final class OfflineCacheService: ObservableObject {
    static let shared = OfflineCacheService()

    @Published private(set) var snapshot = OfflineCacheSnapshot()

    private static let previewTargetSize = CGSize(width: 1800, height: 2200)
    private static let manifestFilename = "manifest.json"

    private let manager = PHImageManager.default()
    private let packageDirectory: URL
    private let imageCache = NSCache<NSString, UIImage>()
    private var manifest: OfflineCacheManifest?

    private init() {
        let fileManager = FileManager.default
        let supportDirectory = (
            try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        ) ?? fileManager.temporaryDirectory
        packageDirectory = supportDirectory
            .appendingPathComponent("PhotoSweep", isDirectory: true)
            .appendingPathComponent("OfflinePackage", isDirectory: true)
        loadManifest()
    }

    var cachedIdentifiers: [String] {
        manifest?.entries.map(\.assetIdentifier) ?? []
    }

    func cachedImage(for identifier: String) -> UIImage? {
        let cacheKey = identifier as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        guard let entry = manifest?.entries.first(where: {
            $0.assetIdentifier == identifier
        }) else {
            return nil
        }

        let fileURL = packageDirectory.appendingPathComponent(entry.filename)
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    func prepare(assets: [PHAsset]) async throws {
        guard !snapshot.isPreparing else { return }
        guard !assets.isEmpty else {
            throw OfflineCacheError.noEligibleAssets
        }

        let previousSnapshot = snapshot
        let fileManager = FileManager.default
        let parentDirectory = packageDirectory.deletingLastPathComponent()
        let stagingDirectory = parentDirectory.appendingPathComponent(
            "OfflinePackage-Staging-" + UUID().uuidString,
            isDirectory: true
        )

        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )

        snapshot = OfflineCacheSnapshot(
            isPreparing: true,
            completedCount: 0,
            targetCount: assets.count,
            cachedCount: 0,
            failedCount: 0,
            createdAt: nil
        )

        do {
            var entries: [OfflineCacheEntry] = []
            var failedCount = 0

            for asset in assets {
                if let image = await requestPreview(for: asset),
                   let imageData = image.jpegData(compressionQuality: 0.88) {
                    let filename = UUID().uuidString + ".jpg"
                    let destination = stagingDirectory.appendingPathComponent(filename)
                    do {
                        try imageData.write(to: destination, options: .atomic)
                        entries.append(
                            OfflineCacheEntry(
                                assetIdentifier: asset.localIdentifier,
                                filename: filename
                            )
                        )
                    } catch {
                        failedCount += 1
                    }
                } else {
                    failedCount += 1
                }

                snapshot.completedCount += 1
                snapshot.cachedCount = entries.count
                snapshot.failedCount = failedCount
                await Task.yield()
            }

            guard !entries.isEmpty else {
                throw OfflineCacheError.noPreviewCouldBeLoaded
            }

            let newManifest = OfflineCacheManifest(
                createdAt: Date(),
                entries: entries
            )
            try writeManifest(newManifest, in: stagingDirectory)
            try install(stagingDirectory: stagingDirectory)

            manifest = newManifest
            imageCache.removeAllObjects()
            excludePackageFromBackup()
            snapshot = OfflineCacheSnapshot(
                isPreparing: false,
                completedCount: assets.count,
                targetCount: assets.count,
                cachedCount: entries.count,
                failedCount: failedCount,
                createdAt: newManifest.createdAt
            )
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            snapshot = previousSnapshot
            throw error
        }
    }

    func removeCachedItems(with identifiers: [String]) {
        guard var currentManifest = manifest else { return }
        let identifiersToRemove = Set(identifiers)
        let removedEntries = currentManifest.entries.filter {
            identifiersToRemove.contains($0.assetIdentifier)
        }
        currentManifest.entries.removeAll {
            identifiersToRemove.contains($0.assetIdentifier)
        }

        for entry in removedEntries {
            let fileURL = packageDirectory.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: fileURL)
            imageCache.removeObject(forKey: entry.assetIdentifier as NSString)
        }

        if currentManifest.entries.isEmpty {
            clear()
            return
        }

        do {
            try writeManifest(currentManifest, in: packageDirectory)
            manifest = currentManifest
            snapshot.cachedCount = currentManifest.entries.count
        } catch {
            // The preview files remain usable for this process. A later package
            // preparation repairs the manifest if the disk write failed.
        }
    }

    func clear() {
        guard !snapshot.isPreparing else { return }
        try? FileManager.default.removeItem(at: packageDirectory)
        manifest = nil
        imageCache.removeAllObjects()
        snapshot = OfflineCacheSnapshot()
    }

    private func requestPreview(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.version = .current
            options.isNetworkAccessAllowed = true

            manager.requestImage(
                for: asset,
                targetSize: Self.previewTargetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }

    private func loadManifest() {
        let manifestURL = packageDirectory
            .appendingPathComponent(Self.manifestFilename)
        guard let data = try? Data(contentsOf: manifestURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode(OfflineCacheManifest.self, from: data) else {
            return
        }

        decoded.entries.removeAll { entry in
            let fileURL = packageDirectory.appendingPathComponent(entry.filename)
            return !FileManager.default.fileExists(atPath: fileURL.path)
        }
        guard !decoded.entries.isEmpty else {
            clear()
            return
        }

        manifest = decoded
        snapshot = OfflineCacheSnapshot(
            isPreparing: false,
            completedCount: decoded.entries.count,
            targetCount: decoded.entries.count,
            cachedCount: decoded.entries.count,
            failedCount: 0,
            createdAt: decoded.createdAt
        )
    }

    private func writeManifest(
        _ manifest: OfflineCacheManifest,
        in directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(
            to: directory.appendingPathComponent(Self.manifestFilename),
            options: .atomic
        )
    }

    private func install(stagingDirectory: URL) throws {
        let fileManager = FileManager.default
        let backupDirectory = packageDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                "OfflinePackage-Backup-" + UUID().uuidString,
                isDirectory: true
            )
        let hadExistingPackage = fileManager.fileExists(atPath: packageDirectory.path)

        if hadExistingPackage {
            try fileManager.moveItem(at: packageDirectory, to: backupDirectory)
        }

        do {
            try fileManager.moveItem(at: stagingDirectory, to: packageDirectory)
            if hadExistingPackage {
                try? fileManager.removeItem(at: backupDirectory)
            }
        } catch {
            if hadExistingPackage,
               !fileManager.fileExists(atPath: packageDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: packageDirectory)
            }
            throw error
        }
    }

    private func excludePackageFromBackup() {
        var packageURL = packageDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? packageURL.setResourceValues(values)
    }
}

enum OfflineCacheError: LocalizedError {
    case noEligibleAssets
    case noPreviewCouldBeLoaded

    var errorDescription: String? {
        switch self {
        case .noEligibleAssets:
            return "没有尚未浏览的项目可以提前加载。"
        case .noPreviewCouldBeLoaded:
            return "没有成功下载任何预览，请检查网络和 iCloud 相册状态。"
        }
    }
}
