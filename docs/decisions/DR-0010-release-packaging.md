# DR-0010: リリースパッケージング — SPM 完結 + スクリプト .app バンドル (xcodeproj 廃止)

## 背景

v3 の実装は SPM 2 パッケージ (Core = 純関数層 / App = executable `laserguide-dev`) で進んでおり、配布に乗せるには既存の配布基盤 (xcodeproj + cd-auto-release-and-deploy.yml の archive → codesign → notarize → Cask 更新) との統合が必要。3 案比較の調査は docs/research/2026-07-10-release-integration-options.md が正本。

## 決定

**案 (b): xcodeproj を廃止し、SPM ビルド + スクリプトによる .app バンドル組み立てへ移行する。**

1. `swift build -c release` の成果物を `scripts/build-app-bundle.sh` で `.app` 化する (Info.plist はテンプレートから生成: Bundle ID `jp.kawaz.LaserGuide` 維持 = DR-0003、`LSUIElement=YES`)
2. 署名は bottom-up codesign (`--options runtime --timestamp` を明示 — 旧 CD は xcodebuild archive の暗黙 Hardened Runtime に依存していたため明示化が必須) → `notarytool submit --wait` → `stapler staple`。kawaz の他リポ (authsock-warden / stable-which / authsock-filter) で実績のあるパターン
3. CD workflow の xcodebuild archive 段を上記に書き換える。**Cask 更新経路・secrets・タグ/リリース作成の後段は温存**
4. 変更検出 path filter に v3 の実体 (`Core/`, `App/`, `Package.swift`, web 資産) を追加する
5. `DEVELOPMENT_TEAM` 等のハードコードは廃止し、CI は secrets、ローカルは環境変数から取る
6. SwiftLint は `--strict` を維持しつつ、幾何ドメインの短識別子 (`x/y/t/p` 等) を `.swiftlint.yml` で明示的に許容する (ドメイン語彙であり lint の対象外とする判断)
7. deployment target は v3 の実態 (`.macOS(.v13)`) を起点とし、配布要件 (旧 Cask は `>= :sequoia`) は Cask 側の宣言で管理する

## 却下案

| 案 | 却下理由 |
|---|---|
| (a) 既存 xcodeproj に v3 ソースを差し替え + ローカル SPM 参照 | リソースアクセスが SPM (`Bundle.module`) と xcodeproj (`Bundle.main`) のハイブリッドになり、ビルド経路 2 系統の保守が恒常化する。DR-0003 の「配布基盤維持」の実体は Bundle ID + secrets + tap 更新フローであり、xcodeproj 本体の維持は要件でない |
| (c) XcodeGen 等の project 生成ツール | 生成ツールという新たな依存を足してまで xcodeproj 形式を残す理由がない (Xcode での開発は `Package.swift` を直接開けば足りる) |

## 検証の輪郭

- `scripts/build-app-bundle.sh` の成果物が `codesign --verify --deep --strict` と `spctl -a -t exec` を通る (notarize 前はローカル署名で確認)
- .app 起動でメニューバー常駐・レーザー・ワープが `swift run` と同挙動
- CD の dry-run (workflow_dispatch + アップロード直前まで) が green
- 既存ユーザの UserDefaults (Bundle ID 同一) が .app 版でも読めること

## ステータス

Proposed (2026-07-10)
