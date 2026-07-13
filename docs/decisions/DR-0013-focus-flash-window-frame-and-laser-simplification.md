# DR-0013: フォーカスフラッシュのウィンドウ枠化 + AX 購読拡張 + レーザー形状の簡素化

関連: DR-0009 (フォーカスフラッシュ), DR-0011 (波動エフェクト), DR-0012 (設定ウィンドウ),
実機フィードバック第 6 ラウンド (2026-07-13)

## 背景

DR-0011 で入れた 2 レイヤ (モニタ縁フラッシュ + 波動) のうち、モニタ縁は kawaz オーダー
「ウィンドウ枠」から乖離した実装で、内蔵モニタのフルスクリーン運用では区別できなかった
ため気づかれていなかった。実機第 6 ラウンドで「モニタ縁いらん、ウィンドウ枠じゃないの?」
と裁定。あわせて:

- 同一アプリ内のウィンドウ切替やダイアログ (LaserGuide 設定 / 1Password TouchID 等) で
  フラッシュが発火していない (kAXFocusedWindowChanged 単独では取りこぼす通知パターン
  がある)
- レーザーのグラデーション中央 (mid) は不要、頂点辺半幅 (tipHalfWidth) は常に 0 で良い、
  カーソル周辺の消える範囲半径 (standoff) を設定できるようにしたい
- 設定ウィンドウの秒単位スライダーの max がバラバラで気持ち悪い
- トレイメニューの「キャリブレーション...」は設定ウィンドウ経由で足りるので消し忘れ扱い

## 決定

### 1. モニタ縁フラッシュを廃止し、ウィンドウ枠アウトラインを描画する

DR-0011 決定 5「モニタ縁と波動の併存」を撤回。フォーカスフラッシュは「震源ウィンドウの
矩形アウトライン」+「その震源から拡がる波動」の 2 レイヤで、モニタ縁ハイライトは削除する。

- 対象: `state.focusFlash.windowFrame` (CG グローバル論理座標) を各 overlay の view-local
  へ変換し、自 display と重なる部分だけを描画 (`intersection(with:)`)。モニタをまたぐ
  ウィンドウはそれぞれの overlay が自分の担当部分を描く
- 減衰: 既存 `focusFlashFadeTimer` (30ms 刻み) をそのまま使う。initial opacity /
  duration / color はそのまま SettingsStore の focus flash 項目を再利用 (項目名は
  「モニタ縁」ラベルを「ウィンドウ枠」に変える)

### 2. AX 購読を拡張してダイアログ/シート/新規ウィンドウでも発火させる

現状 `kAXFocusedWindowChangedNotification` のみ購読。以下を追加購読:

- `kAXMainWindowChangedNotification`: アプリのメインウィンドウ変更 (フォーカス変更を
  伴わない場面がある)
- `kAXWindowCreatedNotification`: 新規ウィンドウ生成 (ダイアログ・シート・新規ドキュメント
  ウィンドウ)

いずれも AXObserver が既に張っているアプリレベルで通知を張り、handler は共通の
`handleFocusedWindowChanged()` に流す。**kAXFocusedUIElementChanged は購読しない**
(テキストフィールド間フォーカス移動などで大量発火し、UX ノイズになる)。

1Password TouchID ダイアログは別プロセスの可能性があるため、`didActivateApplication`
経由の pid 張り直しでカバーされる (別プロセスならプロセス起動で active になる)。
実機で発火しないケースは Console のログで切り分けて follow-up issue へ。

### 3. レーザー形状の簡素化

- **グラデーション色は 2 色 (near / far)**。中央 mid を廃止。3 stop → 2 stop、
  gradient は `location 0.0` = near, `location 1.0` = far
- **頂点辺半幅は常に 0** (完全な三角形に統一)。tipHalfWidth は VM / Settings から
  廃止。LaserGeometry の drawLaser 経路も頂点を 1 点に集約
- **standoff は px 固定値の設定項目にする**: 現在の「距離比率 + min/max クランプ」
  は複雑で調整しにくい。`laserStandoffPx: Double`, 初期値 40 (旧 v1 と同じ、
  範囲 0...200 step 5)。`LaserGeometry.standoffDistance` は削除し、
  `taperApexPoint(from:to:standoff:)` に固定値を渡す

### 4. 設定ウィンドウの Slider range を統一

- **秒単位 (TimeInterval) は全て 0...2.0, step 0.05** に揃える:
  `laserShowDebounce` / `inactivityThreshold` / `laserFadeOutDuration` /
  `focusFlashDuration` / `waveDuration`。目盛りとバラつきの気持ち悪さ解消
- opacity 系 (0...1 step 0.05) と mm 系 (帯幅 5...100 step 1) は既存のまま
- 新規 `laserStandoffPx` は 0...200 step 5
- `laserCornerHalfWidth` は 1...32 step 0.5 のまま (px 単位、標準的な太さ範囲)

### 5. メニュー「キャリブレーション...」項目を削除

設定ウィンドウのタブから開けるため冗長。⌘K は unused に (設定... の "," で開いて
タブへ移動する運用に集約)。

## 追記 (2026-07-13 レビュー後)

- **ウィンドウ枠の描画は windowFrame 全体を stroke してから display にクリップ**
  する: intersection 矩形の 4 辺を単純に stroke すると、モニタまたぎ時に**display
  境界 (= 実際のウィンドウ枠ではない辺)** に線が乗る。両 overlay の境界辺が
  つながって「モニタ境界に太い線」となる描画欠陥を避けるため、windowFrame の
  Rectangle を描いてから `.clipShape(自 display 領域)` で切る (境界辺は描画されない)
- **stroke 厚み / blur 半径は SettingsStore に載せる** (`focusFlashStrokeWidth` /
  `focusFlashBlurRadius`)。DR-0012 決定 2「表示チューニングは SettingsStore 単一
  情報源」との整合、および実機で色 α を 0 にしても blur 域が残る等の UX 調整
  余地を残すため
- **`laserStandoffPx` は `max(0, standoff)` で clamp** して負値経路を防衛
  (UI Slider は 0...200 なので現状経路は安全だが、旧 JSON / 直接編集耐性)
- **AX 通知の全失敗時 tearDown**: 3 通知全部 register 失敗した場合、AXObserver
  は idle のまま RunLoop に張られ leak する。install 内で成功カウンタを取り、
  0 なら tearDown してから return する
- **フェード時間 0 秒は「発火しない」に倒す**: focusFlashDuration=0 / waveDuration=0
  でも 1 tick だけ発火する現状は UX 齟齬。VM 側で 0 なら早期 return

## SettingsStore schema の互換性

- 削除フィールド: `laserColorMid`, `laserTipHalfWidth`
- 新規フィールド: `laserStandoffPx`
- tolerant decode で「欠落フィールドは default」を維持するため、旧保存 JSON からの
  読み込みで新フィールドは default (40) が入り、削除フィールドは無視される (現行の
  DR-0012 decodeIfPresent 実装で自動対応)
- テスト `testDefaultsMatchCurrentImplementationInitialValues` は「semantic 実測近似」
  ではなく「実機第 6 ラウンド裁定後の値」に意図を書き直す (mid 色の assert は削除、
  standoff px の assert を追加)

## 検証の輪郭

- LaserGeometry 単体: tipHalfWidth 廃止で drawLaser の頂点が 1 点に、standoff 固定 px、
  gradient stops = 2 の描画テスト (画像比較でなく Path 幾何の期待値 assert)
- FocusFlashObserver: kAXWindowCreated / kAXMainWindowChanged が呼ばれた時に共通
  handler が発火することを、C callback を挟まずテスト可能な部分で固定
- LaserOverlayView (ウィンドウ枠描画): 純関数 `windowFrameLocalRect(windowFrame:
  displayBounds:) -> LogicalRect?` (自 display と重ならなければ nil) を切り出して
  テスト。モニタまたぎ・自 display 外の 3 パターンで正しくクリップされること
- 実機: 波動のみで気づけるか / ウィンドウ枠アウトラインの視認性 / 秒単位スライダー
  の目盛り整合 / LaserGuide 設定ダイアログ・1Password TouchID・Xcode シート等での
  発火有無 (発火しないケースは runbook + follow-up issue)

## 不採用案

- **モニタ縁を「薄く残す」**: kawaz が「いらん」と明示裁定
- **kAXFocusedUIElementChanged を購読**: テキストフィールド間フォーカス移動で
  大量発火。UX ノイズが実害を上回る
- **standoff を距離比率のまま設定化**: 「消える半径」の直感 = px 距離。比率だと
  レーザーの長さで見え方が変わり調整が難しい
- **秒単位 Slider の最大値をパラメータごとに最適化**: 目盛り整合の気持ち悪さの方が
  優先度が高い (実運用の値は 0...1 で足り、上限に余裕があっても実害なし)

## ステータス

Accepted (2026-07-13, 実機第 6 ラウンド裁定)
