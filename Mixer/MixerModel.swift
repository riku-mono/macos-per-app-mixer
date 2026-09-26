//
//  MixerModel.swift
//  Mixer
//


import AppKit
import CoreAudio
import Observation
import os
 
/// アプリ配下の個別の音源（Chrome のタブ。Chrome 拡張から届く）
struct AudioTab: Identifiable, Equatable {
    let id: Int           // Chrome 拡張の tabId
    let title: String
    var volume: Double = 1.0   // 0.0〜1.0（親アプリ音量に対する相対値）
    var isMuted = false
}

/// 1つのアプリ分の音量情報
struct AudioApp: Identifiable {
    let id: String        // バンドルID（例: com.google.Chrome）
    let name: String
    var volume: Double = 1.0   // 0.0〜1.0
    var isMuted = false
    var tabs: [AudioTab] = []  // 音を出している・操作したタブ。空なら子を持たない

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
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mixer", category: "model")

    static let chromeID = "com.google.Chrome"
    /// 音が止まってからも一覧に残し、音量調整を動かし続ける秒数（一時停止してすぐ再生しても行が消えないように）
    static let idleGracePeriod: TimeInterval = 10

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
        didSet { appsDidChange(from: oldValue) }
    }

    /// Chrome 拡張とつながっているか
    private(set) var isChromeExtensionConnected = false

    /// ログイン時に自動で起動するか
    private(set) var launchAtLogin = false

    // プレビュー中に本物の Mac の音量や保存した設定を変えないためのフラグ
    @ObservationIgnored private var controlsDevices = false
    @ObservationIgnored private var monitor: AudioProcessMonitor?
    @ObservationIgnored private var outputObserver: OutputDevice.Observer?
    @ObservationIgnored private let taps = AppVolumeTapManager()
    // アプリごとの音量・ミュート設定。一覧から消えても保持し、再び音を出したときに復元する。
    // 100%・ミュートなしのアプリは持たない
    @ObservationIgnored private var settings: [String: AppSetting] = [:]
    // アプリID → Core Audio のプロセスオブジェクト（音を出していないものも含む）
    @ObservationIgnored private var processes: [String: [AudioObjectID]] = [:]
    @ObservationIgnored private var detected: [DetectedAudioApp] = []
    // アプリID → 音が止まった時刻（猶予時間の計算用）
    @ObservationIgnored private var stoppedAt: [String: Date] = [:]
    @ObservationIgnored private var graceExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var chromeBridge: ChromeTabBridge?
    // Chrome 拡張から届いた最新のタブ一覧
    @ObservationIgnored private var chromeTabs: [AudioTab] = []
    // 検出結果や拡張からの通知で apps を作り直している最中（このときは拡張へ操作を送り返さない）
    @ObservationIgnored private var isRebuildingApps = false

    /// 実際に音を出しているアプリを Core Audio から検出し、音量を制御する
    init() {
        controlsDevices = true
        settings = SettingsStore.load()
        launchAtLogin = LaunchAtLogin.isEnabled
        readMasterVolume()

        outputObserver = OutputDevice.observe(
            onDeviceChange: { [weak self] in
                guard let self else { return }
                readMasterVolume()
                taps.outputDeviceChanged(gains: gains, processes: processes, activeAppIDs: activeAppIDs)
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

        let chromeBridge = ChromeTabBridge()
        chromeBridge.onTabsChange = { [weak self] tabs in
            guard let self else { return }
            chromeTabs = tabs
            rebuildApps()
        }
        chromeBridge.onConnectionChange = { [weak self] isConnected in
            self?.isChromeExtensionConnected = isConnected
        }
        self.chromeBridge = chromeBridge
        chromeBridge.start()

        // 読み込み済みの拡張を、この Mixer に同梱した最新版に更新しておく
        if ChromeExtensionInstaller.isExported {
            ChromeExtensionInstaller.exportExtension()
        }
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
        let wasOutputting = Set(self.detected.filter(\.isOutputting).map(\.id))
        let isOutputting = Set(detected.filter(\.isOutputting).map(\.id))
        let now = Date()
        for id in wasOutputting.subtracting(isOutputting) {
            stoppedAt[id] = now
        }
        for id in isOutputting {
            stoppedAt[id] = nil
        }

        self.detected = detected
        processes = Dictionary(uniqueKeysWithValues: detected.map { ($0.id, $0.processObjectIDs) })
        // 終了したアプリは猶予なしで消す
        stoppedAt = stoppedAt.filter { processes[$0.key] != nil }
        rebuildApps()
    }

    /// 音を出している、または止まってから猶予時間内のアプリ
    private var activeAppIDs: Set<String> {
        let now = Date()
        let recentlyStopped = stoppedAt.filter { now.timeIntervalSince($0.value) < Self.idleGracePeriod }.keys
        return Set(detected.filter(\.isOutputting).map(\.id)).union(recentlyStopped)
    }

    /// 猶予時間が切れる頃に一覧を作り直し、行を消して音量調整を止める
    private func scheduleGraceExpiry() {
        graceExpiryTask?.cancel()
        let now = Date()
        stoppedAt = stoppedAt.filter { now.timeIntervalSince($0.value) < Self.idleGracePeriod }
        guard let earliest = stoppedAt.values.min() else { return }

        let delay = Self.idleGracePeriod - now.timeIntervalSince(earliest)
        graceExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.rebuildApps()
        }
    }

    /// 検出結果・保存した設定・Chrome のタブから、表示する一覧を作り直す
    private func rebuildApps() {
        isRebuildingApps = true
        defer { isRebuildingApps = false }

        scheduleGraceExpiry()
        let active = activeAppIDs
        apps = detected
            // Chrome はタブをすべてミュートすると音が止まるので、タブがある間は表示し続ける
            .filter { active.contains($0.id) || ($0.id == Self.chromeID && !chromeTabs.isEmpty) }
            .map { detected in
                var app = AudioApp(id: detected.id, name: detected.name)
                if let setting = settings[detected.id] {
                    app.volume = setting.volume
                    app.isMuted = setting.isMuted
                }
                if detected.id == Self.chromeID {
                    app.tabs = chromeTabs
                }
                return app
            }
        Self.logger.debug("表示中: \(self.apps.map(\.id), privacy: .public)")
    }

    private func appsDidChange(from oldApps: [AudioApp]) {
        syncTaps()
        guard controlsDevices, !isRebuildingApps else { return }
        sendTabChanges(from: oldApps)
    }

    /// パネルでタブのスライダー・ミュートを操作したら、Chrome 拡張へ伝える
    private func sendTabChanges(from oldApps: [AudioApp]) {
        guard let tabs = apps.first(where: { $0.id == Self.chromeID })?.tabs else { return }
        let oldTabs = oldApps.first { $0.id == Self.chromeID }?.tabs ?? []

        for tab in tabs {
            guard let old = oldTabs.first(where: { $0.id == tab.id }) else { continue }
            if old.isMuted != tab.isMuted {
                chromeBridge?.setMuted(tabID: tab.id, muted: tab.isMuted)
            }
            if old.volume != tab.volume {
                chromeBridge?.setVolume(tabID: tab.id, volume: tab.volume)
            }
        }
        // 拡張から次の一覧が届く前に作り直されても、操作が巻き戻らないようにする
        chromeTabs = tabs
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.set(enabled)
        refreshLaunchAtLogin()
    }

    /// システム設定側で変えられることもあるので、パネルを開くたびに読み直す
    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private var gains: [String: Float] {
        settings.mapValues { $0.isMuted ? 0 : Float($0.volume) }
    }

    private func syncTaps() {
        guard controlsDevices else { return }

        var newSettings = settings
        for app in apps {
            let setting = AppSetting(volume: app.volume, isMuted: app.isMuted)
            newSettings[app.id] = setting.isDefault ? nil : setting
        }
        if newSettings != settings {
            settings = newSettings
            SettingsStore.save(settings)
        }
        taps.sync(gains: gains, processes: processes, activeAppIDs: activeAppIDs)
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
