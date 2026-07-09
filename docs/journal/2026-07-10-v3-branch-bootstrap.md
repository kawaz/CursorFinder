# 2026-07-10 v3 ブランチ立ち上げ (実験リポからの合流初日)

- 経緯: 前身の実験リポ (MoonBit 構成) での全方位調査・再設計 DR 起草を経て、本リポの v2 先端 f372440 から v3 ブランチを作成。DR-0002〜0008 を移送 (移送時に配布バージョン v0.12.1 等の事実修正、v2 リライトはローカル v2 ブランチ上と訂正、v3 ブランチは f372440 から作成と明記)
- 実機検証: kawaz の手動実機計測 2 回 (delta マトリクス 659 イベント + カドなぞり 120 秒 5960 イベント) で、クランプの min/max 非対称 (max 側のみ -0.02px インセット、scale 非依存)・delta 符号の信頼性 (クランプ中も外向き符号を保持)・継ぎ目通過で境界値ちょうどのイベントは出ないこと (PX は所属モニタ変化でのみ検出)・カドの両軸独立クランプを確定 → docs/findings/2026-07-09-macos-display-api-verification.md に記録
- 幾何コア (Core/): 座標型分離・pose 可逆変換・y-down 隣接検出・物理投影/rate 写像・BX/PX 分類・PP/PB/BP/BB 判定を TDD 実装。コアレビューで Critical 2 (C-1, C-2) / Major 2 (M-1, M-2) / minor 6 (m-2〜m-7) の指摘 → 全修正。C-1 (OS 自動ペア専用の物理投影 PhysicalProjection 新設) は DR-0006 決定 2 の改訂 (OS 自動ペア = 物理投影 / ユーザセグメント = rate 写像) に発展
- store 層: DR-0004 の純関数 store (AppState/Action/Effect/reduce) を実装
- App/ (SPM executable `laserguide-dev`): CGEventTap runtime (同期 rewrite・tap リカバリ・権限 degrade)・v1 流用のオーバーレイ設定・mm 物理空間のレーザー描画・メニューバー最小 UI を新設。起動手順は docs/runbooks/v3-dev-run.md
- 現状: Core 54 テスト + App 4 テスト green (実行確認済み)、origin/v3 に push 済み。justfile (Core テストゲート付き push-wip) 新設
- 次: kawaz による実機起動確認 → キャリブレーション UI (WKWebView 純 view、Web プロトタイプ流用) → xcodeproj/CD 統合 → v1 設定 migration (DR-0007)

## 実機起動フィードバック 1 巡目 (2026-07-10 kawaz 手動確認 → 5 件対処)

### 前提

- kawaz 実機: 内蔵 Retina 2056×1329 @2x, mm/px 0.168 + LG ULTRAGEAR+ 3440×1440 @1x, mm/px 0.306。LG が内蔵の上に配置 (継ぎ目 y=0、x∈[0,2056] のみ通過可)
- 良かった点: LG 上のポインタに対して、内蔵の下 2 角から「内蔵の外にある LG 上のポインタ」へ物理配置に沿ってレーザーが正しく伸びること = pose / bounds / logical→canvas 変換の基本経路は正しい

### 修正 5 件

**#1 各モニタは自ディスプレイの 4 角からのレーザーだけ描く (仕様)**
LaserOverlayView が `for d in model.state.displays` で他ディスプレイの角も列挙して 8 本描いていた。自ディスプレイの `logicalBounds` の 4 隅のみに変更。

**#2 アイドルフェード (仕様)**
`OverlayViewModel.isMouseActive` フラグ + `inactivityThreshold=0.3s` の DispatchWorkItem debounce を追加。位置変化時のみ `markActive()` を呼び、閾値経過で `isMouseActive=false` → LaserOverlayView は描画スキップ。移動再開で即再表示。

**#3 テーパー付き三角形 (仕様)**
`LaserGeometry.taperApexPoint(from:to:standoff:)` を新設。target から standoff 距離だけ corner 方向へ戻した点を apex とする。`defaultStandoffDistance=40` (px) を定数として公開。台形の頂点辺は tipHalfWidth=0.5 で細く。

**#4 境界でレーザー焦点が残るバグ (根本原因調査)**

観測症状 = 実移動量よりはるかに微量の変化しか描画に反映されず、境界付近で左右ジリジリ。

根本原因: 旧 LaserOverlayView は `mouseDisplay.pose.toPhysical(mouseGlobal) → selfDisplay.pose.toLogical(mousePhysical)` の経路でポインタ位置を self overlay 用の描画座標へ変換していた。しかし Phase 1 の `DisplaySnapshotProvider` は各ディスプレイの pose を `translate=(0,0), scale=(mm/px)` で作るため、**display ごとに独立した mm frame** を持つ (cross-display の物理継ぎ目連続はキャリブレーション UI で別途整合させる、と DisplaySnapshotProvider.swift のヘッダに明示済み)。

この状態で「異なる display の pose を経由した mm↔logical 変換」を行うと、同じ CG global point が経路上の source display によって別の描画位置に落ちる。継ぎ目跨ぎで `mouseDisplay` が built-in ↔ LG で切り替わるたび、描画位置が `built-in scale / LG scale = 0.168/0.306 ≒ 0.548` 倍に圧縮された値に跳ぶ。仮説 (b) の「mm↔px 変換の二重適用で移動量が縮小」に相当。

寄与証拠 (regression test):
- `App/Tests/LaserGuideDevTests/LaserGeometryTests.swift::testTargetIsContinuousAcrossSeamOnLGOverlay_FixesBug4` で、y=+1 (built-in 側) と y=-1 (LG 側) の 2px 実移動に対し
  - 修正後 (`LaserGeometry.viewLocal`): 描画差 = 2.0px (連続)
  - 旧経路 (mouseDisplay→selfDisplay pose): 描画差 = 1.548px (< 2.0px、圧縮)
- 旧経路の圧縮量計算を test に inline で残し、根本原因を後続セッションが復元できる形にした

修正: `LaserGeometry.viewLocal(_ p: LogicalPoint, in bounds: LogicalRect) -> CGPoint` を新設し、CG global 論理座標 (既にすべてのディスプレイで共有された基準座標系) を pose 経由なしで単純減算して view local に落とす。cross-display の mm 空間整合は Phase 2 (共有 mm 原点を持つキャリブレーション UI) の課題として明示分離。

**#5 ウィンドウドラッグが重い・止めても行き過ぎる (性能)**

対処:
- `EventTapController` の `eventsOfInterest` を **mouseMoved のみ**に絞った (leftMouseDragged / rightMouseDragged / otherMouseDragged を除外)。ドラッグ系イベントは tap を経由せず OS へ素通しするため、reduce・rewrite・SwiftUI 更新のオーバーヘッドを完全に消去。「止めても行き過ぎる」= tap callback の詰まりでキュー滞留した後発イベントが遅延再生される現象は、ドラッグ系イベントが tap を通らなくなったことで解消するはず (実機検証は kawaz 再起動待ち)
- レーザー描画のためのポインタ位置は `AppDelegate.startDragPositionMonitor()` の NSEvent global monitor (leftMouseDragged 等) で拾い、`OverlayViewModel.apply(mouseLocation:)` に流す。warp は発火しない
- tap callback 内で `DispatchTime.now().uptimeNanoseconds` の差分を `LatencyTracker` に記録。メニューバー `LG → Dump tap latency` で n / p50 / p95 / p99 / max (μs) を NSLog 出力

残リスク:
- SwiftUI @Published の更新は tap 経路から発火し続ける (`OverlayViewModel.apply(state:)` が state 全体を @Published にセット)。60Hz coalescer に載せ替えるのが本筋だが、Phase 2 へ繰越 (今回はドラッグ除外だけで実機体感が改善するか kawaz に確認してから判断)
- p50/p99 の目標値・NG 閾値は未設定。修正後の実測値を journal に追記して基準線を確定する予定
- ドラッグ中のワープが「意図的に発火しない」設計になった。ドラッグ中のワープが必要なユースケースが実運用で出たら再検討 (Phase 1 では優先度低の判断)

### 未検証 (kawaz 実機確認待ち)

- #1 の視覚的確認 (4 本のみになったか、8 本のままか)
- #2 のアイドル 0.3s フェードが実機で自然か (値の再調整余地)
- #3 の standoff 40px が実機で「ポインタが隠れず邪魔にならない」距離か
- #4 の境界跨ぎジリジリが解消しているか (regression テストは pass しているが実機観測が本証)
- #5 のドラッグ重さが解消しているか、tap latency の実測値 (要 Console.app 併用、runbook 記載の手順)
