import AppKit
import JingXuCore
import SwiftUI

extension AppModel {
    func compareSelected() {
        guard photoSelection.selectedIDs.count == 2, operationBlockReason(.browse) == nil else { return }
        transitionPreview {
            self.isPreparingSelection = true
            Task {
                defer { self.isPreparingSelection = false }
                do {
                    let rows = try await self.resolveColorTargets()
                    guard rows.count == 2 else { return }
                    self.comparisonReference = rows[0]
                    self.presentPreview(rows[1])
                } catch { self.errorMessage = "无法比较：\(error.localizedDescription)" }
            }
        }
    }

    func compareSimilarGroup(_ id: String) {
        guard operationBlockReason(.browse) == nil, let store else { return }
        transitionPreview {
            self.isPreparingSelection = true
            Task {
                defer { self.isPreparingSelection = false }
                do {
                    let query = BrowseQuery(similarGroupID: id, sortOrder: self.appliedQuery.sortOrder)
                    let page = try await store.browsePage(query, photosOnly: true, limit: 2)
                    guard page.items.count == 2 else { self.errorMessage = "相似组不足两张可比较照片"; return }
                    self.comparisonReturnQuery = self.appliedQuery
                    self.pendingQuery = query
                    await self.loadBrowsePage()
                    guard self.appliedQuery == query else { return }
                    self.comparisonReference = page.items[0]
                    self.presentPreview(page.items[1])
                } catch { self.errorMessage = "读取相似组失败：\(error.localizedDescription)" }
            }
        }
    }

    func promoteComparisonCandidate() {
        guard previewNavigationEnabled, let candidate = previewAsset, let store else { return }
        transitionPreview {
            self.isPreparingSelection = true
            Task {
                defer { self.isPreparingSelection = false }
                do {
                    let page = try await store.browsePage(self.appliedQuery, cursor: BrowseCursor(candidate), photosOnly: true, limit: 1)
                    guard let next = page.items.first else { self.statusText = "没有更多候选，当前比较保持不变"; return }
                    self.comparisonReference = candidate
                    self.previewAsset = next
                    await self.refreshPreviewWindow()
                } catch { self.errorMessage = "切换参考图失败：\(error.localizedDescription)" }
            }
        }
    }

    func leaveSimilarGroup() {
        transitionPreview {
            self.pendingQuery = self.comparisonReturnQuery ?? BrowseQuery()
            self.comparisonReturnQuery = nil
            self.clearComparisonPrefetch()
            Task { await self.loadBrowsePage() }
        }
    }

    func clearComparisonPrefetch() {
        comparisonPrefetchGeneration = UUID()
        comparisonPrefetchTask?.cancel()
        comparisonPrefetchTask = nil
        prefetchedComparison = nil
        prefetchedComparisonKey = nil
    }

    func comparisonImage(_ item: AssetListItem) async throws -> PreviewImage {
        let key = "\(item.id)-\(item.fileVersion)-\(item.colorRevision)"
        if prefetchedComparisonKey == key, let prefetchedComparison {
            self.prefetchedComparison = nil
            prefetchedComparisonKey = nil
            return prefetchedComparison
        }
        return try await loadOriginal(item)
    }

    func prefetchComparisonNext(from item: AssetListItem) {
        guard previewAsset?.id == item.id,
              comparisonReference != nil,
              let index = previewItems.firstIndex(where: { $0.id == item.id }),
              let next = previewItems.dropFirst(index + 1).first(where: { $0.id != comparisonReference?.id }) else {
            clearComparisonPrefetch()
            return
        }
        let key = "\(next.id)-\(next.fileVersion)-\(next.colorRevision)"
        guard prefetchedComparisonKey != key else { return }
        clearComparisonPrefetch()
        let generation = comparisonPrefetchGeneration
        comparisonPrefetchTask = Task {
            do {
                let image = try await loadOriginal(next)
                guard !Task.isCancelled, comparisonPrefetchGeneration == generation, comparisonReference != nil else { return }
                prefetchedComparison = image
                prefetchedComparisonKey = key
            } catch { /* The visible candidate owns error presentation when reached. */ }
        }
    }
}

struct ComparisonView: View {
    @EnvironmentObject private var model: AppModel
    @State private var linked = true
    @State private var transform = CanvasTransform()
    @State private var transformCommand = 0

    var body: some View {
        VStack(spacing: 0) {
            if let reference = model.comparisonReference, let candidate = model.previewAsset {
                HStack(spacing: 0) {
                    ComparisonPane(
                        item: reference,
                        roleTitle: "参考图",
                        active: false,
                        linked: linked,
                        command: transformCommand,
                        transform: $transform
                    )
                    Rectangle()
                        .fill(DarkroomPalette.comparisonSeam)
                        .frame(width: 2)
                    ComparisonPane(
                        item: candidate,
                        roleTitle: "当前候选（操作作用于此）",
                        active: true,
                        linked: linked,
                        command: transformCommand,
                        transform: $transform
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                comparisonControlBar(candidate: candidate)
            }
        }
        .darkroomStageSurface()
        .onExitCommand { model.closePreview() }
        .accessibilityIdentifier("comparison-view")
    }

    private func comparisonControlBar(candidate: AssetListItem) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(DarkroomPalette.subtleDivider)
            HStack(spacing: 10) {
                if model.appliedQuery.similarGroupID != nil {
                    Button("返回原范围", systemImage: "arrow.uturn.backward") {
                        model.leaveSimilarGroup()
                    }
                    Divider().frame(height: 16).overlay(DarkroomPalette.subtleDivider)
                }

                Toggle("同步缩放", isOn: $linked)
                    .toggleStyle(.checkbox)
                Button("适应") { transform = CanvasTransform(); transformCommand += 1 }
                Button("100%") { transform = CanvasTransform(fitted: false); transformCommand += 1 }

                Divider().frame(height: 16).overlay(DarkroomPalette.subtleDivider)

                Button { model.navigatePreview(-1) } label: {
                    Label("上一候选", systemImage: "chevron.left")
                }
                .disabled(!model.canNavigatePreview(-1))

                Button { model.navigatePreview(1) } label: {
                    Label("下一候选", systemImage: "chevron.right")
                }
                .disabled(!model.canNavigatePreview(1))

                Button("设为参考图", systemImage: "pin") {
                    model.promoteComparisonCandidate()
                }
                .disabled(!model.previewNavigationEnabled)

                Spacer(minLength: 8)

                // Candidate annotations
                HStack(spacing: 5) {
                    ForEach(1...5, id: \.self) { rating in
                        Button {
                            model.updateRating(candidate.rating == rating ? 0 : rating)
                        } label: {
                            Image(systemName: candidate.rating >= rating ? "star.fill" : "star")
                                .foregroundStyle(candidate.rating >= rating ? Color.yellow : DarkroomPalette.textSecondary)
                        }
                        .accessibilityLabel("\(rating) 星")
                    }

                    Button("淘汰并下一张", systemImage: "xmark.circle") {
                        model.updateFlag(.rejected, advanceToNext: true)
                    }
                    .foregroundStyle(DarkroomPalette.rejectCoral)

                    if candidate.flag == .rejected {
                        Button("取消淘汰") {
                            model.updateFlag(.none)
                        }
                    }
                }
                .disabled(model.operationBlockReason(.annotation) != nil)

                Divider().frame(height: 16).overlay(DarkroomPalette.subtleDivider)

                Button("调色 (D)", systemImage: "slider.horizontal.3") {
                    model.switchStage(to: .develop)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartColorAction)

                Button {
                    model.showsFilmstrip.toggle()
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .foregroundStyle(model.showsFilmstrip ? Color.accentColor : DarkroomPalette.textSecondary)
                }
                .accessibilityLabel("切换胶片栏")
                .help(model.showsFilmstrip ? "隐藏胶片栏（F）" : "显示胶片栏（F）")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(DarkroomPalette.panelSurface)
        }
    }
}

private struct ComparisonPane: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetListItem
    let roleTitle: String
    let active: Bool
    let linked: Bool
    let command: Int
    @Binding var transform: CanvasTransform

    @State private var image: PreviewImage?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ComparisonCanvas(
                image: image,
                assetID: item.id,
                linked: linked,
                command: command,
                transform: $transform,
                exit: { model.closePreview() }
            )
            .overlay {
                if let error {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(DarkroomPalette.textSecondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            Button("重试") { retry += 1 }.buttonStyle(.borderedProminent)
                            Button("重新授权…") { model.reauthorizeThumbnailSource(item) }.buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                    }
                    .padding(16)
                    .frame(maxWidth: 300)
                    .background(DarkroomPalette.panelSurface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))
                } else if image == nil {
                    ProgressView().controlSize(.small)
                }
            }

            // Floating pane badge
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? Color.accentColor : DarkroomPalette.textMuted)
                    .frame(width: 6, height: 6)
                Text("\(roleTitle) · \(item.fileName)")
                    .font(.caption.weight(active ? .semibold : .regular))
                    .foregroundStyle(DarkroomPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.rating > 0 {
                    Text(String(repeating: "★", count: min(5, item.rating)))
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                }
                if item.flag == .rejected {
                    Text("已淘汰")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DarkroomPalette.rejectCoral)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                active ? Color.accentColor.opacity(0.24) : Color.black.opacity(0.65),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(active ? Color.accentColor.opacity(0.85) : DarkroomPalette.subtleDivider, lineWidth: 1)
            )
            .padding(10)
            .allowsHitTesting(false)
        }
        .overlay(
            Rectangle()
                .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
        .task(id: "\(item.id)-\(item.fileVersion)-\(item.colorRevision)-\(retry)") {
            image = nil
            error = nil
            do {
                let loaded = try await model.comparisonImage(item)
                guard !Task.isCancelled else { return }
                image = loaded
                if active { model.prefetchComparisonNext(from: item) }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        .onDisappear { image = nil }
    }
}

private struct ComparisonCanvas: NSViewRepresentable {
    let image: PreviewImage?
    let assetID: String
    let linked: Bool
    let command: Int
    @Binding var transform: CanvasTransform
    let exit: () -> Void

    final class Coordinator { var command = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PreviewCanvasView { PreviewCanvasView() }

    func updateNSView(_ view: PreviewCanvasView, context: Context) {
        view.onExit = exit
        view.setImage(image?.image, assetID: assetID, nativeSize: image?.nativeSize ?? .zero)
        if image != nil, linked || context.coordinator.command != command {
            view.applyTransform(transform)
            context.coordinator.command = command
        }
        view.onTransformChange = { value in if linked { transform = value } }
    }

    static func dismantleNSView(_ view: PreviewCanvasView, coordinator: Coordinator) {
        view.onTransformChange = nil
        view.onExit = nil
        view.clearImage()
    }
}
