import Charts
import Foundation
import SwiftUI

struct StatisticsView: View {
    @ObservedObject var viewModel: ReviewViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingResetConfirmation = false
    @State private var isShowingClearOfflineConfirmation = false
    @State private var selectedTrendDay: String?

    private var statistics: StatisticsSnapshot {
        viewModel.statistics
    }

    private var activity: CleanupActivitySnapshot { viewModel.activityStatistics }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        todaySummary(now: context.date)
                    }
                    librarySummary
                    cleanupSummary
                    mediaBreakdown
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(spacing: 16) {
                            weeklyTrend(now: context.date)
                            habits(now: context.date)
                        }
                    }
                    offlinePackage
                    reviewHistory
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .task { await viewModel.refreshLibraryOverview() }
        .refreshable { await viewModel.refreshLibraryOverview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.refreshLibraryOverview() }
            }
        }
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.large)
        .alert(
            "重置所有已浏览项目？",
            isPresented: $isShowingResetConfirmation
        ) {
            Button("确认重置", role: .destructive) {
                Task { await viewModel.resetReviewHistory() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些项目会重新进入随机范围；累计查看和删除统计不会被清除。")
        }
        .alert(
            "清除离线照片包？",
            isPresented: $isShowingClearOfflineConfirmation
        ) {
            Button("确认清除", role: .destructive) {
                Task { await viewModel.clearOfflinePackage() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除本 App 保存的离线预览，不会删除系统相册项目。")
        }
    }

    private var librarySummary: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            statisticsCard {
                HStack {
                    Label("相册概览", systemImage: "photo.stack.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)
                    Spacer()
                    if viewModel.isLoadingLibraryOverview { ProgressView() }
                }
                if let overview = viewModel.libraryOverview {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(overview.totalCount.formatted())
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(viewModel.authorizationStatus == .limited ? "个项目 · 部分访问" : "个照片与视频")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    libraryComposition(overview)
                } else {
                    Text(viewModel.isLoadingLibraryOverview ? "正在统计相册…" : "允许访问相册后可查看数量")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                    Text("最近删除").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(activity.recentDeletionCount(endingAt: context.date).formatted())
                        .font(.title2.bold().monospacedDigit())
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func libraryComposition(_ overview: PhotoLibraryOverview) -> some View {
        let categories: [(title: String, count: Int, color: Color)] = [
            ("照片", overview.photoCount, .blue),
            ("截图", overview.screenshotCount, .orange),
            ("视频", overview.videoCount, .purple)
        ]
        return VStack(spacing: 10) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(categories, id: \.title) { category in
                        category.color
                            .frame(width: proxy.size.width * CGFloat(category.count) / CGFloat(max(overview.totalCount, 1)))
                    }
                }
                .frame(width: proxy.size.width, alignment: .leading)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .accessibilityHidden(true)

            HStack(alignment: .top, spacing: 10) {
                ForEach(categories, id: \.title) { category in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle().fill(category.color).frame(width: 6, height: 6)
                            Text(category.title)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        Text(category.count.formatted())
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var cleanupSummary: some View {
        HStack(spacing: 18) {
            DeletionRatioRing(
                deletedCount: statistics.totalDeletedCount,
                viewedCount: statistics.viewedItemCount
            )
            .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 7) {
                Label("累计删除", systemImage: "trash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)

                Text(formattedBytes(statistics.totalDeletedBytes))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.62)
                    .lineLimit(1)
                    .contentTransition(.numericText())

                HStack(spacing: 7) {
                    Text("\(statistics.totalDeletedCount) 个项目")
                    Circle()
                        .fill(.tertiary)
                        .frame(width: 3, height: 3)
                    Text("查看 \(statistics.viewedItemCount)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 25, style: .continuous)
        )
    }

    private func todaySummary(now: Date) -> some View {
        let today = activity.recentDays(endingAt: now, count: 1).first ?? CleanupDaySnapshot(id: "")
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(.orange.opacity(0.12), in: Circle())
                Text("今日整理").font(.headline)
                Spacer()
                Text(now, format: .dateTime.month().day())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            }
            HStack(alignment: .top, spacing: 12) {
                todayMetric("浏览", value: today.viewedCount.formatted(), icon: "eye", color: .blue)
                todayMetric("删除", value: today.deletedCount.formatted(), icon: "trash", color: .purple)
                todayMetric("删除容量", value: formattedBytes(today.deletedBytes), icon: "externaldrive", color: .green)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.blue.opacity(0.10), .cyan.opacity(0.04), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .strokeBorder(.blue.opacity(0.12), lineWidth: 0.5)
        }
    }

    private func todayMetric(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func weeklyTrend(now: Date) -> some View {
        let week = activity.recentDays(endingAt: now)
        let selected = week.first { $0.id == selectedTrendDay }
        let viewed = selected?.viewedCount ?? week.reduce(0) { $0 + $1.viewedCount }
        let deleted = selected?.deletedCount ?? week.reduce(0) { $0 + $1.deletedCount }
        let bytes = selected?.deletedBytes ?? week.reduce(Int64(0)) { $0 + $1.deletedBytes }
        let countStep = max(1, ceil(Double(week.map { max($0.viewedCount, $0.deletedCount) }.max() ?? 0) / 4))
        let countLimit = countStep * 4
        let byteLimit = max(1, Double(week.map(\.deletedBytes).max() ?? 0))
        let ticks = (0...4).map { Double($0) * countStep }

        return statisticsCard {
            Text("近 7 天趋势").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                trendLegend("浏览", value: "\(viewed.formatted()) 个", color: .blue)
                trendLegend("删除", value: "\(deleted.formatted()) 个", color: .purple)
                trendLegend("删除容量", value: formattedBytes(bytes), color: .green, isLine: true)
            }

            Chart {
                ForEach(week) { day in
                    BarMark(
                        x: .value("日期", day.id),
                        y: .value("数量", day.viewedCount)
                    )
                    .position(by: .value("类别", "浏览"))
                    .foregroundStyle(.blue.opacity(0.8))
                    .cornerRadius(3)
                    .accessibilityLabel("\(day.id)，浏览")
                    .accessibilityValue("\(day.viewedCount) 个")

                    BarMark(
                        x: .value("日期", day.id),
                        y: .value("数量", day.deletedCount)
                    )
                    .position(by: .value("类别", "删除"))
                    .foregroundStyle(.purple.opacity(0.8))
                    .cornerRadius(3)
                    .accessibilityLabel("\(day.id)，删除")
                    .accessibilityValue("\(day.deletedCount) 个")
                }
                ForEach(week) { day in
                    // Map bytes onto the plot height and label their own right axis.
                    LineMark(
                        x: .value("日期", day.id),
                        y: .value("容量位置", Double(day.deletedBytes) / byteLimit * countLimit)
                    )
                    .foregroundStyle(.green)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .symbol(.circle)
                    .symbolSize(25)
                    .accessibilityLabel("\(day.id)，删除容量")
                    .accessibilityValue(formattedBytes(day.deletedBytes))
                }
                if let selected {
                    RuleMark(x: .value("日期", selected.id))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .accessibilityHidden(true)
                }
            }
            .chartLegend(.hidden)
            .chartXSelection(value: $selectedTrendDay)
            .chartYScale(domain: 0...countLimit)
            .chartXAxis {
                AxisMarks(values: week.map(\.id)) { value in
                    AxisValueLabel {
                        if let date = value.as(String.self) {
                            Text(String(date.suffix(5)))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.precision(.fractionLength(0))))
                        }
                    }
                }
                AxisMarks(position: .trailing, values: byteLimit > 1 ? ticks : [0.0]) { value in
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(formattedBytes(Int64(amount / countLimit * byteLimit)))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .frame(height: 190)
        }
    }

    private func trendLegend(_ title: String, value: String, color: Color, isLine: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: isLine ? 14 : 7, height: isLine ? 3 : 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func habits(now: Date) -> some View {
        statisticsCard {
            Label("整理的节奏", systemImage: "flame.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 20) {
                metricTile("当前连续", value: "\(activity.currentStreak(at: now))", unit: "天", color: .orange)
                metricTile("最长连续", value: "\(activity.longestStreak())", unit: "天", color: .pink)
                metricTile("累计整理", value: "\(activity.activeDayCount)", unit: "天", color: .blue)
                metricTile("单日最多删除", value: "\(activity.bestDeletionDay?.deletedCount ?? 0)", unit: "个", color: .purple)
            }
            if let best = activity.bestDeletionDay {
                Text("删除最多的一天：\(best.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statisticsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 23, style: .continuous)
            )
    }

    private func metricTile(_ title: String, value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var mediaBreakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("删除明细")
                .font(.headline)
                .padding(.bottom, 7)

            mediaRow(
                title: "照片",
                icon: "photo.fill",
                color: .blue,
                count: statistics.deletedPhotoCount,
                bytes: statistics.deletedPhotoBytes
            )

            Divider().padding(.leading, 54)

            mediaRow(
                title: "截图",
                icon: "iphone",
                color: .orange,
                count: statistics.deletedScreenshotCount,
                bytes: statistics.deletedScreenshotBytes
            )

            Divider().padding(.leading, 54)

            mediaRow(
                title: "视频",
                icon: "video.fill",
                color: .purple,
                count: statistics.deletedVideoCount,
                bytes: statistics.deletedVideoBytes
            )
        }
        .padding(.horizontal, 17)
        .padding(.top, 18)
        .padding(.bottom, 7)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 23, style: .continuous)
        )
    }

    private func mediaRow(
        title: String,
        icon: String,
        color: Color,
        count: Int,
        bytes: Int64
    ) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text("\(count) 个项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(formattedBytes(bytes))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
            }

            ProgressView(value: categoryShare(bytes: bytes, count: count))
                .tint(color)
                .scaleEffect(x: 1, y: 0.72)
        }
        .padding(.vertical, 11)
    }

    private var offlinePackage: some View {
        let status = viewModel.offlineCacheStatus

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: status.cachedCount > 0 ? "airplane.circle.fill" : "airplane.circle")
                    .font(.system(size: 34, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("登机准备")
                        .font(.headline)
                    Text(offlineStatusText(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if status.cachedCount > 0, !status.isPreparing {
                    Menu {
                        Button("清除离线照片包", role: .destructive) {
                            isShowingClearOfflineConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("离线照片包选项")
                }
            }

            VStack(spacing: 8) {
                ProgressView(value: offlineProgress(status))
                    .tint(offlineProgressColor(status))

                HStack {
                    Text(offlineProgressCaption(status))
                    Spacer()
                    Text(offlineProgressValue(status))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Button {
                Task { await viewModel.prepareOfflinePackage() }
            } label: {
                Label(
                    status.isPreparing
                        ? "正在提前加载"
                        : (status.cachedCount > 0 ? "重新准备 300 个项目" : "提前准备 300 个项目"),
                    systemImage: status.isPreparing ? "arrow.down" : "arrow.down.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(status.isPreparing)
        }
        .padding(18)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 23, style: .continuous)
        )
    }

    private var reviewHistory: some View {
        HStack(spacing: 13) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .frame(width: 42, height: 42)
                .background(.orange.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("\(viewModel.reviewedHistoryCount) 个项目冷却中")
                    .font(.subheadline.weight(.semibold))
                Text("浏览后一年内不会再次出现")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("重置", role: .destructive) {
                isShowingResetConfirmation = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.reviewedHistoryCount == 0)
        }
        .padding(17)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 23, style: .continuous)
        )
    }

    private func categoryShare(bytes: Int64, count: Int) -> Double {
        if statistics.totalDeletedBytes > 0 {
            return Double(bytes) / Double(statistics.totalDeletedBytes)
        }
        guard statistics.totalDeletedCount > 0 else { return 0 }
        return Double(count) / Double(statistics.totalDeletedCount)
    }

    private func offlineStatusText(_ status: OfflineCacheSnapshot) -> String {
        if status.isPreparing {
            return "正在下载并保存清晰预览"
        }
        if status.cachedCount > 0 {
            return "已缓存 \(status.cachedCount) 个，剩余 \(viewModel.offlineAvailableCount) 个"
        }
        return "飞行模式下继续浏览和删除"
    }

    private func offlineProgress(_ status: OfflineCacheSnapshot) -> Double {
        if status.isPreparing {
            return status.progress
        }
        guard status.cachedCount > 0 else { return 0 }
        return min(
            Double(viewModel.offlineAvailableCount) / Double(status.cachedCount),
            1
        )
    }

    private func offlineProgressCaption(_ status: OfflineCacheSnapshot) -> String {
        if status.isPreparing {
            return "已完成 \(status.completedCount) / \(status.targetCount)"
        }
        if status.cachedCount > 0 {
            return "离线可浏览项目"
        }
        return "尚未准备"
    }

    private func offlineProgressValue(_ status: OfflineCacheSnapshot) -> String {
        if status.isPreparing {
            return "\(Int(status.progress * 100))%"
        }
        if status.cachedCount > 0 {
            return "\(viewModel.offlineAvailableCount) / \(status.cachedCount)"
        }
        return "0 / 300"
    }

    private func offlineProgressColor(_ status: OfflineCacheSnapshot) -> Color {
        status.cachedCount > 0 && !status.isPreparing ? .green : .blue
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        return formatter
    }()
}

private struct DeletionRatioRing: View {
    let deletedCount: Int
    let viewedCount: Int

    private var ratio: Double? {
        guard viewedCount > 0 else { return nil }
        return Double(deletedCount) / Double(viewedCount)
    }

    private var percentage: String {
        ratio?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.blue.opacity(0.10), lineWidth: 11)
            Circle()
                // Day-gallery deletions can outnumber random-review views.
                // Clamp the drawing only; keep the displayed ratio accurate.
                .trim(from: 0, to: min(max(ratio ?? 0, 0), 1))
                .stroke(
                    AngularGradient(colors: [.blue, .cyan, .blue], center: .center),
                    style: StrokeStyle(lineWidth: 11, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.55, dampingFraction: 0.8), value: ratio)

            VStack(spacing: 2) {
                Text(percentage)
                    .font(.title3.bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text("删除 / 查看")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
        }
        .padding(7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            viewedCount > 0
                ? "累计删除与查看数量之比 \(percentage)"
                : "暂无查看记录，删除与查看比例暂不可用"
        )
    }
}
