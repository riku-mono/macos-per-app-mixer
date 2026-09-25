//
//  MixerModel.swift
//  Mixer
//


import AppKit
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
    var masterVolume: Double = 0.6
    var apps: [AudioApp]

    @ObservationIgnored private var monitor: AudioProcessMonitor?
    // 一度消えたアプリの音量・ミュートを、再び音を出したときに復元するための控え
    @ObservationIgnored private var remembered: [String: AudioApp] = [:]

    /// 実際に音を出しているアプリを Core Audio から検出する
    init() {
        apps = []
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
        for app in apps {
            remembered[app.id] = app
        }
        apps = detected.map { remembered[$0.id] ?? AudioApp(id: $0.id, name: $0.name) }
    }
}
