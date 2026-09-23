# ChaiNet

原生 iOS 網路診斷工具（Speed Test、Network Toolbox、Root Cause Diagnostics）與其 Go 測速後端。

- [`ChaiNet/`](ChaiNet/README.md) — iOS App（Swift 6、SwiftUI、Swift Concurrency、Network.framework、SwiftData、Charts）
- [`backend/`](backend/README.md) — Go 測速伺服器（/ping /download /upload /health /info、UDP echo、IPv4/IPv6、HTTP/2、選用 HTTP/3）
- `.github/workflows/ios.yml` — 在 macOS runner 上編譯未簽名 `ChaiNet-unsigned.ipa` 並上傳為 Artifact
- `.github/workflows/backend.yml` — 後端測試與建置
