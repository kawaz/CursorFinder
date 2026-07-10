# v3 開発用アプリの起動手順

`swift run laserguide-dev` で立ち上げる開発用の常駐アプリ。メニューバーに `LG` として現れ、
各ディスプレイに透明オーバーレイを張ってレーザーを描画し、CGEventTap 経由で仮想境界ワープを実行する。
リリース用 xcodeproj への配線は別タスク。

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
| キャリブレーション... | 物理配置編集ウィンドウ (WKWebView) を開く。詳細は下記 |
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
- **アイドルフェード**: ポインタ移動を止めると 0.3 秒後にレーザーが消える。移動を再開
  すると即座に再表示される (2026-07-10 フィードバック #2)。
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
  otherMouseDragged) は OS へ素通しする (2026-07-10 フィードバック #5)。レーザーが
  表示中 (直近 0.3 秒以内にマウス移動があった) のドラッグでは、NSEvent global monitor
  経由で overlay がポインタ位置を拾い続けるので描画が追従する。レーザーが非表示
  (アイドルフェード後) の間に始まったドラッグは追跡自体をスキップする (無関係な
  ウィンドウ操作である可能性が高いため、CG 変換・overlay 走査のコストを払わない)。
  view への反映 (tap 経由・drag monitor 経由とも) は 60Hz (16ms) の coalesce タイマーに
  まとめられ、イベントレートに比例して SwiftUI 再描画コストが増えないようにしている
  (2026-07-10 第 2 ラウンド #5: 「レーザー非表示中でもドラッグが重い」という実機報告への対応)。
  ワープ判定はドラッグ中は発火しない設計。

## キャリブレーション画面 (DR-0008)

メニューバー `LG` → 「キャリブレーション...」 (⌘K) で開く。WKWebView 上の web UI で、
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

## フォーカスフラッシュ (DR-0009 Phase A) の確認観点

メニュー `LG → フォーカスフラッシュ` を on にして (デフォルト off):

- **Cmd-Tab でアプリ切替**: フォーカス先ウィンドウがあるモニタの縁が短時間 (~0.5s) 光ってフェードアウトする
- **同一アプリ内のウィンドウ切替** (Cmd-`): Phase A は NSWorkspace のアプリ切替通知ベースのため発火しない場合がある (Phase B で AX observer による対応を検討、実機観測を issue に記録)
- **別モニタのウィンドウへ切替**: 移動先モニタだけが光る
- menubar / Dock 等 AX 非対応対象への切替は発火しない (仕様、observer 冒頭コメント参照)

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
