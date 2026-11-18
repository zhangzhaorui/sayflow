import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

// MARK: - 录音设备

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    /// SayAll 提供的虚拟麦克风
    static let remoteDeviceName = "MiRemoteV 2ch"

    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id -> AudioInputDevice? in
            guard hasInput(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> AudioInputDevice? {
        return inputs().first { $0.uid == uid }
    }

    static func remoteDevice() -> AudioInputDevice? {
        return inputs().first { $0.name == remoteDeviceName }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

// MARK: - 录音

enum RecorderError: LocalizedError {
    case noInputUnit
    case deviceSwitchFailed(OSStatus)
    case badFormat
    case fileCreateFailed(String)
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputUnit: return "找不到录音设备"
        case .deviceSwitchFailed(let status): return "无法切换到所选录音设备（\(status)）"
        case .badFormat: return "录音设备的音频格式不可用"
        case .fileCreateFailed(let reason): return "无法创建录音文件：\(reason)"
        case .engineStartFailed(let reason): return "无法开始录音：\(reason)"
        }
    }
}

/// 把输入设备的音频实时转成 16kHz 单声道 16 位 WAV，写到 App 自己的临时目录
final class AudioFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    private final class Flag: @unchecked Sendable { var value = false }

    init(url: URL, inputFormat: AVAudioFormat) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw RecorderError.badFormat
        }
        converter.downmix = true
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVAudioFileTypeKey: kAudioFileWAVEType,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            throw RecorderError.fileCreateFailed(error.localizedDescription)
        }
        self.converter = converter
        self.outputFormat = output
    }

    /// 在音频线程调用
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        let supplied = Flag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        try? file.write(from: output)
    }

    func close() {
        lock.lock()
        file = nil          // 释放即关闭文件
        lock.unlock()
    }
}

/// 只在按住触发键期间运行；松开后立即停止并释放麦克风
@MainActor
final class Recorder {
    private var engine: AVAudioEngine?
    private var sink: AudioFileSink?

    /// deviceID 为 nil 时使用系统默认麦克风
    func start(deviceID: AudioDeviceID?, url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceID {
            guard let unit = input.audioUnit else { throw RecorderError.noInputUnit }
            var device = deviceID
            let status = AudioUnitSetProperty(unit,
                                              kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global,
                                              0,
                                              &device,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw RecorderError.deviceSwitchFailed(status) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.badFormat }

        let sink = try AudioFileSink(url: url, inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.close()
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        self.engine = engine
        self.sink = sink
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        sink?.close()
        engine = nil
        sink = nil
    }
}
