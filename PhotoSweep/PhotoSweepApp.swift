import SwiftData
import SwiftUI

@main
struct PhotoSweepApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([ReviewRecord.self, CleanupStatistics.self, CleanupDayStatistics.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("无法建立本地浏览记录数据库：\(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
