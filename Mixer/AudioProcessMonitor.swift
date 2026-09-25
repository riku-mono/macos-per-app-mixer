//
//  AudioProcessMonitor.swift
//  Mixer
//

import AppKit
import CoreAudio
import Darwin
import os

/// 音を出しているアプリ1つ分（Helper などの補助プロセスは親アプリにまとめ済み）
struct DetectedAudioApp: Equatable {
    let id: String    // 親アプリのバンドルID（取れなければプロセス自身のバンドルID）
    let name: String
}

/// Core Audio のプロセス一覧を監視し、音声を出力中のアプリが変わるたびに onChange で通知する
final class AudioProcessMonitor {
    var onChange: (([DetectedAudioApp]) -> Void)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mixer", category: "audio")
    // 登録と解除で同じブロックを渡す必要があるので、1つだけ作って保持する
    private var listener: AudioObjectPropertyListenerBlock?
    private var watchedProcesses: Set<AudioObjectID> = []

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        listener = block

        // プロセスが増減したとき
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        refresh()
    }

    func refresh() {
        guard let listener else { return }
        let processes = Self.processObjectIDs()

        // 新しく現れたプロセスは「再生の開始／停止」も監視する。
        // IsRunningOutput は変化しても通知が来ないことがあるため、IsRunning も併せて監視する
        for id in Set(processes).subtracting(watchedProcesses) {
            for selector in [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput] {
                var address = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
            }
        }
        watchedProcesses = Set(processes)

        var result: [DetectedAudioApp] = []
        for id in processes where Self.isRunningOutput(id) {
            guard let pid = Self.pid(of: id), pid != getpid() else { continue }
            let app = Self.resolveApp(pid: pid, fallbackBundleID: Self.bundleID(of: id))
            if !result.contains(where: { $0.id == app.id }) {
                result.append(app)
            }
        }
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        logger.debug("音声出力中: \(result.map(\.id), privacy: .public)")
        onChange?(result)
    }

    // MARK: - Core Audio の読み出し

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningOutput(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func pid(of id: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func bundleID(of id: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?,
              !string.isEmpty else { return nil }
        return string
    }

    // MARK: - プロセス → アプリの読み替え

    /// 「Google Chrome Helper」のような補助プロセスを、外側の .app（Google Chrome.app）に読み替える
    private static func resolveApp(pid: pid_t, fallbackBundleID: String?) -> DetectedAudioApp {
        let path = executablePath(pid: pid)
        if let path, let range = path.range(of: ".app/") {
            let appURL = URL(fileURLWithPath: String(path[..<range.upperBound].dropLast()))
            if let id = Bundle(url: appURL)?.bundleIdentifier {
                var name = FileManager.default.displayName(atPath: appURL.path)
                if name.hasSuffix(".app") { name.removeLast(4) }
                return DetectedAudioApp(id: id, name: name)
            }
        }
        // .app に入っていないプロセス（afplay、WebKit の GPU プロセスなど）
        let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? fallbackBundleID ?? "PID \(pid)"
        return DetectedAudioApp(id: fallbackBundleID ?? "pid.\(pid)", name: name)
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
