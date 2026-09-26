# macos-per-app-mixer

アプリごとに音量を調整できる、メニューバー常駐の macOS アプリです。
Chrome は拡張機能と連携して、タブごとの音量・ミュートまで操作できます。

macOS には標準でアプリ別の音量ミキサーがないため、SwiftUI と Core Audio の学習を兼ねて作りました。

## 機能

- メニューバーのアイコンからパネルを開き、音を出しているアプリを自動で一覧表示
- アプリごとの音量スライダー（0〜100%）とミュート（アイコンをクリック）
- 全体音量スライダー（出力デバイスの音量と連動。音量キーでの変更も反映）
- Chrome のタブごとの音量・ミュート（同梱の Chrome 拡張を使用）
- 設定の保存（アプリを再起動しても音量・ミュートを復元）
- ログイン時に自動起動
- 一時停止してもすぐには行が消えない（音が止まってから 10 秒間は表示）

## 動作環境

- macOS 27 以降
- Xcode 27 / Swift 6.4（ビルドする場合）
- Chrome（タブ連携を使う場合）

## ビルドと実行

1. `Mixer.xcodeproj` を Xcode で開く
2. Signing & Capabilities で Team を自分のものか None（Sign to Run Locally）にする
3. ⌘R で実行すると、メニューバーにアイコン（スライダー）が出る

初めてアプリの音量を 100% 未満にしたとき、「システムオーディオ録音」の許可を求められます。
アプリの音を取り込んで音量を掛け直すために必要です。

普段使いするときは Product > Archive で書き出し、`/Applications` に置いてから「ログイン時に起動」をオンにしてください
（Xcode から実行したアプリは置き場所が変わることがあり、ログイン項目が正しく働かないため）。

## Chrome のタブ連携

パネル下部の「Chrome 拡張: 未接続」の「追加…」から、手順に沿って拡張を読み込みます。

1. 「Chrome と拡張フォルダを開く」を押す
2. `chrome://extensions` の右上で「デベロッパー モード」をオンにする
3. Finder に表示された `ChromeExtension` フォルダを拡張機能ページへドラッグする

つながると「接続中」になり、Chrome の行の下に音を出しているタブが並びます。
拡張のしくみは [ChromeExtension/README.md](ChromeExtension/README.md) を参照してください。

## しくみ

```
Core Audio（プロセス一覧）
  → AudioProcessMonitor：音を出しているアプリを検出（Helper は親アプリにまとめる）
  → MixerModel ⇄ MixerView（SwiftUI のパネル）
  → AppVolumeTap：Process Tap でアプリの音を取り込み、音量を掛けてスピーカーへ出力し直す

Chrome 拡張（ChromeExtension/）
  ⇄ ChromeTabBridge（ws://127.0.0.1:47219）：タブ一覧を受け取り、ミュート・音量の操作を送る
```

| ファイル | 役割 |
| --- | --- |
| `AudioProcessMonitor.swift` | Core Audio のプロセス一覧を監視し、音を出しているアプリを検出する |
| `AppVolumeTap.swift` | Process Tap と Aggregate Device でアプリの音を取り込み、音量を掛けて出力し直す |
| `OutputDevice.swift` | 既定の出力デバイスの音量の読み書きと、デバイス切り替えの監視 |
| `ChromeTabBridge.swift` | Chrome 拡張と WebSocket（ループバックのみ）でつながる |
| `ChromeExtensionInstaller.swift` | 同梱の Chrome 拡張を書き出し、読み込みを案内する |
| `Settings.swift` | 設定の保存（UserDefaults）とログイン時の自動起動（SMAppService） |
| `MixerModel.swift` / `MixerView.swift` | 状態管理と UI |

- 音量 100%・ミュートなしのアプリには Tap を作らないので、遅延も負荷も増えません
- ミュートしたアプリは Tap だけで消音し、音量を下げたアプリも音を出している間だけ処理を動かします
- Chrome 拡張からの接続は `127.0.0.1` のみで待ち受け、`chrome-extension://` からの接続だけを受け付けます

## デバッグ

ログは Console.app（または Xcode のコンソール）で、サブシステム `io.github.riku-mono.Mixer` とカテゴリで絞り込めます。

| カテゴリ | 内容 |
| --- | --- |
| `audio` | 音を出しているアプリの検出 |
| `tap` | 音量制御（Tap）の作成・失敗 |
| `model` | パネルに表示中のアプリ |
| `chrome` | Chrome 拡張との接続 |
| `settings` | 設定の保存・ログイン項目 |

## 制限

- 出力デバイスはステレオを想定しています（5.1ch などの多チャンネル出力では正しく鳴らない場合があります）
- 音量を下げたアプリが、しばらく止まってから再び鳴り始めると、最初の一瞬が無音になることがあります
- Safari の音は WebKit のプロセスから出るため、「Safari」ではなく別名で表示されます
- タブごとの音量は `<video>` / `<audio>` の音だけに効きます（Web Audio API の音はミュートのみ）
- タブ連携は Chrome 専用です

## ライセンス

[MIT](LICENSE)
