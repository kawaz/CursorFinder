# v3 開発用アプリの起動手順

`swift run laserguide-dev` で立ち上げる開発用の常駐アプリ。メニューバーに `LG` として現れ、
各ディスプレイに透明オーバーレイを張ってレーザーを描画し、CGEventTap 経由で仮想境界ワープを実行する。

DR-0010 で SPM 完結 + `scripts/build-app-bundle.sh` による .app バンドル組み立てへ移行済み。
配布用 `.app` の生成手順は本文書末尾の「.app バンドルのローカルビルド (DR-0010)」節を参照。

## 前提

- macOS 13 以上 (SPM manifest で `.macOS(.v13)`)
- Swift 5.9 以上 (`swift --version` で確認)
- アクセシビリティ権限を Terminal (もしくは起動元プロセス) に付与する必要あり

## ビルドと起動

```
cd App
swift build             # 依存の Core も同時にビルドされる
swift run laserguide-dev
```

初回起動時、AXIsProcessTrustedWithOptions(prompt=true) がシステムダイアログを出す。
承認後は `swift run laserguide-dev` を打ち直すと通常経路で立ち上がる。

### アクセシビリティ権限の付与

システム設定 → プライバシーとセキュリティ → アクセシビリティ で、
「Terminal」もしくは実際に `swift run` を打っている親プロセス (iTerm2 / VS Code 等) をトグル ON する。
権限が取れていないと:

- CGEventTap が起動できず、**レーザー描画のみモード**にフォールバック (仮想境界ワープは動かない)
- 起動ログに tap 失敗が現れる (`applicationDidFinishLaunching` 内で判定)

## メニューバー操作

| メニュー項目 | 挙動 |
|---|---|
| 境界ワープ (チェックマーク) | 仮想境界ワープ (CGEventTap) の有効/無効トグル。レーザー描画は独立で常時 on |
| プレゼンテーションモード (チェックマーク) | on で overlay window の sharingType を .readOnly に切替 (画面キャプチャに映る) + クリック可視化サークルを描画。off で既定 (キャプチャ除外) に戻る。詳細は下記 |
| フォーカスフラッシュ (チェックマーク) | on でフォーカス変更 (アプリ切替 + 同一アプリ内ウィンドウ切替) を購読し、モニタ縁ハイライト + ウィンドウ枠震源の波動を描画。状態は設定に永続化。AX 権限なし時はメニュー項目 disabled (toolTip「アクセシビリティ権限が必要です」)。詳細は下記 |
| 設定... (,) | 設定ウィンドウ (一般 / レーザー / フォーカスフラッシュ / キャリブレーションのタブ構成) を開く。数値・色の変更は即時反映、UserDefaults に永続化 (DR-0012) |
| キャリブレーション... (⌘K) | 設定ウィンドウをキャリブレーションタブで開く (独立ウィンドウは DR-0012 で廃止) |
| tap レイテンシ: ... (表示専用) | メニューを開くたびに最新の集計 (n / p50 / p95 / p99 / max) へ更新される |
| レイテンシ統計をコピー | 上記の一行をクリップボードへコピー |
| Quit LaserGuide (dev) | 終了 |

### tap latency の計測手順 (#5 検証用)

1. (Console.app は不要になった。メニュー表示で足りる)
2. マウスを 10 秒程度連続で動かす (画面端に押し付けたり継ぎ目跨ぎしたりを含める)
3. メニューバー `LG` を開くと「tap レイテンシ: ...」行に最新集計が表示される
4. 記録したい場合は「レイテンシ統計をコピー」でクリップボードから貼り付ける
5. 修正効果の測定は「実マウス操作が必要」なため CI 自動化不可 (kawaz の実機確認待ち)

## 動作確認観点

- **レーザー描画**: マウスを動かすと各ディスプレイに、そのディスプレイ自身の 4 隅から
  カーソルへ伸びるレーザーが描画される (2026-07-10 フィードバック #1 で仕様確定:
  他ディスプレイの角からの延長線は描画しない)。
- **表示デバウンス + フェードアウト** (2026-07-11 第 4 ラウンド):
  - 表示開始: 連続移動が 0.1 秒 (laserShowDebounce) 継続して初めてレーザーが出る。
    タッチパッドに触れただけの単発的な微小移動では出ない
  - 消灯: 移動停止から 0.3 秒 (inactivityThreshold) 後、0.25 秒 (laserFadeOutDuration)
    かけてスーッとフェードアウトする (即消しではない)
  - フェード中に移動を再開すると即フル輝度に復帰する (直前まで見えていたレーザーの
    継続なのでデバウンスは課さない)
- **テーパー付き三角形**: レーザーは角側が幅広、ポインタ手前 (角→ポインタ距離の約 10%、
  8〜200px にクランプ) の位置で頂点辺を持つ台形/三角形として描画される。ポインタそのもの
  には触れない (2026-07-10 フィードバック #3、第 2 ラウンドで固定 40px から距離比例 + クランプへ変更)。
- **境界跨ぎの連続性**: 継ぎ目 (LG↔内蔵) を跨いで移動しても、LG overlay 上の
  描画位置がジリジリせず、実移動量にほぼ比例して動く (2026-07-10 フィードバック #4
  の regression テスト: `App/Tests/.../LaserGeometryTests.swift`)。
- **起動直後は OS 挙動そのまま (PP)**: 永続設定がまだ無い初回起動時、userSegments は
  osPassSegments のコピーで初期化される (DR-0006 決定 5)。よってモニタ間の継ぎ目は全て PP
  になり、OS のネイティブ通過をブロックしない。PB (仮想通過ブロック) はユーザが明示的に
  userSegment を削除した時にのみ発生する (2026-07-10 第 2 ラウンド #4 で修正。旧実装は
  userSegments を空で初期化しており、起動直後は全継ぎ目が PB 化して通過をブロックしていた)。
- **LG↔内蔵の PP ワープ**: LG (上) と内蔵 (下) が上下隣接している構成では、継ぎ目を跨がる
  マウス移動で通過が期待どおり行われる (通常の OS 挙動を阻害せず流す)。
- **Warp トグル**: メニューバーで off にすると mouseMoved の tap 経路が停止する
  (レーザーは NSEvent monitor 経由の fallback へ切り替わらないので描画は止まる、Phase 2 課題)。
- **ウィンドウドラッグ中もカーソルを追う**: tap の eventsOfInterest は mouseMoved
  のみに絞ってあり、ドラッグ系イベント (leftMouseDragged / rightMouseDragged /
  otherMouseDragged) は OS へ素通しする (2026-07-10 フィードバック #5)。ドラッグ移動は
  NSEvent global monitor 経由で mouseMoved と同格の「ポインタ活動」として扱う: レーザー
  表示中は追従し続け、アイドルフェードで消えた後でもボタンを押したまま動かせば復活する
  (2026-07-10 実機第 3 ラウンドで確認観点化)。view への反映 (tap 経由・drag monitor 経由
  とも) はリーディング+トレーリングエッジ型スロットル (既定 16ms) にまとめられる: 前回反映
  から interval 以上空いた入力は即時反映 (初動に遅延を足さない)、interval 内の後続は最新値
  だけを trailing で反映し中間値は捨てる (キューに積まない)。イベントレートに比例して
  SwiftUI 再描画コストが増えないようにしている。ワープ判定はドラッグ中は発火しない設計。

## キャリブレーション画面 (DR-0008)

メニューバー `LG` → 「キャリブレーション...」 (⌘K) で設定ウィンドウの該当タブとして開く
(DR-0012 で独立ウィンドウからタブへ統合)。WKWebView 上の web UI で、
Swift 側 store から push される RenderModel JSON を描画するだけの純 view (幾何ロジックは
持たない、DR-0008 決定 1)。

### 開き方と閉じ方

- 開く: メニュー項目「キャリブレーション...」もしくは ⌘K
- 閉じる: ウィンドウの ✕。編集中 (candidatePose あり) の状態で閉じると `.calibration(.cancel)` が
  自動送信される (中間状態の残留を防ぐ、CalibrationWindowController.windowWillClose)

### 操作

| 操作 | 挙動 |
|---|---|
| モニタをドラッグ | `.calibration(.dragStart)` → `.dragMove(candidatePose)` を都度送信、右サイドバーに「候補 translate」が表示され、canvas も候補位置で再描画 (RenderModel の physicalBounds に candidatePose 適用済み) |
| ドロップ (マウス離し) | `.calibration(.dragEnd)` 送信 |
| 確定ボタン | `.calibration(.commit)` 送信 → candidatePose が確定 pose に昇格 + persist effect |
| 取り消しボタン | `.calibration(.cancel)` 送信 → 候補破棄、確定 pose は不変 |
| Export ボタン | 現在の RenderModel JSON を表示 (デバッグ・issue 添付用) |

### 動作確認観点

- 起動直後、実機のモニタ数だけ矩形が描画される (物理 mm 空間、y-down)
- モニタをドラッグ中はステータスに「プレビュー中 (未確定)」が出て、サイドバーに候補 translate mm が更新される
- 「確定」で pose translate が候補値へ昇格し、NSLog に `[LaserGuide] persist: ...` が出る (Phase 1 は NSLog のみ)
- 「取り消し」で候補が破棄され、canvas 描画も元の確定 pose に戻る
- Segment 一覧は表示のみ (今ラウンドでは追加/削除編集 UI は未実装、次ラウンドの対象)
- 別ウィンドウ (overlay) のワープ判定は編集中も**確定済み tables** に基づいて動く (DR-0004 の
  「判定と描画の分離」)。プレビュー中の候補 pose はワープ挙動を変えない

### 開発モード (ブラウザ単体 / agent-browser 検証)

Swift ビルド不要でブラウザだけで挙動確認するには live-server で `Resources/calibration/` を配信する:

```
cd App/Sources/LaserGuideDev/Resources/calibration
bunx live-server --port=3456 --no-browser
```

Swift ブリッジ (`window.webkit.messageHandlers.laserguide`) が無い環境では、main.js の mock bridge が
fixture (実機トポロジ相当のダミー displays) を返し、action は `console.log('[mock] ...')` に流す。
`agent-browser open http://127.0.0.1:3456/` で開き、`agent-browser screenshot` / `mouse` /
`click` / `console` でドラッグ・確定・取り消し・Export を検証できる (V3 の docs/runbooks/ui-testing.md
相当の手法)。console にエラーが出ないこと、`[mock] action:` が期待通り並ぶことを併せて確認する。

## プレゼンテーションモード (issue: presentation-mode-capture-toggle)

メニューバー `LG` → 「プレゼンテーションモード」 でトグル。既定は off。

### on 時の挙動

- 全 overlay window の `sharingType` を `.readOnly` に切替 (画面共有 / スクリーンショットに映る)
- NSEvent global monitor で mouseDown / mouseUp (left / right / other) を購読
- mouseDown 時、カーソル座標を中心に半透明の白サークル (青い縁取り、直径 60px) を該当モニタ上に描画
- mouseUp 後は約 0.3 秒かけて opacity が段階的に減衰し消える (再度 mouseDown で瞬時に再表示)

### off 時の挙動

- 全 overlay window の `sharingType` を `.none` に戻す (v1 由来の完成品設定、通常の非キャプチャ状態)
- mouseDown/Up 監視を停止
- 減衰中のサークルは即座に消える

### 動作確認観点

- 画面共有 (macOS の画面共有 / QuickTime のスクリーン録画 / Zoom / Google Meet 等) を起動して LG overlay が
  相手側に映ることを確認 (off の間は映らない)
- 任意のディスプレイでクリック押下 → 白サークルが即時表示、離すと 0.3 秒でフェードアウト
- モニタ構成変更 (screenParametersChanged) 後もプレゼンテーションモード設定が継続すること
  (rebuildOverlays で sharingType と click monitor が再適用される)
- クリック可視化は tap レイテンシ経路に触れず、監視は NSEvent global monitor のみ (ワープ挙動に影響しない)

### 実装メモ

- `PresentationClickEvent` (App/OverlayViewModel.swift) を「Action として形式化」した型として提供
- click 可視化は VM のプロパティ `clickCircle: ClickCirclePresentation?` に集約、LaserOverlayView が ZStack で
  Canvas レーザーの上に重ねて描画
- clickCircle の減衰は AppKit 側 Timer で opacity 値を段階的に更新 (SwiftUI 暗黙 animation を回避、
  ドラッグ中の main run loop でも 60Hz coalesce と衝突せず単独で動く)

## フォーカスフラッシュ + 波動 (DR-0009 / DR-0011、issue: focus-flash-component)

メニューバー `LG` → 「フォーカスフラッシュ」 または設定ウィンドウ (一般タブ) でトグル。
初期値 off、以降の on/off は設定として永続化される (DR-0012 決定 2、再起動しても維持)。

### on 時の挙動

- `NSWorkspace.didActivateApplicationNotification` (アプリ切替) に加え、アクティブアプリの
  **AXObserver (`kAXFocusedWindowChangedNotification`)** を購読 — 同一アプリ内のウィンドウ /
  ダイアログ間フォーカス移動でも発火する (DR-0011 決定 4)。アプリ切替のたびに AXObserver は
  新しい pid へ張り直す (同一 pid への再切替は張り替えスキップ)
- フォーカスウィンドウの frame を AX で取得 (CG y-down、identity 変換 —
  docs/findings/2026-07-12-ax-window-frame-y-down.md)、中心点包含で display id を解決
  (非包含時は中心距離最小へフォールバック)、`.focusedWindowChanged(displayId:windowFrame:)`
  を dispatch
- 描画は 2 レイヤ併存 (DR-0011 決定 5):
  - **モニタ縁フラッシュ** (従来): 対象モニタの縁に systemBlue の内側 24px stroke + 8px blur、
    initial opacity=0.6 → ~0.5s フェード
  - **波動** (主役): ウィンドウ枠を震源とする角丸矩形リングが mm 空間 (隣接物理レイアウト)
    を等方伝播し、全モニタの最遠隅到達で消える。初期値 waveDuration=0.7s / band=30mm /
    initialOpacity=0.5 (`OverlayViewModel` の var、実機調整前提)

### off 時の挙動

- NSWorkspace 通知 removeObserver + AXObserver の RunLoop source 除去・notification 除去
- 減衰中のフラッシュ・波動を即座に消す (VM.clearFocusFlash)
- off 中の発火は「見なかった」扱いで再 on 時にも再生されない (lastFocusFlashGeneration の
  synchronize)

### 動作確認観点

1. **Cmd-Tab で震源ウィンドウから波が出るか** — 切替先ウィンドウの枠形リングが拡がり、
   他モニタにも届いて消える。モニタ縁フラッシュも同時に出る
2. **同一アプリ内のウィンドウ切替 (Cmd-\`) / ダイアログで発火するか** — AXObserver 経路の確認。
   別モニタの同一アプリウィンドウへの切替でも波の震源が追従すること
3. **波の方向感** — LG 側のウィンドウにフォーカスした時、内蔵側では「上から波が来る」見え方に
   なっているか (mm 空間の隣接配置が物理配置と整合するか)
4. **連続切替 (Cmd-Tab 連打)** — 波・フラッシュとも都度リフレッシュされ、多重描画や残留がない
5. **AXObserver のライフサイクル** — (a) トグル off→on を 10 回程度往復 + アプリ切替を挟んでも
   発火が重複しない (二重登録なし) (b) off 直後に発火が完全に止まる (解除漏れなし)
   (c) 長時間 on でメモリが単調増加しない (leak 検査、厳密には Instruments Leaks で
   FocusFlashObserver / AXObserver を確認)
6. **AX 非対応アプリへの degrade** — AXObserverCreate が失敗するアプリに切り替えても crash せず、
   アプリ切替経路のみで動作継続する (Console に degrade ログ)
7. **チューニング体感** — 波の速度 (duration)・帯幅・opacity・色 (cyan) / モニタ縁との主従
   バランス。調整は `OverlayViewModel` の wave 系 var
8. **AX 権限なし時の degrade** — アクセシビリティ権限なしで起動するとメニュー項目が disabled
   (灰色)、toolTip で理由表示
9. **プレゼンテーションモードとの共存** — click 可視化と波動が干渉しないか


## 設定ウィンドウ (DR-0012)

メニューバー `LG` → 「設定...」(,) で開く。タブ = 一般 / レーザー / フォーカスフラッシュ /
キャリブレーション。SettingsStore (UserDefaults key `LaserGuide.v3.displaySettings`) が
単一情報源で、変更は再起動不要で全 overlay に即時反映される。

### 動作確認観点

1. **live apply** — Slider / ColorPicker の変更が操作中の描画に即座に効く (レーザー色は
   マウスを動かしながら、波動はフォーカス切替しながら確認)
2. **永続化** — 変更 → アプリ再起動 → 値と機能トグル (ワープ/プレゼン/フラッシュ) が維持
   される。特にフラッシュ on が再起動後も生きていること (旧: 毎起動 off に戻っていた)
3. **双方向同期** — メニューのトグルと設定ウィンドウ (一般タブ) の Toggle が常に一致する。
   トグルの実挙動 (observer 起動/停止、tap 起動/停止) がチェック表示と一致すること
4. **warp OFF 起動** — ワープを off にして再起動 → ワープが無効のまま起動する
5. **キャリブレーションタブ** — 旧独立ウィンドウと同等に操作できる。開いた直後に
   キャンバスが白紙でなく初期描画される。タブ離脱 → 再表示で状態が壊れない
6. **リソース leak** — 設定ウィンドウを 5 回ほど開閉しても WebContent プロセス
   (Activity Monitor で「LaserGuide」配下) が積み上がらない
7. **デフォルトに戻す** — タブ単位で該当タブの項目だけが既定値に戻る


## 既知の制約 (Phase 1)

- 永続化 (persist effect) は UserDefaults 経路で書き込み済 (DR-0007 決定 2)。v1 設定は起動時に検出したら
  v3 スキーマへ migration + canonicalize (3-part hardwareId → 4-part) して v3 key に保存する。
  実 v1 設定の migration 動作 (配布版 v0.12.1 が書いた実キーからの取り込み) は kawaz 実機で確認。
  Reconcile 結果の inactiveUserSegments は state.inactiveUserSegments に保持されるが、
  キャリブレーション UI での可視化は次ラウンド。
- 実行中の権限失効検知は起動時判定のみ (tap callback 経由での剥奪検知は Phase 2)。
- ディスプレイ構成変更時、overlay を全部作り直す (差分更新は Phase 2)。
- キャリブレーション UI は物理配置編集 (pose translate ドラッグ) のみ。セグメント PB/BP の
  追加/削除編集 UI は次ラウンド (現状は表示のみ)。設定 UI は無い。
- CGDisplayScreenSize=0 のモニタ (プロジェクタ等) では fallback 110dpi を暫定使用するが、
  UI 上の警告表示は Phase 2。
- フォーカスフラッシュ (DR-0009) は Phase A のみ実装済み。同一アプリ内のウィンドウ切替 (Cmd-\`)
  検知 (kAXFocusedWindowChangedNotification observer) と、ウィンドウ枠のアウトライン強調は
  Phase B で追加予定。

## .app バンドルのローカルビルド (DR-0010)

配布用 `LaserGuide.app` を SPM + `scripts/build-app-bundle.sh` で組み立てる手順。CD workflow
(`.github/workflows/cd-auto-release-and-deploy.yml`) も同じ script を APPLE_SIGNING_IDENTITY
経由で呼び出す (kawaz の実 identity は CI 側 secrets)。

### ad-hoc 署名でのローカルビルド

```bash
just build-app
# or
scripts/build-app-bundle.sh --version 0.0.0-local
```

生成物: `build/app/LaserGuide.app` (`codesign --verify --deep --strict` pass)。

### Finder からの起動確認 (kawaz 実機マニュアル手順)

ad-hoc 署名の .app は Gatekeeper に弾かれるので、初回起動時のみ以下:

1. Finder で `build/app/LaserGuide.app` を右クリック → 「開く」を選ぶ (ダブルクリックだと開けない)
2. 「開いてもよろしいですか？」ダイアログで「開く」
3. メニューバーに `LG` アイコンが出ることを確認
4. システム設定 → プライバシーとセキュリティ → アクセシビリティ で `LaserGuide` を許可
5. 再起動後、レーザー描画とワープが `swift run laserguide-dev` と同挙動になることを確認

#### ad-hoc .app の AX 権限は「−で削除 → +で追加 → アプリ再起動」が必要 (2026-07-10 実機確認)

TCC (アクセシビリティ権限 DB) はアプリを **bundle ID + コード署名**で識別する。ad-hoc 署名は
ビルドごとに署名が変わり、また配布版 (v0.12.1、実 identity 署名) の `LaserGuide.app` と
bundle ID が同一のため、**既存の LaserGuide エントリが残っていると新バイナリに権限が効かない**。
チェックボックスの on/off やアプリ再起動だけでは直らない:

1. システム設定 → アクセシビリティのリストから既存の `LaserGuide` を **− ボタンで削除**
2. **+ ボタンで対象の .app を追加し直す**
3. **アプリを再起動** (権限判定は起動時 + メニュー開時)

`just build-app` で .app を作り直すたびに (署名が変わるので) この手順の再実施が必要。

#### 恒久解: ローカルビルドも実 identity で署名する (推奨)

実 identity 署名は designated requirement が証明書ベースで安定するため、リビルドしても
TCC が同一アプリとして扱い、権限の再付与が不要になる (notarization は Gatekeeper 用で
TCC には無関係)。リポ親ディレクトリ (バージョン管理外) の `.envrc` に
`APPLE_SIGNING_IDENTITY` を export しておくと、`scripts/build-app-bundle.sh` が既定
identity として拾い、以後の `just build-app` は常に署名ビルドになる。identity 名は
`security find-identity -v -p codesigning` で確認。切替直後の 1 回だけは従来どおり
− → + → 再起動 の再付与が必要。

### 実 identity 署名の CI 経路 (参考、CI/kawaz 実機のみ)

```bash
scripts/build-app-bundle.sh \
  --version <VERSION> \
  --identity "Developer ID Application: ... (<TEAM>)"
```

identity 指定時のみ `codesign --options runtime --timestamp` が自動付与され、notarize 前提の
Hardened Runtime + secure timestamp が満たされる。以降の `notarytool submit --wait` と
`stapler staple` は CD workflow の該当ステップを参照 (ローカルでは通常実行しない)。

### 検証コマンド (ad-hoc / 実 identity 共通)

```bash
codesign --verify --deep --strict --verbose=2 build/app/LaserGuide.app
codesign -dv --verbose=4 build/app/LaserGuide.app
plutil -p build/app/LaserGuide.app/Contents/Info.plist
```
