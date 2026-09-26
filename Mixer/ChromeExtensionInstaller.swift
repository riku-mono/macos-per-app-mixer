//
//  ChromeExtensionInstaller.swift
//  Mixer
//

import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mixer", category: "chrome")

/// Mixer.app に同梱した Chrome 拡張を Chrome から読める場所へ書き出し、読み込みの準備をする。
/// Chrome はストア外の拡張を他のアプリから勝手に入れさせないため、最後の読み込みだけはユーザーが行う
enum ChromeExtensionInstaller {
    static var isChromeInstalled: Bool {
        chromeURL != nil
    }

    /// ~/Library/Application Support/Mixer/ChromeExtension。
    /// コンテナ内だと Chrome が読むたびに「他のアプリのデータへのアクセス」の確認が出るため、
    /// サンドボックスの外（Mixer.entitlements で許可したフォルダ）に置く
    static var folderURL: URL {
        // サンドボックス内では NSHomeDirectory() がコンテナを指すので、本物のホームを使う
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appending(path: "Library/Application Support/Mixer/ChromeExtension", directoryHint: .isDirectory)
    }

    /// 以前に書き出したことがあるか（= 拡張を読み込み済みの可能性がある）
    static var isExported: Bool {
        FileManager.default.fileExists(atPath: folderURL.path)
    }

    /// 同梱の拡張で上書きする。Mixer を更新したら、次に Chrome が読み込むときに拡張も新しくなる
    @discardableResult
    static func exportExtension() -> Bool {
        guard let source = Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) else {
            logger.error("同梱の Chrome 拡張が見つかりません")
            return false
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: folderURL.path) {
                try fileManager.removeItem(at: folderURL)
            }
            try fileManager.copyItem(at: source, to: folderURL)
            return true
        } catch {
            logger.error("Chrome 拡張を書き出せませんでした: \(error)")
            return false
        }
    }

    /// 拡張を書き出して Finder で表示し、Chrome の拡張機能ページを開く
    static func prepareInstall() {
        guard exportExtension() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        if let chromeURL, let pageURL = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([pageURL], withApplicationAt: chromeURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static var chromeURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: MixerModel.chromeID)
    }
}
