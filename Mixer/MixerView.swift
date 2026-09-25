//
//  MixerView.swift
//  Mixer
//

import SwiftUI
 
struct MixerView: View {
    @Bindable var model: MixerModel
 
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("サウンドミキサー")
                .font(.headline)
 
            // 全体音量
            HStack {
                Image(systemName: "speaker.wave.3.fill")
                    .frame(width: 28)
                Slider(value: $model.masterVolume)
            }
 
            Divider()
 
            // アプリごとの行
            if model.apps.isEmpty {
                Text("音を出しているアプリはありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach($model.apps) { $app in
                AppVolumeRow(app: $app)
            }

            Divider()

            // フッター（F-07）
            HStack {
                Spacer()
                Button("終了") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
                .help("Mixer を終了")
            }
        }
        .padding()
        .frame(width: 300)
    }
}
 
struct AppVolumeRow: View {
    @Binding var app: AudioApp
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // アイコンをクリックでミュート切り替え
                Button {
                    app.isMuted.toggle()
                } label: {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .opacity(app.isMuted ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .help(app.isMuted ? "ミュート解除" : "ミュート")
                .accessibilityLabel("\(app.name)を\(app.isMuted ? "ミュート解除" : "ミュート")")

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(app.name)
                            .font(.subheadline)
                        // 子の音源（タブ）があるときだけ開閉ボタンを出す
                        if !app.tabs.isEmpty {
                            Button {
                                withAnimation(.snappy) { isExpanded.toggle() }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(isExpanded ? "タブを隠す" : "タブを表示")
                        }
                        Spacer()
                        Text(app.isMuted ? "ミュート" : "\(Int(app.volume * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $app.volume)
                        .disabled(app.isMuted)
                }
            }

            if isExpanded {
                ForEach($app.tabs) { $tab in
                    TabVolumeRow(tab: $tab, isParentMuted: app.isMuted)
                }
                // アイコン(28) + 間隔(10) 分だけ字下げして親の配下に見せる
                .padding(.leading, 38)
            }
        }
    }
}

/// アプリ配下のタブ1つ分の行（親アプリより一段小さく表示）
struct TabVolumeRow: View {
    @Binding var tab: AudioTab
    let isParentMuted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                tab.isMuted.toggle()
            } label: {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 16)
                    .foregroundStyle(tab.isMuted ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .disabled(isParentMuted)
            .help(tab.isMuted ? "ミュート解除" : "ミュート")
            .accessibilityLabel("\(tab.title)を\(tab.isMuted ? "ミュート解除" : "ミュート")")

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tab.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(tab.isMuted ? "ミュート" : "\(Int(tab.volume * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $tab.volume)
                    .controlSize(.mini)
                    .disabled(isParentMuted || tab.isMuted)
            }
        }
        // 親がミュート中は子もまとめて薄くする
        .opacity(isParentMuted ? 0.35 : 1)
    }
}

#Preview {
    MixerView(model: .preview)
}
 
