# LaserGuide — AI アシスタント向けガイド

> [English](./CLAUDE.md)

マルチモニタ環境の「いまどこ?」をオーバーレイ描画で可視化する macOS 常駐アプリ。
3 コンポーネント: **レーザー** (カーソル位置) / **境界ワープ** (仮想境界でのカーソル移動制御) / **フォーカスフラッシュ** (フォーカス先モニタの明示)。

## ブランチ / リリースモデル (重要)

- **main**: 唯一の長命ブランチ (SPM 全面リライト系譜)。**main への push はリリース CD が発火する**
  (最新 tag からの auto bump + tag + GH Release + Cask 更新)。main への push = kawaz のリリース判断
- 作業は wip/feature ブランチで行う (`just push-wip` は main を拒否)。リリース時に main へ合流

## Quick Commands

```bash
just ci          # lint (swiftlint --strict) + Core/App 全テスト
just test        # テストのみ
just run         # 開発実行 (swift run laserguide-dev)。要アクセシビリティ権限
just build-app   # LaserGuide.app を組み立て (ad-hoc 署名 + verify)
just push-wip    # ci ゲート付きで現ブランチを push (main は不可)
```

## アーキテクチャ

- `Core/` — **UI 非依存の純関数層** (SwiftPM)。座標型・pose・エッジ接続・ワープ判定・reducer・永続化スキーマ。テストが仕様書 (意図コメント必読)
- `App/` — executable `laserguide-dev` (SwiftPM)。Effect インタープリタ (CGEventTap / オーバーレイ / UserDefaults / WKWebView ブリッジ) とメニューバー
- 単方向データフロー (手組み Elm-style、DR-0004): `reduce(AppState, Action) -> (AppState, [Effect])`。reducer 内の副作用禁止、store は main run loop で同期
- `App/Resources/calibration/` — キャリブレーション UI (WKWebView の**純 view**、幾何ロジックの JS 実装は禁止 = DR-0008)

## 座標系の鉄則 (DR-0005)

- 論理座標 = **CG グローバル (top-left 原点、y-down)**。`LogicalPoint` / `PhysicalPoint` (mm、同じく y-down) を型で分離
- NSScreen / NSEvent / AX 由来の値は**入力アダプタ境界で即 CG に変換**し、reducer より内側に y-up を持ち込まない
- 「Top」= minY 側。実機のクランプ挙動 (min 側 = 境界値ちょうど / max 側 = −0.02px) は docs/findings/ 参照

## 作業規約

- 設計判断は `docs/decisions/` (DR-0002〜0010 + INDEX) が正本。実装と矛盾したら双方向で確認
- 経緯は `docs/journal/`、実機手順・確認観点は `docs/runbooks/v3-dev-run.md`、未完タスクは `docs/issue/`
- tag / GH Release を手で作らない (CD の仕事)。リリース判断は kawaz
- テストは輪郭ごと意図コメント付きで。緩めて green にするのは禁止
