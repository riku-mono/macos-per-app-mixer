//
//  ChromeTabBridge.swift
//  Mixer
//

import Foundation
import Network
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Mixer", category: "chrome")

/// Chrome 拡張（ChromeExtension/）と WebSocket でつながり、
/// 音の出ているタブの一覧を受け取り、タブのミュート・音量の操作を送る
final class ChromeTabBridge {
    /// ChromeExtension/background.js の MIXER_URL と合わせること
    static let port: NWEndpoint.Port = 47219

    var onTabsChange: (([AudioTab]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private var listener: NWListener?
    // 操作の送り先。最後にタブ一覧を送ってきた接続（Origin の確認で弾かれた接続は何も送れない）
    private var connection: NWConnection?

    func start() {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(.main) { _, headers in
            // Web ページも localhost の WebSocket に接続できてしまうため、
            // ブラウザが付ける Origin を見て Chrome 拡張からの接続だけを受け付ける
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let isExtension = origin.hasPrefix("chrome-extension://")
            return NWProtocolWebSocket.Response(status: isExtension ? .accept : .reject, subprotocol: nil, additionalHeaders: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        // 127.0.0.1 だけで待ち受け、他の Mac からは接続させない
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    logger.error("待ち受けに失敗: \(error)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            logger.error("待ち受けを開始できませんでした: \(error)")
        }
    }

    func setMuted(tabID: Int, muted: Bool) {
        send(Command(type: "setMuted", tabId: tabID, muted: muted))
    }

    func setVolume(tabID: Int, volume: Double) {
        send(Command(type: "setVolume", tabId: tabID, volume: volume))
    }

    // MARK: - 接続

    private func accept(_ newConnection: NWConnection) {
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .failed, .cancelled:
                // 拡張との接続が切れたらタブは不明になるので空にする
                if connection === newConnection {
                    connection = nil
                    logger.debug("拡張との接続が切れました")
                    onConnectionChange?(false)
                    onTabsChange?([])
                }
            default:
                break
            }
        }
        newConnection.start(queue: .main)
        receive(on: newConnection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()  // → stateUpdateHandler の .cancelled で後始末する
                return
            }
            if let data {
                handle(data, from: connection)
            }
            receive(on: connection)
        }
    }

    // MARK: - メッセージ

    private struct Incoming: Decodable {
        struct Tab: Decodable {
            let id: Int
            let title: String
            let muted: Bool
            let volume: Double
        }
        let type: String
        let tabs: [Tab]?
    }

    private struct Command: Encodable {
        let type: String
        let tabId: Int
        var muted: Bool?
        var volume: Double?
    }

    private func handle(_ data: Data, from sender: NWConnection) {
        guard let message = try? JSONDecoder().decode(Incoming.self, from: data) else {
            logger.error("読めないメッセージを受け取りました")
            return
        }
        guard message.type == "tabs", let tabs = message.tabs else { return }  // ping など
        if connection !== sender {
            connection?.cancel()  // 拡張が再接続してきたら古い接続は閉じる
            connection = sender
            logger.debug("拡張とつながりました")
            onConnectionChange?(true)
        }
        logger.debug("タブ一覧: \(tabs.count) 件")
        onTabsChange?(tabs.map { AudioTab(id: $0.id, title: $0.title, volume: $0.volume, isMuted: $0.muted) })
    }

    private func send(_ command: Command) {
        guard let connection, let data = try? JSONEncoder().encode(command) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "command", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
