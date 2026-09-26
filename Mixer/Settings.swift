//
//  Settings.swift
//  Mixer
//

import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mixer", category: "settings")

/// 1アプリ分の保存する設定
struct AppSetting: Codable, Equatable {
    var volume: Double
    var isMuted: Bool

    /// 100%・ミュートなしなら、保存しなくても同じ
    var isDefault: Bool {
        volume >= 0.999 && !isMuted
    }
}

/// アプリごとの音量・ミュートを UserDefaults に保存する
enum SettingsStore {
    private static let key = "appSettings"

    static func load() -> [String: AppSetting] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: AppSetting].self, from: data)
        } catch {
            logger.error("設定を読み込めませんでした: \(error)")
            return [:]
        }
    }

    static func save(_ settings: [String: AppSetting]) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: key)
        } catch {
            logger.error("設定を保存できませんでした: \(error)")
        }
    }
}

/// ログイン時の自動起動（システム設定 > 一般 > ログイン項目 に登録される）
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("ログイン項目を変更できませんでした: \(error)")
        }
        // ユーザーの承認待ちになったら、ログイン項目の設定画面を開く
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
