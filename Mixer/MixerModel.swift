//
//  MixerModel.swift
//  Mixer
//


import AppKit
import CoreAudio
import Observation
 
/// アプリ配下の個別の音源（Chrome のタブなど。今はダミー）
struct AudioTab: Identifiable {
    let id: Int           // Chrome 拡張の tabId を想定
    let title: String
    var volume: Double = 1.0   // 0.0〜1.0（親アプリ音量に対する相対値）
    var isMuted = false
}

/// 1つのアプリ分の音量情報（今はダミー）
struct AudioApp: Identifiable {
    let id: String        // バンドルID（例: com.google.Chrome）
    let name: String
    var volume: Double = 1.0   // 0.0〜1.0
    var isMuted = false
    var tabs: [AudioTab] = []  // 音を出しているタブ。空なら子を持たない

    /// インストール済みならそのアプリの本物のアイコンを使う
    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}
 
@MainActor
@Observable
final class MixerModel {
    /// 全体音量。既定の出力デバイスの音量と連動する
    var masterVolume: Double = 0.6 {
        didSet {
            if controlsDevices { OutputDevice.volume = masterVolume }
        }
    }
    /// 出力デバイスが音量変更に対応しているか（HDMI などは非対応）
    private(set) var canChangeMasterVolume = true

    /// 今音を出しているアプリ
    var apps: [AudioApp] = [] {
        didSet { syncTaps() }
    }

    // プレビュー中に本物の Mac の音量を変えないためのフラグ
    @ObservationIgnored private var controlsDevices = false
    @ObservationIgnored private var monitor: AudioProcessMonitor?
    @ObservationIgnored private var outputObserver: OutputDevice.Observer?
    @ObservationIgnored private let taps = AppVolumeTapManager()
    // アプリごとの音量・ミュート設定。一覧から消えても保持し、再び音を出したときに復元する
    @ObservationIgnored private var settings: [String: AudioApp] = [:]
    // アプリID → Core Audio のプロセスオブジェクト（音を出していないものも含む）
    @ObservationIgnored private var processes: [String: [AudioObjectID]] = [:]

    /// 実際に音を出しているアプリを Core Audio から検出し、音量を制御する
    init() {
        controlsDevices = true
        readMasterVolume()

        outputObserver = OutputDevice.observe(
            onDeviceChange: { [weak self] in
                guard let self else { return }
                readMasterVolume()
                taps.outputDeviceChanged(gains: gains, processes: processes)
            },
            onVolumeChange: { [weak self] in
                self?.readMasterVolume()
            }
        )

        let monitor = AudioProcessMonitor()
        monitor.onChange = { [weak self] detected in
            self?.update(with: detected)
        }
        self.monitor = monitor
        monitor.start()
    }

    /// プレビュー用（Core Audio を使わずダミーデータで表示）
    init(apps: [AudioApp]) {
        self.apps = apps
    }

    static var preview: MixerModel {
        MixerModel(apps: [
            AudioApp(id: "com.google.Chrome", name: "Google Chrome", tabs: [
                AudioTab(id: 101, title: "YouTube - Lo-fi hip hop radio"),
                AudioTab(id: 102, title: "Google Meet - 定例", volume: 0.7),
            ]),
            AudioApp(id: "com.apple.Music", name: "ミュージック", volume: 0.5),
            AudioApp(id: "com.tinyspeck.slackmacgap", name: "Slack", volume: 0.8),
            AudioApp(id: "us.zoom.xos", name: "Zoom"),
        ])
    }

    private func update(with detected: [DetectedAudioApp]) {
        processes = Dictionary(uniqueKeysWithValues: detected.map { ($0.id, $0.processObjectIDs) })
        apps = detected
            .filter(\.isOutputting)
            .map { settings[$0.id] ?? AudioApp(id: $0.id, name: $0.name) }
    }

    private var gains: [String: Float] {
        settings.mapValues { $0.isMuted ? 0 : Float($0.volume) }
    }

    private func syncTaps() {
        for app in apps {
            settings[app.id] = app
        }
        taps.sync(gains: gains, processes: processes)
    }

    /// 音量キーなど、外で変わった音量をスライダーに反映する
    private func readMasterVolume() {
        guard let volume = OutputDevice.volume else {
            canChangeMasterVolume = false
            return
        }
        canChangeMasterVolume = true
        // 同じ値を書き戻して通知が往復し続けないよう、変化があるときだけ代入する
        if abs(volume - masterVolume) > 0.001 {
            masterVolume = volume
        }
    }
}
