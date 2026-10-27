import SwiftUI

/// The group summary is independent of PhotoKit so its layout can be inspected
/// with fixture content without opening the user's library.
struct BatchCompletionView<Thumbnails: View>: View {
    let reviewedCount: Int
    let candidateCount: Int
    let selectedCount: Int
    let isLoading: Bool
    let isDeleting: Bool
    let onNext: () -> Void
    let onKeep: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let thumbnails: () -> Thumbnails

    private var isBusy: Bool { isLoading || isDeleting }
    private var willDelete: Bool { candidateCount > 0 && selectedCount > 0 }

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.height < 420 && proxy.size.width > proxy.size.height
            content(isCompact: isCompact)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actions(isCompact: isCompact)
                        .padding(.horizontal, 20)
                        .padding(.vertical, isCompact ? 12 : 20)
                        .background(.bar)
                }
        }
        .background(.background)
    }

    private func content(isCompact: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 24) {
                let headerLayout = isCompact
                    ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                headerLayout {
                    Text("回顾完毕")
                        .font(isCompact ? .title2.bold() : .largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("已查看 \(reviewedCount) 个项目")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if candidateCount == 0 {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64, weight: .regular))
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("这一组没有需要删除的项目")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        let selectionLayout = isCompact
                            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        selectionLayout {
                            Text("请选择最终需要删除的项目")
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("已选择 \(selectedCount) / \(candidateCount)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        thumbnails()
                            .disabled(isBusy)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, isCompact ? 16 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(isCompact: Bool) -> some View {
        let layout = isCompact
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 12))
        return layout {
            Button(role: willDelete ? .destructive : nil) {
                if willDelete {
                    onDelete()
                } else if candidateCount > 0 {
                    onKeep()
                } else {
                    onNext()
                }
            } label: {
                HStack(spacing: 10) {
                    if isBusy { ProgressView().tint(.white) }
                    Text(primaryActionTitle)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(willDelete ? .red : .accentColor)
            .disabled(isBusy)

            if willDelete {
                Button(action: onKeep) {
                    Text("放弃，再来一组")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .disabled(isBusy)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle)
    }

    private var primaryActionTitle: String {
        if isDeleting { return "正在删除…" }
        if isLoading { return "正在准备下一组…" }
        if willDelete { return "确认删除（\(selectedCount)）" }
        return candidateCount > 0 ? "不删除，再来一组" : "再来一组"
    }
}
