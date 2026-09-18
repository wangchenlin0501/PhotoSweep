import Foundation
import SwiftData

@Model
final class CleanupStatistics {
    @Attribute(.unique) var recordIdentifier: String
    var viewedItemCount: Int
    var deletedPhotoCount: Int
    var deletedPhotoBytes: Int64
    var deletedScreenshotCount: Int
    var deletedScreenshotBytes: Int64
    var deletedVideoCount: Int
    var deletedVideoBytes: Int64
    var unmeasuredDeletedCount: Int
    var updatedAt: Date

    init(recordIdentifier: String = "lifetime") {
        self.recordIdentifier = recordIdentifier
        viewedItemCount = 0
        deletedPhotoCount = 0
        deletedPhotoBytes = 0
        deletedScreenshotCount = 0
        deletedScreenshotBytes = 0
        deletedVideoCount = 0
        deletedVideoBytes = 0
        unmeasuredDeletedCount = 0
        updatedAt = Date()
    }
}

struct StatisticsSnapshot: Equatable, Sendable {
    var viewedItemCount = 0
    var deletedPhotoCount = 0
    var deletedPhotoBytes: Int64 = 0
    var deletedScreenshotCount = 0
    var deletedScreenshotBytes: Int64 = 0
    var deletedVideoCount = 0
    var deletedVideoBytes: Int64 = 0
    var unmeasuredDeletedCount = 0

    var totalDeletedCount: Int {
        deletedPhotoCount + deletedScreenshotCount + deletedVideoCount
    }

    var totalDeletedBytes: Int64 {
        deletedPhotoBytes + deletedScreenshotBytes + deletedVideoBytes
    }

    init() {}

    init(record: CleanupStatistics) {
        viewedItemCount = record.viewedItemCount
        deletedPhotoCount = record.deletedPhotoCount
        deletedPhotoBytes = record.deletedPhotoBytes
        deletedScreenshotCount = record.deletedScreenshotCount
        deletedScreenshotBytes = record.deletedScreenshotBytes
        deletedVideoCount = record.deletedVideoCount
        deletedVideoBytes = record.deletedVideoBytes
        unmeasuredDeletedCount = record.unmeasuredDeletedCount
    }
}

/// Independent of ReviewRecord: resetting cooldowns must not erase activity.
@Model
final class CleanupDayStatistics {
    @Attribute(.unique) var dayIdentifier: String
    var viewedCount: Int
    var deletedCount: Int
    var deletedBytes: Int64

    init(dayIdentifier: String) {
        self.dayIdentifier = dayIdentifier
        viewedCount = 0
        deletedCount = 0
        deletedBytes = 0
    }
}

struct CleanupDaySnapshot: Identifiable, Equatable, Sendable {
    let id: String
    var viewedCount = 0
    var deletedCount = 0
    var deletedBytes: Int64 = 0
    var isActive: Bool { viewedCount > 0 || deletedCount > 0 }
}

struct CleanupActivitySnapshot: Equatable, Sendable {
    var days: [CleanupDaySnapshot] = []

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // Civil dates retain the day an action happened, including after travel.
    static func dayIdentifier(for date: Date, calendar: Calendar = CleanupActivitySnapshot.localCalendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func recentDays(endingAt date: Date, count: Int = 7, calendar: Calendar = CleanupActivitySnapshot.localCalendar) -> [CleanupDaySnapshot] {
        guard count > 0 else { return [] }
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0) })
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            let id = Self.dayIdentifier(for: day, calendar: calendar)
            return byDay[id] ?? CleanupDaySnapshot(id: id)
        }
    }

    /// Today and the preceding 29 civil days. Only persisted successful deletions
    /// are counted; old lifetime totals cannot be assigned an invented date.
    func recentDeletionCount(endingAt date: Date, calendar: Calendar = CleanupActivitySnapshot.localCalendar) -> Int {
        recentDays(endingAt: date, count: 30, calendar: calendar)
            .reduce(0) { $0 + $1.deletedCount }
    }

    var activeDayCount: Int { days.filter(\.isActive).count }
    var bestDeletionDay: CleanupDaySnapshot? {
        days.filter { $0.deletedCount > 0 }.max {
            $0.deletedCount == $1.deletedCount ? $0.id < $1.id : $0.deletedCount < $1.deletedCount
        }
    }

    func currentStreak(at now: Date, calendar: Calendar = CleanupActivitySnapshot.localCalendar) -> Int {
        let active = Set(days.filter(\.isActive).map(\.id))
        var day = calendar.startOfDay(for: now)
        // Yesterday's streak stays alive until the user has had today to act.
        if !active.contains(Self.dayIdentifier(for: day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while active.contains(Self.dayIdentifier(for: day, calendar: calendar)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    func longestStreak(calendar: Calendar = CleanupActivitySnapshot.localCalendar) -> Int {
        var longest = 0
        var run = 0
        var previous: Date?
        for item in days.filter(\.isActive).sorted(by: { $0.id < $1.id }) {
            let components = item.id.split(separator: "-").compactMap { Int($0) }
            guard components.count == 3,
                  let date = calendar.date(from: DateComponents(
                    year: components[0], month: components[1], day: components[2]
                  )) else { continue }
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return longest
    }
}

extension StatisticsSnapshot {
    var measuredDeletedCount: Int { max(0, totalDeletedCount - unmeasuredDeletedCount) }

    var averageMeasuredDeletedBytes: Int64? {
        guard measuredDeletedCount > 0 else { return nil }
        return totalDeletedBytes / Int64(measuredDeletedCount)
    }
}
