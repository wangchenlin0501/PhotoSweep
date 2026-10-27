import Foundation
import SwiftData

@main
struct BatchLoadingChecks {
    @MainActor
    static func main() async throws {
        let library = PhotoLibraryService.shared
        library.library = (0..<75).map { PHAsset("photo-\($0)") }
        let schema = Schema([ReviewRecord.self, CleanupStatistics.self, CleanupDayStatistics.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let offline = OfflineCacheService()
        let model = ReviewViewModel(photoLibrary: library, offlineCache: offline)
        model.configure(modelContext: context)
        await model.loadBatch()
        assert(library.requestedLimits.first == 30, "Startup must select two disjoint groups")
        assert(model.batch.count == 15)
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        assert(records.count == 1, "Prefetch must not record views")
        let manager = PHCachingImageManager.latest!
        assert(Set(manager.requests.map(\.identifier)).count == 30, "Both groups must start loading")
        print("PASS: two groups preload; only the visible item is recorded")

        let nextRequest = manager.requests.first { $0.identifier == "photo-15" }!
        let cachedImage = UIImage()
        manager.callbacks[nextRequest.id]?(cachedImage, nil)
        await settle()
        model.markCurrentForDeletion()
        model.undoLastDeletion()
        assert(model.currentAsset?.localIdentifier == "photo-0")
        for _ in 1..<15 { assert(model.showNextAsset()) }
        model.finishBatch()
        await model.loadBatch()
        await settle()
        assert(model.batch.map(\.localIdentifier) == (15..<30).map { "photo-\($0)" })
        assert(Set(manager.requests.map(\.identifier)) == Set((0..<45).map { "photo-\($0)" }))
        assert(manager.requests.filter { $0.identifier == "photo-15" }.count == 1)
        assert(!manager.cancelled.contains(nextRequest.id), "Promotion must retain next-group work")
        var reusedImage: UIImage?
        MediaPreloadService.shared.loadImage(for: library.library[15]) { reusedImage = $0 }
        assert(reusedImage === cachedImage, "Promotion must reuse a downloaded preview")
        let promotedRecords = try context.fetch(FetchDescriptor<ReviewRecord>())
        assert(promotedRecords.count == 16)
        print("PASS: next-group promotion reuses cache, refills a disjoint group, and supports undo")

        // A cancelled PhotoKit callback can still arrive after an identifier is
        // readmitted. It must not finish or overwrite the newer request.
        let service = MediaPreloadService.shared
        let staleAsset = PHAsset("stale")
        service.prepareBatches(current: [staleAsset], next: [])
        let oldRequest = manager.requests.last!
        service.prepareBatches(current: [], next: [])
        service.prepareBatches(current: [staleAsset], next: [])
        let newRequest = manager.requests.last!
        var received: UIImage?
        service.loadImage(for: staleAsset) { received = $0 }
        manager.callbacks[oldRequest.id]?(UIImage(), nil)
        await settle()
        assert(received == nil)
        manager.callbacks[newRequest.id]?(cachedImage, nil)
        await settle()
        assert(received === cachedImage)
        print("PASS: delayed callbacks from cancelled requests cannot overwrite newer work")

        // Rotate into group two while group three is waiting, then revoke access.
        service.prepareBatches(current: [], next: [])
        let permissionModel = makeModel(library: library)
        await permissionModel.loadBatch()
        library.pauseSampling = true
        await permissionModel.loadBatch()
        await settle()
        assert(library.samplingContinuation != nil)
        let requestCount = manager.requests.count
        library.authorizationStatus = .denied
        permissionModel.refreshAuthorization()
        library.pauseSampling = false
        library.samplingContinuation?.resume()
        library.samplingContinuation = nil
        await settle()
        assert(manager.requests.count == requestCount, "Revoked access must discard the in-flight next group")
        library.authorizationStatus = .authorized
        print("PASS: permission changes invalidate in-flight group selection")

        library.library = (0..<40).map { PHAsset("offline-\($0)") }
        let offlineCache = OfflineCacheService()
        offlineCache.cachedIdentifiers = library.library.prefix(30).map(\.localIdentifier)
        offlineCache.snapshot.cachedCount = 30
        let offlineModel = makeModel(library: library, offline: offlineCache)
        await offlineModel.loadBatch()
        let removedFromNext = library.library[15]
        let deleted = await offlineModel.deleteAssetsFromDay([removedFromNext])
        assert(deleted)
        for _ in 1..<15 { _ = offlineModel.showNextAsset() }
        offlineModel.finishBatch()
        await offlineModel.loadBatch()
        await settle()
        assert(offlineModel.batch.count == 14)
        assert(!offlineModel.batch.contains { $0.localIdentifier == removedFromNext.localIdentifier })
        assert(offlineModel.batch.allSatisfy { offlineCache.cachedIdentifiers.contains($0.localIdentifier) })
        print("PASS: offline groups remain disjoint and day-gallery deletions invalidate queued items")

        library.library = (0..<8).map { PHAsset("short-\($0)") }
        let shortModel = makeModel(library: library)
        await shortModel.loadBatch()
        await settle()
        assert(shortModel.batch.count == 8)
        for _ in 1..<8 { _ = shortModel.showNextAsset() }
        shortModel.finishBatch()
        await shortModel.loadBatch()
        assert(shortModel.batch.isEmpty)
        print("PASS: short and exhausted libraries do not duplicate reviewed items")

        library.library = (0..<40).map { PHAsset("overlap-\($0)") }
        library.pauseSampling = true
        let overlapModel = makeModel(library: library)
        let before = library.requestedLimits.count
        let firstLoad = Task { await overlapModel.loadBatch() }
        await settle()
        await overlapModel.loadBatch()
        assert(library.requestedLimits.count == before + 1, "Repeated taps must not race group selection")
        library.pauseSampling = false
        library.samplingContinuation?.resume()
        library.samplingContinuation = nil
        await firstLoad.value
        print("PASS: overlapping loads are coalesced")
    }

    @MainActor
    static func makeModel(library: PhotoLibraryService, offline: OfflineCacheService? = nil) -> ReviewViewModel {
        let schema = Schema([ReviewRecord.self, CleanupStatistics.self, CleanupDayStatistics.self])
        let container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let model = ReviewViewModel(photoLibrary: library, offlineCache: offline ?? OfflineCacheService())
        model.configure(modelContext: ModelContext(container))
        return model
    }

    @MainActor
    static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }
}
