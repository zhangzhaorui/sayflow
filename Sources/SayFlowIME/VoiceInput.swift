import AppKit
import CoreAudio
import SayFlowCore

/// 一段语音：从按下右 Command 开始，到写入完成（或放弃）结束
@MainActor
final class RecordingJob {
    let sequence: Int
    let fileURL: URL
    let startedAt = Date()
    let target: TextTarget
    let recorder: Recorder
    var discard = false

    init(sequence: Int, fileURL: URL, target: TextTarget, recorder: Recorder) {
        self.sequence = sequence
        self.fileURL = fileURL
        self.target = target
        self.recorder = recorder
    }
}

struct VoiceResult {
    let job: RecordingJob
    let text: String
    let notice: String?
}

/// 语音输入：按住右 Command 说话 → 网关识别 → AI 整理（可关）→ 按说话顺序写入光标处。
/// 录音只在按住期间进行，文件放在 App 自己的临时目录，识别完立即删除，不保存任何历史。
@MainActor
final class VoiceInput {
    private let prefs: Preferences
    private let gateway: GatewayClient
    private let hud: HUD
    private var current: RecordingJob?
    private let delivery = OrderedDelivery<VoiceResult>()
    private var generation = 0
    private(set) var pendingCount = 0

    /// 需要打开设置时调用
    var openSettings: (() -> Void)?

    init(prefs: Preferences, gateway: GatewayClient, hud: HUD) {
        self.prefs = prefs
        self.gateway = gateway
        self.hud = hud
    }

    var isRecording: Bool { current != nil }

    // MARK: 触发

    func pressed(target: TextTarget) {
        guard prefs.voiceEnabled, current == nil else { return }
        guard !Permissions.isSecureInputActive else { return }
        guard KeychainStore.hasKey else {
            hud.show("语音输入需要先在 SayFlow 设置里填写令牌", duration: 3)
            return
        }
        switch Permissions.microphone() {
        case .granted:
            break
        case .notDetermined:
            Permissions.requestMicrophone { _ in }
            hud.show("请允许 SayFlow 使用麦克风，然后再按住右 Command", duration: 4)
            return
        case .denied:
            hud.show("没有麦克风权限，请在系统设置 → 隐私与安全性 → 麦克风里打开 SayFlow", duration: 4)
            return
        }

        let url: URL
        do {
            url = try TempFiles.newRecordingURL()
        } catch {
            hud.show("无法创建临时文件", duration: 3)
            return
        }
        let (deviceID, note) = resolveDevice()
        let recorder = Recorder()
        do {
            try recorder.start(deviceID: deviceID, url: url)
        } catch {
            TempFiles.remove(url)
            hud.show((error as? LocalizedError)?.errorDescription ?? "无法开始录音", duration: 4)
            return
        }
        let job = RecordingJob(sequence: delivery.reserve(), fileURL: url, target: target, recorder: recorder)
        current = job
        hud.show(note.map { "正在听…（\($0)）" } ?? "正在听…", duration: nil)

        generation += 1
        let g = generation
        after(GatewayConfig.maxRecordingSeconds) { [weak self] in
            guard let self, self.generation == g, self.current === job else { return }
            self.stop(discard: false)
            self.hud.show("单次录音最长 3 分钟，已自动结束", duration: 3)
        }
    }

    func released() {
        stop(discard: false)
    }

    /// 按住右 Command 时按了别的键：当成快捷键，取消这次录音
    func cancelForOtherKey() {
        guard current != nil else { return }
        stop(discard: true)
    }

    private func resolveDevice() -> (AudioDeviceID?, String?) {
        if let uid = prefs.deviceUID {
            if let device = AudioDevices.device(uid: uid) { return (device.id, nil) }
            return (nil, "所选录音设备不在，改用系统默认麦克风")
        }
        return (AudioDevices.remoteDevice()?.id, nil)
    }

    private func stop(discard: Bool) {
        guard let job = current else { return }
        current = nil
        generation += 1
        job.discard = discard || Date().timeIntervalSince(job.startedAt) < GatewayConfig.minRecordingSeconds
        hud.hide()
        // 松开后多录一小段，避免吞掉最后一个字
        after(job.discard ? 0 : GatewayConfig.tailSeconds) { [weak self] in
            job.recorder.stop()
            self?.finished(job)
        }
    }

    private func finished(_ job: RecordingJob) {
        if job.discard {
            TempFiles.remove(job.fileURL)
            resolve(job, nil)
            return
        }
        if TempFiles.size(job.fileURL) < GatewayConfig.minRecordingBytes {
            TempFiles.remove(job.fileURL)
            hud.show("没有录到声音，请检查录音设备", duration: 3)
            resolve(job, nil)
            return
        }
        process(job)
    }

    // MARK: 识别和整理

    private func process(_ job: RecordingJob) {
        guard let key = KeychainStore.read() else {
            TempFiles.remove(job.fileURL)
            resolve(job, nil)
            return
        }
        pendingCount += 1
        hud.show("正在识别…", duration: nil)
        let dictionary = prefs.dictionary
        let endpoint = prefs.gateway

        gateway.transcribe(fileURL: job.fileURL, endpoint: endpoint, apiKey: key, dictionary: dictionary) { [weak self] result in
            TempFiles.remove(job.fileURL)
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finishPending()
                self.hud.show("识别失败：" + error.message, duration: 4)
                self.resolve(job, nil)
            case .success(let text):
                let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty {
                    self.finishPending()
                    self.resolve(job, nil)
                    return
                }
                if !self.prefs.cleanupEnabled || raw.unicodeScalars.count < GatewayConfig.cleanupMinChars {
                    self.deliver(job, text: raw, notice: nil)
                    return
                }
                let prompt = PromptBuilder.systemPrompt(appName: job.target.appName, bundleID: job.target.bundleID,
                                                        dictionary: dictionary, style: self.prefs.cleanupStyle)
                self.gateway.cleanup(transcript: raw, systemPrompt: prompt, endpoint: endpoint, apiKey: key) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure:
                        self.deliver(job, text: raw, notice: "整理失败，已写入识别原文")
                    case .success(let cleaned):
                        if cleaned.isEmpty {
                            self.deliver(job, text: raw, notice: "整理结果为空，已写入识别原文")
                        } else if ResultGuard.isTooMuchLonger(raw: raw, cleaned: cleaned) {
                            self.deliver(job, text: raw, notice: "整理结果明显变长，已改为写入原文")
                        } else {
                            self.deliver(job, text: cleaned, notice: nil)
                        }
                    }
                }
            }
        }
    }

    private func finishPending() {
        pendingCount = max(0, pendingCount - 1)
        if pendingCount == 0 { hud.hide() }
    }

    private func deliver(_ job: RecordingJob, text: String, notice: String?) {
        finishPending()
        resolve(job, VoiceResult(job: job, text: text, notice: notice))
    }

    /// 每段语音都必须 resolve 一次，保证后面的段不会被卡住
    private func resolve(_ job: RecordingJob, _ item: VoiceResult?) {
        for ready in delivery.resolve(job.sequence, item) {
            if Permissions.isSecureInputActive {
                hud.show("当前是密码输入框，已取消写入", duration: 3)
                continue
            }
            ready.job.target.insert(ready.text)
            if let notice = ready.notice { hud.show(notice, duration: 2.5) }
        }
    }
}
