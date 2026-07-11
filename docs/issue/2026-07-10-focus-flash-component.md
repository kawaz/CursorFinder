---
title: 第3コンポーネント「フォーカスフラッシュ」— ウィンドウフォーカス変更の視覚エフェクト
status: wip
category: design
created: 2026-07-10T11:23:41+09:00
last_read: 2026-07-10T12:15:00+09:00
open_entered:
wip_entered: 2026-07-10T12:15:00+09:00
blocked_entered:
pending_entered:
discarded_entered:
resolved_entered:
discard_reason:
pending_reason:
close_reason:
blocked_by:
origin: kawaz発案
---

# 第3コンポーネント「フォーカスフラッシュ」— ウィンドウフォーカス変更の視覚エフェクト

## 概要

ウィンドウフォーカスが切り替わった時に「どのモニタのどのウィンドウにフォーカスが移ったか」を即座に視認できるエフェクトを、対象モニタ全体やウィンドウ枠にオーバーレイ表示する。

レーザー (カーソル可視化)・ワープ (カーソル移動補助) に続く、「オーバーレイ描画でアクセシビリティを良くする」第3のコンポーネントとして同アプリに追加する (kawaz 発案 2026-07-10、マウスとは独立)。

## 背景

現状のオーバーレイ機能はマウスカーソルの可視化・移動補助に特化している。マルチモニタ環境では「今どのウィンドウがフォーカスされているか」を見失いやすく、キーボードショートカット (Cmd+Tab 等) でのウィンドウ切替時や外部要因 (通知・他アプリのフォーカス奪取) での切替時に、視線移動先が分かりにくい。マウス操作を介さないフォーカス変更に対するアクセシビリティ支援として、視覚エフェクトによる即時フィードバックを追加する。

## 実装方針メモ

- `NSWorkspace.didActivateApplicationNotification` + AX observer (`kAXFocusedWindowChangedNotification`) でフォーカス変更を検出
- `.focusedWindowChanged(app, windowFrame)` action として形式化 → 減衰アニメーションの effect/view
- ウィンドウ枠取得は AX API (権限は既存の tap と同じ AX で追加要求なし)
- AX のフレームは y-up なので入力アダプタで即 CG y-down 変換 (DR-0005 の境界規則に従う)

## 受け入れ条件

- [ ] ウィンドウフォーカス変更 (アプリ切替 / 同一アプリ内ウィンドウ切替) を検出できる
- [ ] フォーカス移動先のモニタ・ウィンドウ枠に視覚エフェクト (オーバーレイ) が表示される
- [ ] エフェクトは減衰アニメーションで自動的に消える
- [ ] マウス操作系 (レーザー・ワープ) の既存処理と独立して動作する
- [ ] AX 座標系 (y-up) → CG 座標系 (y-down) の変換が入力アダプタ層で行われている

## TODO

- [x] DR-0009 起票 (Proposed)
- [x] Phase A 実装 (Core Action / reducer / Overlay 描画 / 入力アダプタ / メニュートグル)
- [x] Phase A の unit test (Core reducer 3 ケース + App resolveFocusDisplay 4 ケース + VM 3 ケース)
- [ ] Phase A 実機確認 (実機確認待ちリスト参照、close 前提)
- [x] Phase B 方針裁定: DR-0011 (ウィンドウ枠震源の波動エフェクト、mm 空間・隣接物理レイアウト)
- [x] Phase B 実装 (feature/focus-flash-wave ブランチ、AXObserver によるウィンドウ単位フォーカス観測含む)、`just ci` green
- [ ] Phase B 実機確認 (runbook `v3-dev-run.md` の「フォーカスフラッシュ + 波動」節の観点)
- [ ] チューニング (duration / band / opacity / 色 / 主従バランス)
- [ ] main マージ判断

## Phase A 実装記録 (2026-07-10)

### 選定した frame 取得方式: AX 経路 (kAXFocusedWindowAttribute)

**理由**:
1. DR-0009 決定 2/3/4 が AX 経路を仕様レベルで前提としている
2. 既存アプリは EventTapController 起動時に AX 権限を取得済み (`PermissionMonitor.isTrusted`)。追加権限要求なし
3. CGWindowList 経路は「最前面ウィンドウ」の判定に owningPID フィルタ + z-order 層フィルタが必要 (menubar / dock / スクリーンショット系のシステム UI window が z-order 上位に混ざるため)
4. Phase B (ウィンドウ枠のアウトライン強調) でも AX からの frame 取得が必要。経路統一で Phase A→B の実装コストが下がる

### 座標系の実装ノート (DR-0009 決定 3 の実機観測との乖離)

DR-0009 決定 3 は「AX のウィンドウフレームは y-up」と記述しているが、macOS の実測では
`kAXPositionAttribute` は **CG グローバル (top-left y-down)** を返す (Cocoa/AppKit 系アプリでは
AX 実装が既に CG 座標を扱う)。`FocusFlashObserver.convertAXFrameToCGGlobal` は identity 変換
(現時点で最も妥当な仮説) として実装し、実機で y 反転バグが観測された場合はこの 1 関数を
y-flip 実装に差し替える (DR-0005 の「境界変換を 1 か所に集約」規律に従う)。実機確認結果次第で
DR-0009 決定 3 の注記を訂正する候補として journal / DR 追記の余地を残す。

### 実装ファイル

- **Core (Swift)**:
  - `Core/Sources/LaserGuideCore/Action.swift`: `.focusedDisplayChanged(displayId: String)` case 追加
  - `Core/Sources/LaserGuideCore/AppState.swift`: `FocusFlashState { displayId, generation }` + `AppState.focusFlash: FocusFlashState?` 追加
  - `Core/Sources/LaserGuideCore/Store.swift`: `reduceFocusedDisplayChanged` を追加 (generation を単調 &+ で上書き、effect なし)
  - `Core/Tests/LaserGuideCoreTests/StoreReduceTests.swift`: 初回発火 / 同一 displayId 連続発火 / cross-display 切替の 3 ケース追加
- **App (Swift)**:
  - `App/Sources/LaserGuideDev/FocusFlashObserver.swift` (新規): NSWorkspace + AX 経路の入力アダプタ + `resolveFocusDisplay` 純関数
  - `App/Sources/LaserGuideDev/OverlayViewModel.swift`: `FocusFlashPresentation` + `focusFlash` @Published + generation 差分検知で `startFocusFlash`、`clearFocusFlash` (機能 off 時用)
  - `App/Sources/LaserGuideDev/LaserOverlayView.swift`: 対象 display 一致時のみ描画する `focusFlashView` (systemBlue 24px stroke + 8px blur)
  - `App/Sources/LaserGuideDev/AppDelegate.swift`: メニュー「フォーカスフラッシュ」トグル (既定 off) + `applyFocusFlash` で observer 起動/停止 + VM クリア
  - `App/Tests/LaserGuideDevTests/FocusFlashObserverTests.swift` (新規): `resolveFocusDisplay` 4 ケース
  - `App/Tests/LaserGuideDevTests/OverlayViewModelTests.swift`: focus flash 立ち上げ / 再発火 / clear の 3 ケース追加

### 実装上の設計判断 (根拠)

| 項目 | 値 | 根拠 |
|---|---|---|
| generation の初期値 | 1 (初回発火時) | 0 は「未発火」との区別のため予約 |
| generation の増分 | `&+ 1` (overflow 折り返し) | 純関数、precondition 失敗を避け無限運転で破綻しない |
| フェード時間 | 0.5s | task 指示「~0.5s でフェードアウト」、`focusFlashDuration` var で調整可 |
| 初期不透明度 | 0.6 | クリックサークル (0.6) と揃え、体感の一貫性 |
| 色 | `Color.blue` (systemBlue) | macOS システムのフォーカス強調と親和性、レーザーの赤系と競合しない |
| 縁の厚み | 24px + 8px blur | ウィンドウ枠 (Phase B) と重ねた時にモニタ縁の方が薄く広く光る差別化 |
| 減衰の刻み | 30ms 刻みの Timer | クリックサークル既存パターンを踏襲、キャリブレーション画面 main run loop 占有下でも予測可能な速度 |
| default 値 | off (オプトイン) | Phase A は実機フィードバック待ちの新機能、`presentationModeEnabled` と同じ流儀 |
| メニュー disabled 化 | AX 権限なし時 | menuBuilder 生成時に `isTrusted(prompt: false)` で判定 |
| observer の scope | AppDelegate 保持 | overlay 再構築 (`rebuildOverlays`) から独立 (observer は overlay に依存しない) |
| resolveFocusDisplay の fallback | 中心距離最小の display | フルスクリーン化直後 / 境界跨ぎで発火が空振りしないため |

### 残タスク (Phase B)

- Action payload に `windowFrame: LogicalRect?` を追加し、window frame を Core 層まで運ぶ
- AX 由来 frame → view local → SwiftUI stroke でウィンドウ枠アウトライン強調を描く
- ウィンドウ枠色は systemBlue の別トーン (現状のモニタ縁と識別可能に)
- モニタ縁とウィンドウ枠の両方を同時に光らせる場合の描画順序 (縁の上にウィンドウ枠)

### 実機確認待ち (close 前提)

Phase A の unit test は Core 3 ケース + App 7 ケース (VM 3 + Observer 4) で描画・reducer 側を
固定できたが、以下は実機依存で unit test では覆えない (Cmd-Tab や NSWorkspace 通知の実体験):

1. Cmd-Tab で対象モニタが正しく光るか (単純経路)
2. 同一アプリ内のウィンドウ切替 (Cmd-\` 等) でフラッシュが起きるか
   - Phase A は `NSWorkspace.didActivateApplicationNotification` のみ購読なので、同一アプリ内の
     ウィンドウ切替は原理的に発火しない。この観測は「発火しないことの確認」で、Phase B の
     kAXFocusedWindowChangedNotification observer 追加 (DR-0009 決定 2) 待ち
3. 別モニタへの切替で generation が進み、対象モニタ側だけが光る (対称性 = 前のモニタは光り続けない)
4. Cmd-Tab 連打 (連続切替) で generation 上書きが視覚的に自然か (フェードが重ならない / チラつかない)
5. 複数モニタで同一アプリの複数ウィンドウがある時、フォーカス先モニタ判定が正しいか
6. フェード時間 0.5s の体感 (長すぎ / 短すぎ → 数値調整)
7. 縁の色・厚み・blur の体感 (`Color.blue` が既存レーザー色 = 赤系と競合しないか、24px + 8px blur の
   グロー感がモニタ全体の縁として自然に見えるか)
8. AX 権限なし時のメニュー disabled 表示 (`toolTip: "アクセシビリティ権限が必要です"`)
9. Y 座標系: `convertAXFrameToCGGlobal` の identity 変換が正しいか (y-flip が要らないか) の実機観測。
   誤りなら DR-0009 決定 3 の記述 + convertAXFrameToCGGlobal 実装を対で訂正
10. `presentationClickMonitor` と `focusFlashObserver` の共存 (両 on にした時に干渉しないか)

### 経路差の観察点 (AX 経路の degrade)

- AXUIElementCopyAttributeValue が失敗するアプリ (AX 非対応 UI・Finder のバックグラウンドウィンドウ・
  一部の Electron 系) では focus flash が発火しない可能性がある。実機で「特定アプリだけ光らない」
  症状が観測されたら AX 失敗ケースとして journal に記録し、Phase B で fallback 経路
  (CGWindowList / NSWorkspace.frontmostApplication の bundleIdentifier 一致検査) を検討する

## Phase B 方針裁定・実装記録 (2026-07-12)

Phase A の「ウィンドウ枠のアウトライン強調」計画 (上記 TODO / 実装ノート内の Phase B 記述) は
実機調査を経て以下の通り改訂された。旧計画の記述は経緯として残すが、正の方針は DR-0011。

1. 2026-07-12、「LaserGuide でエフェクトが出ない」報告を調査した結果、Phase A のモニタ縁仕様と
   オーダー (ウィンドウ枠) の乖離が判明
2. kawaz 裁定により Phase B = **ウィンドウ枠震源の波動エフェクト** (mm 空間・隣接物理レイアウト)
   に確定、DR-0011 (`docs/decisions/DR-0011-focus-wave-mm-space.md`) 起票・Accepted
3. `feature/focus-flash-wave` ブランチで実装完了 (AXObserver によるウィンドウ単位フォーカス観測を
   含む)。`just ci` green、実機確認待ち
4. 残 TODO: 実機確認 (runbook `v3-dev-run.md` の「フォーカスフラッシュ + 波動」節の観点)、
   チューニング (duration / band / opacity / 色 / 主従バランス)、main マージ判断

## 設計検討

component 追加の設計判断 (責務分離・既存 2 コンポーネントとの関係・DR 起票要否) は着手時に検討する。
→ DR-0009 として起票済み (Proposed 2026-07-10)。Phase A の実装記録は本 issue の上記セクションで管理。
Phase B の方針改訂は DR-0011 として起票済み (Accepted 2026-07-12)。
