import Foundation
import SwiftData

// Standalone regression checks; uses a temporary store, never the app's data.
@main
struct StatisticsChecks {
    @MainActor
    static func main() throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "calculations"
        if mode != "calculations" {
            let url = URL(fileURLWithPath: CommandLine.arguments[2])
            try persistence(mode: mode, url: url)
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 9, 16)
        let empty = CleanupActivitySnapshot()
        assert(empty.recentDays(endingAt: now, calendar: calendar).count == 7)
        assert(empty.currentStreak(at: now, calendar: calendar) == 0)
        assert(empty.longestStreak(calendar: calendar) == 0)
        assert(empty.bestDeletionDay == nil)
        assert(empty.recentDays(endingAt: now, count: 0, calendar: calendar).isEmpty)
        let activity = CleanupActivitySnapshot(days: [
            .init(id: "2026-09-10", viewedCount: 15),
            .init(id: "2026-09-11", deletedCount: 4, deletedBytes: 400),
            .init(id: "2026-09-12", viewedCount: 30, deletedCount: 10, deletedBytes: 1_000),
            .init(id: "2026-09-14", viewedCount: 15),
            .init(id: "2026-09-15", deletedCount: 10, deletedBytes: 500)
        ])
        assert(activity.activeDayCount == 5)
        assert(activity.currentStreak(at: now, calendar: calendar) == 2) // Today is still available.
        assert(activity.currentStreak(at: date(2026, 9, 17), calendar: calendar) == 0)
        assert(activity.longestStreak(calendar: calendar) == 3)
        assert(activity.bestDeletionDay?.id == "2026-09-15") // Most recent tie.
        let week = activity.recentDays(endingAt: now, calendar: calendar)
        assert(week.first?.id == "2026-09-10" && week.last?.id == "2026-09-16")
        assert(week[3].viewedCount == 0 && week[3].deletedCount == 0)
        assert(week.reduce(0) { $0 + $1.viewedCount } == 60)
        assert(week.reduce(0) { $0 + $1.deletedCount } == 24)
        assert(week.reduce(Int64(0)) { $0 + $1.deletedBytes } == 1_900)
        let dst = CleanupActivitySnapshot(days: [
            .init(id: "2026-03-28", viewedCount: 1),
            .init(id: "2026-03-29", viewedCount: 1),
            .init(id: "2026-03-30", viewedCount: 1)
        ])
        assert(dst.longestStreak(calendar: calendar) == 3)
        assert(dst.currentStreak(at: date(2026, 3, 30), calendar: calendar) == 3)
        assert(dst.recentDays(endingAt: date(2026, 3, 30), calendar: calendar).suffix(3).map(\.id) == ["2026-03-28", "2026-03-29", "2026-03-30"])
        let yearBoundary = CleanupActivitySnapshot(days: [
            .init(id: "2025-12-31", viewedCount: 1), .init(id: "2026-01-01", viewedCount: 1)
        ])
        assert(yearBoundary.longestStreak(calendar: calendar) == 2)
        assert(yearBoundary.currentStreak(at: date(2026, 1, 1), calendar: calendar) == 2)
        assert(CleanupActivitySnapshot.dayIdentifier(for: date(2026, 9, 16, hour: 0), calendar: calendar) == "2026-09-16")
        let monthActivity = CleanupActivitySnapshot(days: [
            .init(id: "2026-08-17", deletedCount: 100), // Outside the last 30 days.
            .init(id: "2026-08-18", deletedCount: 2),   // First included day.
            .init(id: "2026-09-15", deletedCount: 3),
            .init(id: "2026-09-16", deletedCount: 4),
            .init(id: "2026-09-17", deletedCount: 200)  // Future records excluded.
        ])
        assert(empty.recentDeletionCount(endingAt: now, calendar: calendar) == 0)
        assert(monthActivity.recentDeletionCount(endingAt: now, calendar: calendar) == 9)
        let nextDayActivity = CleanupActivitySnapshot(days: monthActivity.days.filter { $0.id <= "2026-09-16" })
        assert(nextDayActivity.recentDeletionCount(endingAt: date(2026, 9, 17), calendar: calendar) == 7)
        let monthAcrossDST = CleanupActivitySnapshot(days: [
            .init(id: "2026-02-28", deletedCount: 100),
            .init(id: "2026-03-01", deletedCount: 2),
            .init(id: "2026-03-29", deletedCount: 3),
            .init(id: "2026-03-30", deletedCount: 4)
        ])
        assert(monthAcrossDST.recentDeletionCount(endingAt: date(2026, 3, 30), calendar: calendar) == 9)
        print("PASS: 30-day deletion window, inclusive today, expiry, future exclusion, DST")
        var stats = StatisticsSnapshot()
        assert(stats.averageMeasuredDeletedBytes == nil)
        stats.deletedPhotoCount = 4
        stats.deletedPhotoBytes = 900
        stats.unmeasuredDeletedCount = 1
        assert(stats.measuredDeletedCount == 3)
        assert(stats.averageMeasuredDeletedBytes == 300)
        stats.unmeasuredDeletedCount = 4
        assert(stats.averageMeasuredDeletedBytes == nil)
        print("PASS: empty state, zero-filled week, totals, streak gaps, ties, DST, year boundary, unknown-size averages")
    }

    @MainActor
    static func persistence(mode: String, url: URL) throws {
        let legacy = mode == "seed"
        let schema = legacy
            ? Schema([ReviewRecord.self, CleanupStatistics.self])
            : Schema([ReviewRecord.self, CleanupStatistics.self, CleanupDayStatistics.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        if legacy {
            let stats = CleanupStatistics()
            stats.viewedItemCount = 321
            stats.deletedPhotoCount = 17
            stats.deletedPhotoBytes = 2_400_000
            context.insert(stats)
            context.insert(ReviewRecord(assetIdentifier: "migration-fixture", reviewedAt: .now, eligibleAgainAt: .distantFuture))
            try context.save()
            print("PASS: seeded legacy schema")
        } else {
            let stats = try context.fetch(FetchDescriptor<CleanupStatistics>())
            assert(stats.count == 1 && stats[0].viewedItemCount == 321)
            assert(stats[0].deletedPhotoCount == 17 && stats[0].deletedPhotoBytes == 2_400_000)
            if mode == "migrate" {
                let oldReviews = try context.fetch(FetchDescriptor<ReviewRecord>())
                assert(oldReviews.count == 1)
                let priorDays = try context.fetch(FetchDescriptor<CleanupDayStatistics>())
                assert(priorDays.isEmpty) // No fabricated history.
                let day = CleanupDayStatistics(dayIdentifier: "2026-09-16")
                day.viewedCount = 15
                day.deletedCount = 3
                day.deletedBytes = 900
                context.insert(day)
                try context.save()
                // A failed save/action rollback leaves persisted counts unchanged.
                day.deletedCount += 8
                context.processPendingChanges()
                context.rollback()
                // Re-fetch after rollback: SwiftData may invalidate the old instance.
                let restoredDays = try context.fetch(FetchDescriptor<CleanupDayStatistics>())
                assert(restoredDays.count == 1 && restoredDays[0].deletedCount == 3)
                for review in oldReviews { context.delete(review) }
                try context.save()
                print("PASS: additive migration, old totals preserved, rollback and independent history reset")
            } else {
                let days = try context.fetch(FetchDescriptor<CleanupDayStatistics>())
                assert(days.count == 1 && days[0].viewedCount == 15 && days[0].deletedCount == 3)
                assert(days[0].deletedBytes == 900)
                let reviews = try context.fetch(FetchDescriptor<ReviewRecord>())
                assert(reviews.isEmpty)
                print("PASS: daily activity persists across reopening and cooldown reset")
            }
        }
    }
}
