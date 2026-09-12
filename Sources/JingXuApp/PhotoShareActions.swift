import AppKit
import JingXuCore

extension AppModel {
    var canShowPhotoShare: Bool {
        canStartColorAction && !isStarting && !isSavingAnnotation && !isShowingColorPresets &&
        !automationOwnsOperation && errorMessage == nil && !photoShareSession.isActive && !colorTargetIDs.isEmpty
    }
    var fileOperationsBlockedByShare: Bool { isShowingPhotoShare || photoShareSession.blocksFileChanges }

    func showPhotoShare() {
        guard canShowPhotoShare, NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return }
        isPreparingSelection = true
        Task {
            defer { isPreparingSelection = false }
            do {
                guard await flushKeywords() else { return }
                shareDraft = try await resolveColorTargets()
                guard !shareDraft.isEmpty else { return }
                sharePreparationProgress = ""; isShowingPhotoShare = true
            } catch { errorMessage = "读取分享范围失败：\(error.localizedDescription)" }
        }
    }

    func preparePhotoShare(mode: PhotoShareMode, maximumDimension: Int?) {
        guard isShowingPhotoShare, !isWorking, !photoShareSession.isActive,
              sharePreparationTask == nil, let coordinator = photoShareCoordinator else { return }
        let ids = shareDraft.map(\.id)
        isWorking = true; sharePreparationProgress = "正在准备照片…"
        sharePreparationTask = Task {
            defer { isWorking = false; sharePreparationTask = nil }
            do {
                try await checkDeletionRecovery()
                if mode == .jpeg, let editor = colorEditor {
                    isPreviewTransitioning = true
                    let saved = await editor.flush()
                    isPreviewTransitioning = false
                    guard saved else {
                        sharePreparationProgress = "调色保存失败，请返回调色面板重试；尚未开始分享"
                        return
                    }
                }
                try Task.checkCancellation()
                let plan = try await coordinator.plan(assetIDs: ids, mode: mode, maximumDimension: maximumDimension)
                let prepared = try await coordinator.prepare(plan) { [weak self] done, total in
                    await MainActor.run { self?.sharePreparationProgress = "准备照片 \(done)/\(total)" }
                }
                if Task.isCancelled {
                    try await coordinator.finish(id: prepared.id, cacheDirectory: prepared.cacheDirectory, handedToSystem: false)
                    throw CancellationError()
                }
                do { try photoShareSession.install(prepared, coordinator: coordinator) }
                catch {
                    try await coordinator.finish(id: prepared.id, cacheDirectory: prepared.cacheDirectory, handedToSystem: false)
                    throw error
                }
                sharePreparationProgress = "已准备 \(prepared.files.count) 张；请选择系统分享目标"
            } catch is CancellationError {
                sharePreparationProgress = "已取消分享准备"; isShowingPhotoShare = false
            } catch { sharePreparationProgress = "准备失败：\(error.localizedDescription)" }
        }
    }
    func retryPhotoShare(mode: PhotoShareMode, maximumDimension: Int?) {
        guard isShowingPhotoShare, photoShareSession.phase == .ready, !isWorking else { return }
        // Keep the preparation page open while replacing a failed/partial plan.
        photoShareSession.discardPreparation()
        isWorking = true
        Task {
            await photoShareSession.waitForCleanup()
            isWorking = false
            guard isShowingPhotoShare else { return }
            preparePhotoShare(mode: mode, maximumDimension: maximumDimension)
        }
    }
    func cancelPhotoShare() {
        if let sharePreparationTask { sharePreparationProgress = "正在取消…"; sharePreparationTask.cancel(); return }
        if photoShareSession.isActive { photoShareSession.end() }
        isShowingPhotoShare = false; shareDraft = []
    }
    func endPhotoShare() {
        if photoShareSession.phase == .sharing {
            let alert = NSAlert()
            alert.messageText = "结束本次分享会话？"
            alert.informativeText = "这会释放原片访问授权，可能使未完成的分享失败；不能撤回或停止外部应用发送。"
            alert.addButton(withTitle: "继续等待"); alert.addButton(withTitle: "结束会话")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        cancelPhotoShare()
    }
    func prepareShareForExit() async -> Bool {
        if photoShareSession.requiresExitConfirmation {
            let alert = NSAlert()
            alert.messageText = "原片分享尚未结束"
            alert.informativeText = "退出将释放原片访问授权，可能使分享失败。请先完成或取消系统分享；结束会话不能撤回或停止外部应用发送。"
            alert.addButton(withTitle: "留在镜序"); alert.addButton(withTitle: "结束会话并退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        sharePreparationTask?.cancel(); await sharePreparationTask?.value
        if photoShareSession.isActive { photoShareSession.end() }
        await photoShareSession.waitForCleanup()
        isShowingPhotoShare = false
        return true
    }
}
