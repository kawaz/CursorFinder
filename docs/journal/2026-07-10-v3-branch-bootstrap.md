# 2026-07-10 v3 ブランチ立ち上げ (実験リポからの合流初日)

- 経緯: 前身の実験リポ (MoonBit 構成) での全方位調査・再設計 DR 起草を経て、本リポの v2 先端 f372440 から v3 ブランチを作成。DR-0002〜0008 を移送 (移送時に配布バージョン v0.12.1 等の事実修正、v2 リライトはローカル v2 ブランチ上と訂正、v3 ブランチは f372440 から作成と明記)
- 実機検証: kawaz の手動実機計測 2 回 (delta マトリクス 659 イベント + カドなぞり 120 秒 5960 イベント) で、クランプの min/max 非対称 (max 側のみ -0.02px インセット、scale 非依存)・delta 符号の信頼性 (クランプ中も外向き符号を保持)・継ぎ目通過で境界値ちょうどのイベントは出ないこと (PX は所属モニタ変化でのみ検出)・カドの両軸独立クランプを確定 → docs/findings/2026-07-09-macos-display-api-verification.md に記録
- 幾何コア (Core/): 座標型分離・pose 可逆変換・y-down 隣接検出・物理投影/rate 写像・BX/PX 分類・PP/PB/BP/BB 判定を TDD 実装。コアレビューで Critical 2 (C-1, C-2) / Major 2 (M-1, M-2) / minor 6 (m-2〜m-7) の指摘 → 全修正。C-1 (OS 自動ペア専用の物理投影 PhysicalProjection 新設) は DR-0006 決定 2 の改訂 (OS 自動ペア = 物理投影 / ユーザセグメント = rate 写像) に発展
- store 層: DR-0004 の純関数 store (AppState/Action/Effect/reduce) を実装
- App/ (SPM executable `laserguide-dev`): CGEventTap runtime (同期 rewrite・tap リカバリ・権限 degrade)・v1 流用のオーバーレイ設定・mm 物理空間のレーザー描画・メニューバー最小 UI を新設。起動手順は docs/runbooks/v3-dev-run.md
- 現状: Core 54 テスト + App 4 テスト green (実行確認済み)、origin/v3 に push 済み。justfile (Core テストゲート付き push-wip) 新設
- 次: kawaz による実機起動確認 → キャリブレーション UI (WKWebView 純 view、Web プロトタイプ流用) → xcodeproj/CD 統合 → v1 設定 migration (DR-0007)
