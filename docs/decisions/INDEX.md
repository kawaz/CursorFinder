# Decision Records 一覧

DR-0001 は前身の実験リポ (LaserGuideV3) 側にあり、本リポには持ち込まない (番号は通しで継続)。

## Active

- [DR-0002-swift-single-core](./DR-0002-swift-single-core.md) — MoonBit 廃止、幾何コア含め Swift 単一実装 (Proposed)
- [DR-0003-repo-consolidation](./DR-0003-repo-consolidation.md) — 本リポの v2 リライトに合流、v3 ブランチで再設計 (Proposed)
- [DR-0004-unidirectional-data-flow](./DR-0004-unidirectional-data-flow.md) — 手組み Elm-style: Action 形式化 + 純関数 reducer + Effect 分離、BX/PX トリガーモデル (Proposed)
- [DR-0005-coordinate-system](./DR-0005-coordinate-system.md) — CG (y-down) を論理座標の正、mm 物理空間と型分離 (Proposed)
- [DR-0006-edge-connection-model](./DR-0006-edge-connection-model.md) — v2 PassSegment 2 リスト差分方式を土台に rate マッピング統合 (Proposed)
- [DR-0007-persistence-migration](./DR-0007-persistence-migration.md) — hardwareId のみで同一性判定、v1 設定 migration、Bundle ID 維持 (Proposed)
- [DR-0008-calibration-ui](./DR-0008-calibration-ui.md) — キャリブレーション UI は WKWebView + JS の「純 view」 (Proposed)
- [DR-0009-focus-flash-component](./DR-0009-focus-flash-component.md) — 第3コンポーネント「フォーカスフラッシュ」(段階実装 A=モニタ縁 → B=ウィンドウ枠) (Proposed)

## Archived

<!-- 現役の文脈を汚す古い DR は decisions/archive/ に退避し、ここに記載 -->

## Moved to research/

<!-- 判断記録の体を成さなくなり research/ に降格した DR -->

## Superseded

<!-- 後続 DR に上書きされた DR (Status: Superseded by DR-XXXX) -->
