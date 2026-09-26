# Mixer Tab Bridge（Chrome 拡張）

Mixer のパネルから、Chrome のタブごとに音量とミュートを操作するための拡張です。
Mixer.app とは `ws://127.0.0.1:47219` の WebSocket でつながります（Mac の外には出ません）。

## インストール

1. Chrome で `chrome://extensions` を開く
2. 右上の「デベロッパー モード」をオンにする
3. 「パッケージ化されていない拡張機能を読み込む」でこの `ChromeExtension` フォルダを選ぶ
4. Mixer を起動しておくと、30 秒以内に自動で接続する

JS を書き換えたら、`chrome://extensions` で拡張の再読み込みボタンを押し、開いているタブも再読み込みする。

## 仕組み

| ファイル | 役割 |
| --- | --- |
| `background.js` | Mixer と接続し、音の出ているタブの一覧を送る。ミュートは `chrome.tabs.update`、音量はタブ内のスクリプトへ伝える |
| `volume-bridge.js` | 拡張の世界からページの世界へ音量を渡す |
| `volume-main.js` | ページの `<video>` / `<audio>` の音量にタブの音量を掛ける |

## 制限

- 音量が効くのは `<video>` / `<audio>` の音だけ。Web Audio API で鳴らす音（ゲームなど）には効かない（ミュートは効く）
- Chrome 専用。Brave など他の Chromium ブラウザに入れると、タブが Chrome の行に表示されてしまう
- 動画プレーヤー内蔵の音量つまみ（`controls` 属性）で変えた音量には、タブの音量が掛からないことがある
