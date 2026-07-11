# AX kAXPositionAttribute は CG グローバル y-down を返す (実機マトリクス検証)

## 判明した事実

- macOS の AX API `kAXPositionAttribute` が返すウィンドウ位置は **CG グローバル論理座標
  (top-left 原点, y-down)** であり、`CGWindowListCopyWindowInfo` の `kCGWindowBounds` と
  完全一致する
- **負の y 領域 (primary より上に配置された外部モニタ) のウィンドウでも y-down のまま**。
  y-up (Cocoa) への反転は起きない
- DR-0009 決定 3 の「AX は y-up 前提、入力アダプタで変換」は実機と乖離しており、
  identity 変換が正 (DR-0011 で訂正済み)
- 注意: **primary モニタ上のウィンドウだけを見ても y-up / y-down は区別できない**
  (primary は両解釈で値域が一致するため)。この種の検証は必ず負 y 領域のモニタを含めること

## 実用的な示唆 / ベストプラクティス

- AX frame → display 解決は座標変換なしで `CGDisplayBounds` と直接突合してよい
- 座標系の実機検証は「primary 上のサンプル」だけでは無意味。マルチモニタの
  非 primary (特に負座標領域) を必ずサンプルに含める

## 検証の詳細

### 環境 (2026-07-12)

| display | CGDisplayBounds (y-down) | 備考 |
|---|---|---|
| Built-in Retina (cgid=1, main) | (0, 0, 2056, 1329) | primary |
| LG ULTRAGEAR+ (cgid=2) | (-517, -1440, 3440, 1440) | primary の上に配置 (負 y) |

### 方法

各 GUI アプリの `kAXFocusedWindowAttribute` → `kAXPositionAttribute` /
`kAXSizeAttribute` を取得し、同一ウィンドウ (pid + サイズ一致) の
`CGWindowListCopyWindowInfo` の `kCGWindowBounds` (CG y-down の正解データ) と突合。

### 結果: 14 アプリ全一致 (うち LG = 負 y 領域 4 件)

| app | AX pos | CGWindowList bounds | 判定 |
|---|---|---|---|
| Antigravity | (668, 375) | 同値 | y-down 一致 |
| Slack | (0, 39) | 同値 | y-down 一致 |
| メッセージ | (897, 132) | 同値 | y-down 一致 |
| **Messenger (LG)** | **(-349, -1199)** | 同値 | y-down 一致 |
| **Finder (LG)** | **(394, -1129)** | 同値 | y-down 一致 |
| OrbStack | (703, 212) | 同値 | y-down 一致 |
| **1Password (LG)** | **(-285, -1107)** | 同値 | y-down 一致 |
| Xcode | (778, 214) | 同値 | y-down 一致 |
| **Google Chrome Beta (LG)** | **(48, -1410)** | 同値 | y-down 一致 |
| Claude | (207, 250) | 同値 | y-down 一致 |
| Code | (0, 39) | 同値 | y-down 一致 |
| アクティビティモニタ | (479, 44) | 同値 | y-down 一致 |
| 時計 | (516, 170) | 同値 | y-down 一致 |
| Ghostty | (0, 39) | 同値 | y-down 一致 |

### 併せて確認した end-to-end 再現

NSWorkspace.didActivateApplicationNotification → AX frame → display 解決
(FocusFlashObserver と同一ロジック) をアプリ外で再現し、LG 上のウィンドウが
正しく LG の hardwareId (`7789-40587-480315-1`) に解決されることを、
時計 (内蔵) ↔ Messenger (LG) の交互アクティブ化で確認した (contains 判定、
fallback 不使用)。
