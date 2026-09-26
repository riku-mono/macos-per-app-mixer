# セキュリティポリシー

## 脆弱性の報告

脆弱性を見つけた場合は、公開の Issue ではなく、GitHub の
[Private vulnerability reporting](https://github.com/riku-mono/macos-per-app-mixer/security/advisories/new)
から非公開で報告してください。

## このアプリが扱うもの

- **システムオーディオ録音の権限**：アプリごとの音量を変えるために各アプリの音声を取り込みますが、音声を保存・送信することはありません
- **ローカルの WebSocket サーバー**：Chrome 拡張との通信のため `127.0.0.1:47219` で待ち受けます。Mac の外からは接続できず、`chrome-extension://` 以外の Origin からの接続は拒否します

## 対象バージョン

最新の `main` ブランチのみを対象とします。
