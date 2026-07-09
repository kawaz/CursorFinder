# DR-0003: リポジトリ統合 — kawaz/LaserGuide の v2 リライトに合流する

## 背景

2026-07-09 の偵察で、既存 kawaz/LaserGuide (public、Homebrew Cask で v0.12.1 配布中。リポ内 Casks/ の 0.6.4 は古く、tap リポ kawaz/homebrew-laserguide 側が実配布の正) が**既に v2 リライトの途中**であることが判明した:

- 配布中の実装 (レーザー描画・NSEvent 監視・オーバーレイ) は `LaserGuide.v1.backup/` に退避済み
- v2 リライトはローカル `v2` ブランチ (main +14 コミット、未 push) で進行しており、その `LaserGuide/` は v2 骨格: データモデル (`WorkspaceConfiguration` / `Display` / `PassSegment` / `DisplayFingerprint`) + SpriteKit キャリブレーション画面のみ。描画・入力・CGEventTap は commit 51a4ab8 で明示削除
- CGEventTap による越境ワープの完動実装が git 履歴 (`git show 6cab429:LaserGuide/Services/EdgeCrossingDetector.swift`) に残っている
- notarize 込み CI/CD、Cask 配布、ja/en ドキュメント体裁が整備済み

一方 V3 (本リポ) は MoonBit 実験と並行して、エッジ接続のドメインモデル (EdgeSegment + rate マッピング)、物理配置キャリブレーション UI プロトタイプ (web)、設計知見 (docs/decisions/) を蓄積した。

## 決定

**開発の本流を kawaz/LaserGuide リポに戻す。**

1. kawaz/LaserGuide の `v2` ブランチ先端 (f372440) から `v3` ブランチを作成し、Elm-style 再設計 (DR-0004〜DR-0008) をそこで実装する
2. v2 のデータモデルを土台に、V3 の設計知見 (DR 群・テスト仕様輪郭・web UI プロトタイプの操作設計) を還元する
3. 実装が配布可能水準に達したら main を v3 で差し替える (既存 main の v2 骨格は履歴に残る)
4. 本リポ (LaserGuideV3) は設計資産の供給元として役目を終えたらアーカイブする。DR 群は v3 ブランチの docs/decisions/ に移送する
5. **配布基盤は維持する**: Bundle ID `jp.kawaz.LaserGuide` (Cask の uninstall/zap 経路を壊さない)、notarize secrets、tap 更新フロー

## 引き継ぎ時の既知の落とし穴 (偵察で確認済み)

- `cd-auto-release-and-deploy.yml:42` の変更検出パターンに web/ 等が未登録 — v3 のファイル構成に合わせて更新が必要
- tap 更新は `HOMEBREW_TAP_TOKEN` (PAT) 方式 (個人標準の ssh deploy key 方式とは異なる)
- `scripts/dev-run.sh` に業務先の Team ID がハードコード — 個人リポとして整理対象
- v1 (配布中) と v2 で UserDefaults の key prefix と fingerprint 生成が異なり、migration 未実装 (DR-0007)

## v3 ブランチ期間中の運用

- 配布中リリース (v0.12.1) への hotfix は main (= v0.12.1 タグと同一) から hotfix ブランチを切る。CD は main push トリガなので hotfix リリースは workflow の手動実行経路を確認してから行う
- `code-quality.yml` (SwiftLint --strict) は push トリガで v3 ブランチにも走る。v3 の初期は骨格構築で red になりやすいため、v3 ブランチ作成時に workflow のトリガ条件を確認し、必要なら branch filter を調整する (無効化ではなく対象調整)

## 却下案

| 案 | 却下理由 |
|---|---|
| V3 リポで開発を続け、完成後に LaserGuide main を上書き | xcodeproj・CI・v1 資産・v2 モデルを V3 側へ運ぶ手間が逆向きに発生し、MoonBit 時代の履歴も本流に混入する |
| LaserGuide main で直接作業 (ブランチなし) | 配布中プロダクトのリポの main を長期間ビルド不能状態にする。リリース CD が main push トリガのため誤発火リスクもある |

## ステータス

Proposed (2026-07-09)
