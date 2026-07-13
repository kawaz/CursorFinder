# DR-0012: 設定ウィンドウ (表示チューニングの一元化 + キャリブレーションのタブ統合)

関連: DR-0008 (キャリブレーション UI), DR-0011 (波動エフェクト), 実機フィードバック第 5 ラウンド

## 背景

レーザー / フォーカスフラッシュ / 波動に色・速度・太さ等の調整パラメータが増え、現状は
`OverlayViewModel` の var (コード内初期値) でしか触れない。kawaz 要望 (2026-07-13):
これらを調整する設定画面が欲しい。キャリブレーションも独立ウィンドウではなく設定
ダイアログ内のタブの一つに置く方が良い。

## 決定

1. **ネイティブ SwiftUI の設定ウィンドウ** (NSWindow + NSHostingController + TabView)。
   タブ構成: 「一般」「レーザー」「フォーカスフラッシュ」「キャリブレーション」。
   メニューバーに「設定... (⌘, 相当の keyEquivalent=",")」を追加
2. **SettingsStore (App 層, ObservableObject) を表示チューニングの単一情報源にする**:
   - 表示チューニング値は reducer に関与しない (DR-0004 の Action/state を汚さない)。
     App 層の SettingsStore が UserDefaults に永続化し、変更は即座に全 OverlayViewModel
     へ反映 (live apply、再起動不要)
   - 保存形式: Codable struct を JSON で単一 key `LaserGuide.v3.displaySettings` に保存
     (workspace キーとは独立 = モニタ構成に依存しない全体設定)。色は RGBA hex 文字列
   - 機能トグル (境界ワープ / プレゼンテーションモード / フォーカスフラッシュ) も
     SettingsStore に含めて**永続化する** (従来はフラッシュ等が毎起動 off に戻っていた)。
     既存メニューのトグル項目は高頻度スイッチとして残し、SettingsStore と双方向同期
3. **Phase 1 の公開パラメータ**:
   - 一般: 境界ワープ on/off、プレゼンテーションモード on/off、フォーカスフラッシュ on/off
   - レーザー: グラデーション 3 色 + 各 opacity、表示デバウンス、非アクティブ非表示閾値、
     フェードアウト時間、太さ (corner/tip 半幅)
   - フォーカスフラッシュ: モニタ縁の色 / 初期 opacity / duration、波動の色 / duration /
     帯幅 mm / 初期 opacity
   - 数値は Slider + 現在値表示、色は ColorPicker、「デフォルトに戻す」ボタン (タブ単位)
4. **キャリブレーションはタブに統合**: CalibrationWindowController の WKWebView 生成 +
   Swift↔JS 配線を view 提供型 (controller) に切り出して設定ウィンドウのタブへ embed。
   独立ウィンドウ経路は廃止し、メニュー「キャリブレーション...」は設定ウィンドウを
   該当タブで開くショートカットにする (項目自体は残す)
5. **ウィンドウは単一インスタンス・リサイズ可**。初期サイズはキャリブレーションタブが
   実用になる大きさ (1000x640 を下回らない)

6. **色は固定 sRGB 値として保存・描画する**: 従来描画の SwiftUI semantic color
   (Color.red 等) は appearance 適応する動的色で、保存経路 (hex 量子化) と往復一致
   しない。デフォルト値は semantic color の実測 sRGB 近似 (red=#FF4245 /
   yellow=#FFD600 / blue=#0091FF / cyan=#3CD3FE) に固定する。light/dark 適応は
   失うが、ユーザが ColorPicker で自由に変更できるため許容 (レビュー M-3 裁定)

## 不採用案

- **WKWebView で設定画面ごと作る**: キャリブレーション (幾何キャンバス) と違い、設定
  フォームは標準コントロール (Slider/ColorPicker/Toggle) の集合であり、ネイティブ
  SwiftUI が macOS の作法・アクセシビリティ・実装量すべてで勝る
- **設定値を Core の AppState/Action に載せる**: 表示チューニングは描画層の関心事で
  reducer の判定 (ワープ幾何等) に影響しない。Core を汚さず App 層で完結させる。
  ワープ on/off 等 Core に効く既存経路 (.settingsChanged 等) は従来どおり
- **メニューのトグル項目を廃止して設定画面に一本化**: ワープ/フラッシュの on/off は
  高頻度操作でメニュー 1 クリックの価値が高い。二重管理の懸念は SettingsStore 単一
  情報源 + メニューは表示だけで解消する

## 検証の輪郭

- SettingsStore: encode/decode 往復、部分的な既存保存値 (新パラメータ追加時) の
  tolerant decode、デフォルト値へのリセット、の unit test
- live apply: SettingsStore 変更 → VM の該当 var へ反映される配線の unit test
- 実機: 各 Slider/ColorPicker の変更が即時に描画へ効く / 再起動後も保持 /
  メニュートグルと設定画面トグルの双方向同期 / キャリブレーションタブが従来の
  独立ウィンドウと同等に操作できる

## ステータス

Accepted (2026-07-13, kawaz 要望に基づく)
