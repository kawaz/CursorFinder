# LaserGuide v3 リリース統合方式 調査・提案

対象リポ: `/Users/kawaz/.local/share/repos/github.com/kawaz/LaserGuide` (main/v2 checkout) + `wip-v3/` (v3 branch worktree)。ファイル書き込み・commit なし (本レポート除く)、SwiftLint 実測は scratchpad 上のコピーに対してのみ実行。

## 1. 現状の配布基盤 (main / v2 側)

### xcodeproj

- ターゲット 1 個 `LaserGuide` (`productType = "com.apple.product-type.application"`) — `LaserGuide.xcodeproj/project.pbxproj:51-72`
- Bundle ID: `PRODUCT_BUNDLE_IDENTIFIER = jp.kawaz.LaserGuide` — `project.pbxproj:279, 310`
- LSUIElement (メニューバー常駐): `INFOPLIST_KEY_LSUIElement = YES` — `project.pbxproj:182, 244`
- Info.plist は **`GENERATE_INFOPLIST_FILE = YES`** で xcodebuild 生成 (`project.pbxproj:271, 302`)。`LaserGuide/Info.plist` は物理ファイルとして存在せず、`INFOPLIST_KEY_LSUIElement` / `INFOPLIST_KEY_NSAppleEventsUsageDescription` / `INFOPLIST_KEY_LSApplicationCategoryType` の build setting だけで組み立てる
- entitlements: `LaserGuide/LaserGuide.entitlements` — 内容は空 dict (`<plist><dict/></plist>`)。App Sandbox / Hardened Runtime は build setting 側で管理
- macOS deployment target: **15.0** (`project.pbxproj:185, 247`)、`DEVELOPMENT_TEAM=3QMEVK549R` がハードコード (`project.pbxproj:164`)
- ソース同期方式: **Xcode 16 の `fileSystemSynchronizedGroups`** を使用 (`project.pbxproj:63-65`)。`LaserGuide/` 配下の `.swift` を pbxproj 列挙せず自動同期 (統合方式の判断に効く)
- SwiftLint config: リポルート `.swiftlint.yml` の `included: [LaserGuide]`

### CD workflow (`.github/workflows/cd-auto-release-and-deploy.yml`)

- トリガ: `main` push + workflow_dispatch (`:3-10`)
- **変更検出 path filter** (`:42`):
  ```
  git diff --name-only $LATEST_TAG..HEAD | grep -E '\.(swift|m|mm|h|cpp|c|xcodeproj|plist|entitlements)$'
  ```
  → `Package.swift` / `App/**` / `Core/**` / `.resolved` / html / js (calibration UI) が拾われない
- 主要ステップ:
  - Set up code signing: `.p12` を base64 secret から復号 → 一時 keychain に import (`:126-155`)
  - Build: `xcodebuild -scheme LaserGuide -configuration Release -archivePath ... archive` + `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` / `CODE_SIGN_STYLE=Manual` / `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` を注入 (`:161-181`)
  - Verify signature: `codesign -dv` で `Signature=adhoc` を弾く (`:184-211`)
  - Zip → `xcrun notarytool submit --wait --timeout 10m` (`:236-259`)
  - `xcrun stapler staple` + 再 zip (`:263-286`)
  - `softprops/action-gh-release@v2` で tag + release + asset (`:295-303`)
  - `kawaz/homebrew-laserguide` を PAT (`HOMEBREW_TAP_TOKEN`) で clone → `sed` で `Casks/laserguide.rb` の version + sha256 差し替え → push (`:305-338`)
- **前提 secrets**: `APPLE_CERTIFICATE_BASE64` / `APPLE_CERTIFICATE_PASSWORD` / `APPLE_DEVELOPMENT_TEAM` / `APPLE_SIGNING_IDENTITY` / `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD` / `APPLE_TEAM_ID` / `HOMEBREW_TAP_TOKEN` — `personal-macos-signing-notarization` skill の 6 secrets + tap PAT。統合方式によらず維持できる

### code-quality.yml (参考)

- `code-quality.yml:16-45` は SwiftLint --strict + `xcodebuild ... analyze` + ASAN/UBSAN build。**xcodeproj 前提**。統合方式 (b) では `swift build -Xswiftc -sanitize=address` に置き換え要

## 2. v3 (wip-v3) の SPM 構成

- ルート = `wip-v3/`。**`Package.swift` は root には無い**、`App/Package.swift` と `Core/Package.swift` の 2 パッケージ構成
- `Core` (`wip-v3/Core/Package.swift`): `LaserGuideCore` library、Foundation まで、AppKit/CoreGraphics 非依存 (幾何 + Store 純関数層)
- `App` (`wip-v3/App/Package.swift`):
  - `swift-tools-version: 5.9`, `.macOS(.v13)` (**v2 の 15.0 と不一致**、統合時に揃える)
  - `.executable(name: "laserguide-dev", targets: ["LaserGuideDev"])`
  - `dependencies: [.package(path: "../Core")]`
  - `resources: [.copy("Resources/calibration")]` — WKWebView 用の `index.html` / `main.js` を `Bundle.module` で読む (DR-0008)
- 起動: `App/Sources/LaserGuideDev/main.swift` で `NSApplication.shared.setActivationPolicy(.accessory)` を明示呼び出し (**`Info.plist` は書かない、コード側で activation policy を設定**)
- `.app` バンドル生成の仕組みは **未整備**: `wip-v3/justfile` は `just test` (= `cd Core && swift test`) のみ、`push` は `exit 1` (「リリース経路は未整備」)
- entitlements: `wip-v3/LaserGuide/LaserGuide.entitlements` は v2 側からの残置 (空 dict)。v3 `App/` 配下には entitlements 相当なし
- DR-0003 引用: 「配布基盤は維持する: Bundle ID `jp.kawaz.LaserGuide`、notarize secrets、tap 更新フロー」 — `wip-v3/docs/decisions/DR-0003-repo-consolidation.md:22`

### v3 コードの SwiftLint --strict 実測

scratchpad にコピー、`swiftlint --strict App/Sources Core/Sources`:

```
Found 204 violations, 204 serious in 37 files.
  172 identifier_name  ← 幾何コードの x/y/t/p/d/us/mm/to
   12 line_length
    4 switch_case_alignment
    3 opening_brace
    2 large_tuple / trailing_comma / comma
    1 unused_closure_parameter / type_body_length / statement_position /
      function_parameter_count / force_cast / file_length / cyclomatic_complexity
```

- 172/204 が `identifier_name`。現行 `.swiftlint.yml` の `identifier_name.min_length` 明示 (warning: 1 / error: 1) は書いてあるが、swiftlint デフォルトが優先される場面がある (config 再検討要)。幾何コード (`Judgement.swift`, `DisplayPose.swift`) の `x/y/t/p` は意味的に正、`identifier_name` は 1 文字許容に緩めるか `Core/Sources` を対象外にする
- 残 30 件はフォーマット寄り (line_length / opening_brace 等)、機械修正可能

## 3. 統合方式の比較

### 案 (a) 既存 xcodeproj の app target に v3 SPM を接続する

- **概要**:
  1. `LaserGuide.xcodeproj` を残し `LaserGuide/` を空にして v3 の `App/Sources/LaserGuideDev/` の内容を配置 (fileSystemSynchronizedGroups で自動同期)
  2. `Core/` パッケージを xcodeproj に **local SPM package** (`XCLocalSwiftPackageReference`) として追加、`LaserGuideCore` を app target の `packageProductDependencies` に
  3. `Info.plist` は `INFOPLIST_KEY_LSUIElement=YES` 由来生成を維持
  4. `MACOSX_DEPLOYMENT_TARGET=15.0` のまま (v3 の 13.0 は下方互換)
  5. WebView 資源 `Resources/calibration/*` は xcodeproj Resources build phase に追加 (`Bundle.module` は SPM 資源解決、xcodeproj target では `Bundle.main` 経由に書き換え必要)
- **CD 変更量**: 小 — `cd-auto-release-and-deploy.yml:42` の path filter に `Package\.swift` / `\.resolved` / `Resources/calibration` を追加、5〜10 行
- **保守性**: `+` Xcode で開ける、既存経路そのまま。`-` pbxproj バイナリ diff、fileSystemSynchronizedGroups の Xcode 16 依存、`.swiftlint.yml` の `included:` 書換 + 幾何 identifier_name 緩和が必要
- **リスク**: 中 — `Bundle.module` → `Bundle.main` の書き換えを v3 コード側に入れる必要 (SPM `swift run` 経路とバンドル経路の分岐が必要になる)。低 — 署名・notarize 経路は現状のまま、Bundle ID 維持は build setting で

### 案 (b) xcodeproj 廃止、SPM 完結 + 手動 .app バンドル (推奨)

- **概要**:
  1. `LaserGuide.xcodeproj` 削除
  2. リポルートに `Package.swift` を配置 (App/Core 統合または `wip-v3/App` root 昇格)
  3. CD で `swift build -c release --arch arm64 --arch x86_64` (universal binary) → スクリプトで `LaserGuide.app/Contents/{MacOS,Resources}` を組み立て → `Info.plist` を手書き (LSUIElement / CFBundleIdentifier=`jp.kawaz.LaserGuide` 等) → Resources に `calibration/` copy
  4. `codesign` bottom-up (Resources → Frameworks → `.app`, `--options runtime --timestamp` 明示) → `notarytool submit --wait` → `stapler staple` (`personal-macos-signing-notarization` skill パターン、kawaz の `authsock-warden` / `stable-which` に前例)
- **CD 変更量**: 大 — `Set up code signing` は流用、`Build Universal Binary` 以降を全面書換。40〜80 行の diff + `scripts/build-app-bundle.sh` 新規 80〜120 行想定
- **保守性**: `+` SPM 純度最高、`swift build` / `swift test` / `swift run` 全て自然に動く、pbxproj バイナリ diff から解放、`justfile` に統合しやすい。`-` `.app` 組み立てスクリプトを自前保守 (Info.plist キー追加時に script を触る)
- **リスク**: 中〜高 — 署名 bottom-up は kawaz の他リポで実績あるが AppKit GUI (メニューバー常駐) での前例は現時点なし (authsock-warden は launchd デーモン、stable-which は CLI)。ただし macOS TCC (AXIsProcessTrusted) は Bundle Identifier ベース、`Info.plist` を正しく書けば実質同等。中 — swift build は Info.plist を持たない → 全キー手動 (5〜10 個)。低 — notarize 経路は同一

### 案 (c) XcodeGen / Tuist で project 生成

- kawaz リポでの XcodeGen / Tuist の前例は見当たらない (本レポート範囲での確認)
- **概要**: `project.yml` (XcodeGen) を書いて CD で `xcodegen generate` → 案 (a) と同じ xcodebuild archive
- **CD 変更量**: 中 — xcodegen インストール + generate ステップ (5〜15 行)
- **保守性**: `+` pbxproj バイナリ diff 撤廃、`project.yml` 人間可読。`-` 学習コスト、SPM 両立で bug 踏む可能性、メンテナンス層が 1 つ増える
- **リスク**: 中 — 単一 executable + 1 library に project 生成ツール新規導入は overkill

## 4. 共通項目

| 項目 | 現状 | 統合対応 |
|---|---|---|
| Info.plist | `INFOPLIST_KEY_LSUIElement=YES` 由来 (`project.pbxproj:182,244`) で xcodebuild 生成 | (a) そのまま / (b) 手書き: LSUIElement / CFBundleIdentifier / CFBundleShortVersionString / CFBundleVersion / LSApplicationCategoryType / NSAppleEventsUsageDescription |
| entitlements | 空 dict | 空維持 (App Sandbox 未有効)。Hardened Runtime は codesign `--options runtime` で明示 (現行 workflow は xcodebuild archive の暗黙 runtime に依存、(b) では明示要) |
| Bundle ID | `jp.kawaz.LaserGuide` (`project.pbxproj:279,310`) | 全案で維持可能 (DR-0003 準拠) |
| CD path filter | `cd-auto-release-and-deploy.yml:42` | (a) `Package\.swift` / `\.resolved` / `App/` / `Core/` / `\.html$` / `\.js$` 追加。(b) `xcodeproj` を消し `Package\.swift` / `\.html$` / `\.js$` / `scripts/build-app-bundle\.sh$` に |
| SwiftLint --strict | v2 対象で pass、v3 対象で 204 violations (172 identifier_name) | `.swiftlint.yml` で `identifier_name.min_length: {warning: 1, error: 1}` 明示 or `Core/Sources` 対象外、+ 30 件フォーマット機械修正 |
| code-quality.yml | `xcodebuild ... analyze` + ASAN (`code-quality.yml:32-58`) | (a) scheme 維持。(b) `swift build -Xswiftc -sanitize=address` + `swift test` に書換 |
| `DEVELOPMENT_TEAM=3QMEVK549R` | `project.pbxproj:164` にハードコード | DR-0003「個人リポとして整理対象」。全案で secrets 参照化 |

## 5. 推奨案: (b) SPM 完結 + 手動 .app バンドル

### 根拠

1. **v3 設計純度と整合**: DR-0002 (Swift 単一 core) + DR-0004 (unidirectional data flow) は「純関数 Core + 薄い runtime」を志向、SPM 2 パッケージ構成はその物理表現。xcodeproj を挟むと SPM `Bundle.module` と xcodeproj `Bundle.main` の資源解決差 (案 (a) 中リスク項) や pbxproj バイナリ diff の日常化が入り込む
2. **kawaz 他リポとの一貫性**: `personal-macos-signing-notarization` skill の bottom-up codesign + notarytool パターンは `authsock-warden` / `stable-which` / `authsock-filter` の release.yml で実績あり。LaserGuide だけ xcodeproj 経路だと保守が孤立
3. **(c) は overkill**: v3 は単一 executable + 1 library、project 生成ツール新規導入するほどの複雑度なし
4. **(a) の唯一の利点 (差分小) は再現しない**: fileSystemSynchronizedGroups + local SPM + `Bundle.module` → `Bundle.main` 書換 は実質「新旧経路のハイブリッド」で synthesis-temptation-guard に該当
5. **DR-0003 の「配布基盤は維持」を Bundle ID + secrets + tap 更新の 3 要素に狭く解釈**: xcodeproj そのものの維持は DR 本文に書かれていない (`wip-v3/docs/decisions/DR-0003-repo-consolidation.md:22`)

### 実装タスク分解 (v3 ブランチ内で完結する形)

| # | タスク | 検証 |
|---|---|---|
| 1 | ルート `Package.swift` 新設 (App + Core 統合または `App/Package.swift` root 昇格)、product 名を `LaserGuide` に (`laserguide-dev` は開発名) | `swift build -c release` pass、`swift test` が Core + App tests を両方走らせる |
| 2 | `scripts/build-app-bundle.sh` 新設。`swift build -c release --arch arm64 --arch x86_64` → `LaserGuide.app/Contents/{MacOS,Resources,Info.plist,PkgInfo}` 構築 → `Resources/calibration/` copy | ローカル実行、Finder から起動、メニューバー表示、WKWebView が index.html を読める (`Bundle.module` → `Bundle.main.resourceURL?.appendingPathComponent("calibration")` 書換必要) |
| 3 | v3 コードの `Bundle.module` 参照を「SPM 実行 = Bundle.module / .app 起動 = Bundle.main」で分岐するヘルパを追加 | `swift run laserguide-dev` と `.app` 起動の両方でキャリブレーション UI 起動 |
| 4 | `Info.plist` テンプレを `scripts/` 配下に。キー: `CFBundleIdentifier=jp.kawaz.LaserGuide` / `LSUIElement=YES` / `LSApplicationCategoryType=public.app-category.utilities` / `NSAppleEventsUsageDescription` / `CFBundleShortVersionString=$VERSION` / `CFBundleVersion=$VERSION` / `LSMinimumSystemVersion=13.0` | `plutil -lint`、`.app` が macOS 13 / 15 で起動 |
| 5 | `cd-auto-release-and-deploy.yml` 書換: (i) path filter を `\.(swift|plist|entitlements)$\|Package\.(swift\|resolved)$\|scripts/build-app-bundle\.sh$\|App/Sources/.*Resources/` に (ii) Build を `swift build` + `scripts/build-app-bundle.sh` に (iii) codesign を bottom-up + `--options runtime --timestamp` 明示 | GitHub Actions で workflow_dispatch (force_release=true) → notarize Accepted、stapler validate pass、`spctl -a -vvv -t exec LaserGuide.app` accepted |
| 6 | `code-quality.yml` 書換: `swiftlint --strict` (config は v3 向け) + `swift build -Xswiftc -sanitize=address` + `swift build -Xswiftc -warnings-as-errors` | PR で workflow pass |
| 7 | `.swiftlint.yml` v3 向け更新: `included: [App/Sources, Core/Sources]`、`identifier_name.min_length: {warning: 1, error: 1}` 明示、line_length 等 30 件フォーマット機械修正 | `swiftlint --strict` 0 violations |
| 8 | `justfile` に `build-app` / `release-check` (署名なし .app 生成) / `test` (Core+App) 追加、既存 `push` の警告文言更新 | `just build-app` で `.app` 生成 |
| 9 | Homebrew Cask 更新 (`Update Homebrew Tap` step) は現行 `sed` 経路を流用 (zip 名 `LaserGuide-${VERSION}.zip` を維持) | 統合前に `Casks/laserguide.rb` を確認、version + sha256 差し替え regex が当たるか |
| 10 | main への merge 前、v3 で `workflow_dispatch(force_release=true)` の試験は **Cask に v3 を上書きするリスキー**。`Update Homebrew Tap` step を条件付き skip する feature flag を一時追加して signing + notarize までを検証 | notarize Accepted、Cask 更新スキップをログで確認 |

### 補足

- **`DEVELOPMENT_TEAM=3QMEVK549R`**: `project.pbxproj:164` の業務先 Team ID ハードコード。(b) では pbxproj 削除で自然消滅
- **macOS 13.0 vs 15.0**: v3 `.macOS(.v13)` と v2 `MACOSX_DEPLOYMENT_TARGET=15.0` のずれ。DR-0002 / v3 実装が 15+ 専用 API に依存していないかは Xcode の警告で確認可。13.0 維持なら Package.swift そのまま、15.0 に上げるなら `Info.plist` の `LSMinimumSystemVersion=15.0`
- **Hardened Runtime**: 現行 workflow の codesign は xcodebuild archive の暗黙 `--options runtime`。SPM ルート case では **明示的に** `codesign --options runtime --timestamp` を付けないと notarize reject (kawaz の他リポで実績)
