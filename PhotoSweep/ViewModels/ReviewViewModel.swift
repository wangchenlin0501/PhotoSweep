import Combine
import Foundation
import Photos
import SwiftData

private struct DeletionUndoEntry {
    let asset: PHAsset
    let index: Int
}

@MainActor
final class ReviewViewModel: ObservableObject {
    static let batchSize = 15

    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var batch: [PHAsset] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var pendingDeletionIdentifiers: [String] = []
    @Published private(set) var pendingDeletionAssets: [PHAsset] = []
    @Published private(set) var deletionReviewAssets: [PHAsset] = []
    @Published private(set) var originalBatchCount = 0
    @Published private(set) var visitedIdentifiers: Set<String> = []
    @Published private(set) var hasFinishedBatch = false
    @Published private(set) var accessibleCount = 0
    @Published private(set) var eligibleCount = 0
    @Published private(set) var nextEligibleDate: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statistics = StatisticsSnapshot()
    @Published private(set) var activityStatistics = CleanupActivitySnapshot()
    @Published private(set) var libraryOverview: PhotoLibraryOverview?
    @Published private(set) var isLoadingLibraryOverview = false
    @Published private(set) var reviewedHistoryCount = 0
    @Published private(set) var offlineAvailableCount = 0
    @Published private(set) var offlineCacheStatus = OfflineCacheSnapshot()

    private let photoLibrary: PhotoLibraryService
    private let offlineCache: OfflineCacheService
    private var modelContext: ModelContext?
    private var recordsByIdentifier: [String: ReviewRecord] = [:]
    private var statisticsRecord: CleanupStatistics?
    private var dailyRecords: [String: CleanupDayStatistics] = [:]
    private var deletionUndoStack: [DeletionUndoEntry] = []
    private var hasStarted = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        photoLibrary: PhotoLibraryService = .shared,
        offlineCache: OfflineCacheService? = nil
    ) {
        self.photoLibrary = photoLibrary
        let resolvedOfflineCache = offlineCache ?? .shared
        self.offlineCache = resolvedOfflineCache
        authorizationStatus = photoLibrary.authorizationStatus
        offlineCacheStatus = resolvedOfflineCache.snapshot

        resolvedOfflineCache.$snapshot
            .sink { [weak self] snapshot in
                self?.offlineCacheStatus = snapshot
                self?.refreshOfflineAvailableCount()
            }
            .store(in: &cancellables)
    }

    var hasReadAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var currentAsset: PHAsset? {
        guard batch.indices.contains(currentIndex) else { return nil }
        return batch[currentIndex]
    }

    var isBatchComplete: Bool {
        hasFinishedBatch
    }

    var reviewedCount: Int {
        visitedIdentifiers.count
    }

    var hasActiveBatch: Bool {
        hasReadAccess && !batch.isEmpty && !hasFinishedBatch
    }

    var canShowPrevious: Bool {
        currentIndex > 0
    }

    var canShowNext: Bool {
        currentIndex + 1 < batch.count
    }

    var canUndoDeletion: Bool {
        !deletionUndoStack.isEmpty
    }

    var hasOfflinePackage: Bool {
        offlineCacheStatus.cachedCount > 0
    }

    func configure(modelContext: ModelContext) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        loadStatistics()
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        authorizationStatus = photoLibrary.authorizationStatus
        if hasReadAccess {
            await loadBatch()
        }
    }

    func refreshAuthorization() {
        authorizationStatus = photoLibrary.authorizationStatus
        if hasReadAccess, batch.isEmpty, !isLoading {
            Task { await loadBatch() }
        }
    }

    func requestAccess() async {
        authorizationStatus = await photoLibrary.requestAuthorization()
        if hasReadAccess {
            await loadBatch()
        }
    }

    func loadBatch() async {
        guard hasReadAccess, let modelContext else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let records = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
            recordsByIdentifier = Dictionary(
                uniqueKeysWithValues: records.map { ($0.assetIdentifier, $0) }
            )
            reviewedHistoryCount = records.count
            let cooldowns = recordsByIdentifier.mapValues(\.eligibleAgainAt)
            let offlineIdentifiers = offlineCache.cachedIdentifiers
            let sample: PhotoSample
            if offlineIdentifiers.isEmpty {
                sample = await photoLibrary.randomEligibleSample(
                    cooldowns: cooldowns,
                    limit: Self.batchSize
                )
            } else {
                sample = await photoLibrary.randomEligibleSample(
                    from: offlineIdentifiers,
                    cooldowns: cooldowns,
                    limit: Self.batchSize
                )
            }

            batch = photoLibrary.assets(for: sample.identifiers)
            accessibleCount = sample.accessibleCount
            eligibleCount = sample.eligibleCount
            nextEligibleDate = sample.nextEligibleDate
            currentIndex = 0
            pendingDeletionIdentifiers = []
            pendingDeletionAssets = []
            deletionReviewAssets = []
            deletionUndoStack = []
            originalBatchCount = batch.count
            visitedIdentifiers = []
            hasFinishedBatch = false
            refreshOfflineAvailableCount()
            MediaPreloadService.shared.prepareBatch(batch)
            recordCurrentViewIfNeeded()
        } catch {
            errorMessage = "无法读取浏览记录：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func showPreviousAsset() -> Bool {
        guard canShowPrevious else { return false }
        currentIndex -= 1
        recordCurrentViewIfNeeded()
        return true
    }

    @discardableResult
    func showNextAsset() -> Bool {
        guard canShowNext else { return false }
        currentIndex += 1
        recordCurrentViewIfNeeded()
        return true
    }

    func finishBatch() {
        guard hasActiveBatch else { return }
        hasFinishedBatch = true
    }

    func markCurrentForDeletion() {
        guard let currentAsset else { return }
        guard recordCurrentViewIfNeeded() else { return }

        let deletedIndex = currentIndex
        let wasLastVisibleAsset = currentIndex == batch.count - 1

        if !pendingDeletionIdentifiers.contains(currentAsset.localIdentifier) {
            pendingDeletionIdentifiers.append(currentAsset.localIdentifier)
            pendingDeletionAssets.append(currentAsset)
            deletionReviewAssets.append(currentAsset)
            deletionUndoStack.append(
                DeletionUndoEntry(asset: currentAsset, index: deletedIndex)
            )
        }

        batch.remove(at: currentIndex)
        if batch.isEmpty || wasLastVisibleAsset {
            hasFinishedBatch = true
        } else {
            currentIndex = min(currentIndex, batch.count - 1)
            recordCurrentViewIfNeeded()
        }
    }

    func undoLastDeletion() {
        guard let entry = deletionUndoStack.popLast() else { return }

        pendingDeletionIdentifiers.removeAll {
            $0 == entry.asset.localIdentifier
        }
        pendingDeletionAssets.removeAll {
            $0.localIdentifier == entry.asset.localIdentifier
        }
        deletionReviewAssets.removeAll {
            $0.localIdentifier == entry.asset.localIdentifier
        }

        let insertionIndex = min(max(entry.index, 0), batch.count)
        batch.insert(entry.asset, at: insertionIndex)
        currentIndex = insertionIndex
        hasFinishedBatch = false
    }

    func isSelectedForDeletion(_ asset: PHAsset) -> Bool {
        pendingDeletionIdentifiers.contains(asset.localIdentifier)
    }

    func toggleDeletionSelection(for asset: PHAsset) {
        let identifier = asset.localIdentifier
        if isSelectedForDeletion(asset) {
            pendingDeletionIdentifiers.removeAll { $0 == identifier }
            pendingDeletionAssets.removeAll { $0.localIdentifier == identifier }
            deletionUndoStack.removeAll { $0.asset.localIdentifier == identifier }
        } else {
            pendingDeletionIdentifiers.append(identifier)
            pendingDeletionAssets.append(asset)
        }
    }

    func commitPendingDeletion() async {
        guard !pendingDeletionIdentifiers.isEmpty, let modelContext else { return }

        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        let identifiers = pendingDeletionIdentifiers
        let deletionMetrics = await photoLibrary.deletionMetrics(for: identifiers)
        do {
            try await photoLibrary.deleteAssets(with: identifiers)
        } catch {
            errorMessage = "没有删除任何项目。它们仍按已查看处理，一年内不会再次随机出现。\n\(error.localizedDescription)"
            return
        }

        offlineCache.removeCachedItems(with: identifiers)
        do {
            apply(deletionMetrics)
            for identifier in identifiers {
                if let record = recordsByIdentifier.removeValue(forKey: identifier) {
                    modelContext.delete(record)
                }
            }
            try modelContext.save()
            reviewedHistoryCount = recordsByIdentifier.count
            refreshOfflineAvailableCount()
            refreshStatisticsSnapshot()
            await loadBatch()
        } catch {
            modelContext.rollback()
            loadStatistics()
            errorMessage = "项目已经删除，但本地统计没有保存成功。\n\(error.localizedDescription)"
            await loadBatch()
        }
    }

    @discardableResult
    func deleteAssetsFromDay(_ assets: [PHAsset]) async -> Bool {
        guard !assets.isEmpty, let modelContext else { return false }

        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        let identifiers = assets.map(\.localIdentifier)
        let identifierSet = Set(identifiers)
        let deletionMetrics = await photoLibrary.deletionMetrics(for: identifiers)

        do {
            try await photoLibrary.deleteAssets(with: identifiers)
        } catch {
            errorMessage = "没有删除任何项目。\n" + error.localizedDescription
            return false
        }

        offlineCache.removeCachedItems(with: identifiers)

        do {
            apply(deletionMetrics)
            for identifier in identifiers {
                if let record = recordsByIdentifier.removeValue(forKey: identifier) {
                    modelContext.delete(record)
                }
            }

            pendingDeletionIdentifiers.removeAll { identifierSet.contains($0) }
            pendingDeletionAssets.removeAll {
                identifierSet.contains($0.localIdentifier)
            }
            deletionReviewAssets.removeAll {
                identifierSet.contains($0.localIdentifier)
            }
            deletionUndoStack.removeAll {
                identifierSet.contains($0.asset.localIdentifier)
            }

            let previousIndex = currentIndex
            batch.removeAll { identifierSet.contains($0.localIdentifier) }
            if batch.isEmpty {
                currentIndex = 0
                hasFinishedBatch = true
            } else {
                currentIndex = min(previousIndex, batch.count - 1)
                recordCurrentViewIfNeeded()
            }

            try modelContext.save()
            reviewedHistoryCount = recordsByIdentifier.count
            refreshOfflineAvailableCount()
            refreshStatisticsSnapshot()
            return true
        } catch {
            modelContext.rollback()
            loadStatistics()
            errorMessage = "项目已经删除，但本地统计没有保存成功。\n" + error.localizedDescription
            return true
        }
    }

    func changePendingDeletionToKeep() async {
        guard let modelContext else { return }

        do {
            let now = Date()
            for identifier in pendingDeletionIdentifiers {
                setCooldown(for: identifier, from: now)
            }
            try modelContext.save()
            await loadBatch()
        } catch {
            modelContext.rollback()
            errorMessage = "无法保存浏览记录：\(error.localizedDescription)"
        }
    }

    func refreshLibraryOverview() async {
        authorizationStatus = photoLibrary.authorizationStatus
        guard hasReadAccess else {
            libraryOverview = nil
            return
        }
        guard !isLoadingLibraryOverview else { return }
        isLoadingLibraryOverview = true
        defer { isLoadingLibraryOverview = false }
        let overview = await photoLibrary.libraryOverview()
        // Permission may have changed while metadata was being counted.
        authorizationStatus = photoLibrary.authorizationStatus
        libraryOverview = hasReadAccess ? overview : nil
    }

    func prepareOfflinePackage(limit: Int = 300) async {
        guard hasReadAccess, let modelContext else { return }

        do {
            let records = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
            recordsByIdentifier = Dictionary(
                uniqueKeysWithValues: records.map { ($0.assetIdentifier, $0) }
            )
            reviewedHistoryCount = records.count
            let sample = await photoLibrary.randomEligibleSample(
                cooldowns: recordsByIdentifier.mapValues(\.eligibleAgainAt),
                limit: limit,
                excluding: Set(batch.map(\.localIdentifier))
            )
            let assets = photoLibrary.assets(for: sample.identifiers)
            try await offlineCache.prepare(assets: assets)
            refreshOfflineAvailableCount()
        } catch {
            errorMessage = "提前加载没有完成。\n" + error.localizedDescription
        }
    }

    func resetReviewHistory() async {
        guard let modelContext else { return }

        do {
            let records = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
            for record in records {
                modelContext.delete(record)
            }
            try modelContext.save()
            recordsByIdentifier = [:]
            reviewedHistoryCount = 0
            nextEligibleDate = nil
            refreshOfflineAvailableCount()

            if batch.isEmpty, hasReadAccess {
                await loadBatch()
            }
        } catch {
            modelContext.rollback()
            errorMessage = "无法重置浏览记录。\n" + error.localizedDescription
        }
    }

    func clearOfflinePackage() async {
        offlineCache.clear()
        offlineAvailableCount = 0
        if batch.isEmpty, hasReadAccess {
            await loadBatch()
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func setCooldown(for identifier: String, from date: Date) {
        guard let modelContext else { return }
        let eligibleAgainAt = Calendar.autoupdatingCurrent.date(
            byAdding: .year,
            value: 1,
            to: date
        ) ?? date.addingTimeInterval(365 * 24 * 60 * 60)

        if let record = recordsByIdentifier[identifier] {
            record.reviewedAt = date
            record.eligibleAgainAt = eligibleAgainAt
        } else {
            let record = ReviewRecord(
                assetIdentifier: identifier,
                reviewedAt: date,
                eligibleAgainAt: eligibleAgainAt
            )
            modelContext.insert(record)
            recordsByIdentifier[identifier] = record
        }
    }

    @discardableResult
    private func recordCurrentViewIfNeeded() -> Bool {
        guard let currentAsset, let modelContext else { return false }
        let identifier = currentAsset.localIdentifier
        guard !visitedIdentifiers.contains(identifier) else { return true }

        do {
            setCooldown(for: identifier, from: Date())
            incrementViewedCount()
            try modelContext.save()
            visitedIdentifiers.insert(identifier)
            reviewedHistoryCount = recordsByIdentifier.count
            refreshOfflineAvailableCount()
            refreshStatisticsSnapshot()
            return true
        } catch {
            modelContext.rollback()
            loadStatistics()
            errorMessage = "无法保存查看记录：\(error.localizedDescription)"
            return false
        }
    }

    private func loadStatistics() {
        guard let modelContext else { return }
        do {
            var descriptor = FetchDescriptor<CleanupStatistics>()
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                statisticsRecord = existing
            } else {
                let newRecord = CleanupStatistics()
                modelContext.insert(newRecord)
                try modelContext.save()
                statisticsRecord = newRecord
            }
            let daily = try modelContext.fetch(FetchDescriptor<CleanupDayStatistics>())
            dailyRecords = Dictionary(uniqueKeysWithValues: daily.map { ($0.dayIdentifier, $0) })
            refreshStatisticsSnapshot()
        } catch {
            errorMessage = "无法读取统计数据：\(error.localizedDescription)"
        }
    }

    private func incrementViewedCount() {
        statisticsRecord?.viewedItemCount += 1
        statisticsRecord?.updatedAt = Date()
        dailyRecord()?.viewedCount += 1
    }

    private func dailyRecord(now: Date = Date()) -> CleanupDayStatistics? {
        guard let modelContext else { return nil }
        let identifier = CleanupActivitySnapshot.dayIdentifier(for: now)
        if let existing = dailyRecords[identifier] { return existing }
        let record = CleanupDayStatistics(dayIdentifier: identifier)
        modelContext.insert(record)
        dailyRecords[identifier] = record
        return record
    }

    private func apply(_ metrics: DeletionMetrics) {
        guard let statisticsRecord else { return }

        for metric in metrics.assets {
            switch metric.category {
            case .photo:
                statisticsRecord.deletedPhotoCount += 1
                statisticsRecord.deletedPhotoBytes += metric.byteCount ?? 0
            case .screenshot:
                statisticsRecord.deletedScreenshotCount += 1
                statisticsRecord.deletedScreenshotBytes += metric.byteCount ?? 0
            case .video:
                statisticsRecord.deletedVideoCount += 1
                statisticsRecord.deletedVideoBytes += metric.byteCount ?? 0
            }
            if metric.byteCount == nil {
                statisticsRecord.unmeasuredDeletedCount += 1
            }
        }
        statisticsRecord.updatedAt = Date()
        if !metrics.assets.isEmpty, let daily = dailyRecord() {
            daily.deletedCount += metrics.assets.count
            daily.deletedBytes += metrics.assets.reduce(Int64(0)) { $0 + ($1.byteCount ?? 0) }
        }
    }

    private func refreshStatisticsSnapshot() {
        guard let statisticsRecord else { return }
        statistics = StatisticsSnapshot(record: statisticsRecord)
        activityStatistics = CleanupActivitySnapshot(days: dailyRecords.values.map {
            CleanupDaySnapshot(
                id: $0.dayIdentifier,
                viewedCount: $0.viewedCount,
                deletedCount: $0.deletedCount,
                deletedBytes: $0.deletedBytes
            )
        }.sorted { $0.id < $1.id })
    }

    private func refreshOfflineAvailableCount(now: Date = Date()) {
        offlineAvailableCount = offlineCache.cachedIdentifiers.reduce(into: 0) {
            count, identifier in
            if let eligibleAgainAt = recordsByIdentifier[identifier]?.eligibleAgainAt,
               eligibleAgainAt > now {
                return
            }
            count += 1
        }
    }
}
