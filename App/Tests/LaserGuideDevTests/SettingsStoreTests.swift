// SettingsStore (DR-0012) の仕様書テスト。
//
// 検証輪郭 (DR-0012 検証):
//   - encode/decode 往復 (= 全フィールドが JSON 経由で lossless に戻る)
//   - tolerant decode (= 欠落フィールドはデフォルト値で補完、古い保存 JSON が破棄されない)
//   - デフォルト値が現行実装の初期値と一致 (= SettingsStore 導入で見た目が変わっていない証拠)
//   - タブ単位リセット (resettingLaser 等) が該当タブのフィールドだけを default に戻す
//   - live apply: DisplaySettings.applyDisplayParameters(to:) で VM の該当 var が更新される
//     (AppDelegate 購読ハンドラが呼び出す抽出済み extension を直接テスト)
//   - 色 RGBAColor の hex ラウンドトリップ (#RRGGBBAA 8 桁固定)
import XCTest
import Foundation
import CoreGraphics
@testable import LaserGuideDev
import LaserGuideCore

final class SettingsStoreTests: XCTestCase {

    // MARK: - RGBAColor hex ラウンドトリップ

    /// hexString 出力は常に大文字 8 桁の `#RRGGBBAA` 固定、parseHex は同一を戻す (= idempotent)。
    /// 0..1 double 値が 255 段階に quantize されて誤差が出るのは仕様なので、ラウンドトリップは
    /// hexString → parseHex → hexString の 2 段目一致で検証する (小数値の直接一致ではなく)。
    func testRGBAColorHexRoundTripIsIdempotent() {
        let c = RGBAColor(r: 0.5, g: 0.25, b: 0.125, a: 0.9)
        let h1 = c.hexString
        let parsed = RGBAColor.parseHex(h1)
        XCTAssertNotNil(parsed, "8 桁 hex は parse できる")
        XCTAssertEqual(parsed?.hexString, h1, "parse → hexString で同一文字列に戻る")
    }

    /// #RRGGBBAA 以外 (前置なし / 6 桁 RGB / 不正文字) は parse 失敗を返す (= 保存経路が
    /// 常に 8 桁固定であることの前提を壊さないため、silent fallback しない)。
    func testRGBAColorParseRejectsInvalidFormats() {
        XCTAssertNil(RGBAColor.parseHex("FF0000FF"), "先頭 # が無いなら不許可")
        XCTAssertNil(RGBAColor.parseHex("#FF0000"),  "6 桁 (RGB) は不許可 (常に 8 桁固定)")
        XCTAssertNil(RGBAColor.parseHex("#FF0000GG"),"hex でない文字を含むと不許可")
    }

    /// Codable: RGBAColor は singleValueContainer で hex 文字列としてエンコードされる
    /// (= JSON 上で `"laserColorNear": "#FF0000D9"` のようにコンパクト表現になる)。
    func testRGBAColorEncodesAsSingleHexString() throws {
        let c = RGBAColor(r: 1.0, g: 0.0, b: 0.0, a: 0.85)
        let data = try JSONEncoder().encode(c)
        let s = String(data: data, encoding: .utf8)
        XCTAssertEqual(s, "\"\(c.hexString)\"", "hex 文字列単体で JSON リテラルになる")
    }

    // MARK: - DisplaySettings encode/decode 往復

    /// デフォルト値を encode → decode すると同値に戻る (= 全フィールドが Codable 対応済み、
    /// スキーマの穴 (encode し忘れ / key の綴り違い) を検出する)。
    func testDisplaySettingsRoundTripPreservesAllFieldsFromDefaults() throws {
        let original = DisplaySettings.defaults
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: data)
        XCTAssertEqual(decoded, original, "デフォルト値は encode/decode で同値に戻る")
    }

    /// 非デフォルト値 (境界値含む) を encode → decode で同値。RGBAColor の double 誤差は
    /// hex quantize 後の再構成値で見るため、original 側も hex ラウンドトリップ済みの色を使う。
    func testDisplaySettingsRoundTripPreservesArbitraryValues() throws {
        let quantized = RGBAColor.parseHex("#7F3F1FEB")!  // 任意の 8 桁を hex から作って quantize 済みに揃える
        var settings = DisplaySettings.defaults
        settings.warpEnabled = false
        settings.presentationModeEnabled = true
        settings.focusFlashEnabled = true
        settings.laserShowDebounce = 0.42
        settings.laserFadeOutDuration = 0.11
        settings.laserCornerHalfWidth = 12.5
        settings.laserColorNear = quantized
        settings.waveBandMM = 55
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: data)
        XCTAssertEqual(decoded, settings, "任意値も往復で同値")
    }

    // MARK: - tolerant decode

    /// フィールドが 1 つだけの JSON (古いバージョン相当 / 部分保存された想定) を decode すると、
    /// 指定フィールドはその値を取り、それ以外はすべてデフォルト値になる (= 破棄されない)。
    /// この tolerant 挙動が無いと、将来のパラメータ追加時にユーザの既存設定が消える。
    func testTolerantDecodeFillsMissingFieldsWithDefaults() throws {
        let json = #"{"laserShowDebounce": 0.5}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: json)
        XCTAssertEqual(decoded.laserShowDebounce, 0.5, "指定したフィールドはその値")
        // 他フィールドはデフォルト値と一致する
        XCTAssertEqual(decoded.warpEnabled, DisplaySettings.defaults.warpEnabled)
        XCTAssertEqual(decoded.waveDuration, DisplaySettings.defaults.waveDuration)
        XCTAssertEqual(decoded.laserColorNear, DisplaySettings.defaults.laserColorNear,
                       "未指定色フィールドはデフォルトで補完")
    }

    /// 空 JSON `{}` でも decode でき、全フィールドがデフォルト値になる (= 最小ケース)。
    func testTolerantDecodeWithEmptyObjectReturnsAllDefaults() throws {
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(decoded, DisplaySettings.defaults, "空 JSON はデフォルトと同値")
    }

    // MARK: - デフォルト値の固定 (レビュー M-3 で色は semantic 実測近似に確定)

    /// タイミング / 太さ / 機能トグルの defaults は DR-0013 実機第 6 ラウンド裁定後の値をそのまま持つ。
    /// **色は semantic color (Color.red 等) の実測 sRGB 近似で固定** (DR-0012 決定 6、
    /// レビュー M-3 の裁定 — 動的な semantic color は保存経路の hex 量子化と往復一致しないため、
    /// light/dark 適応を捨てて固定 sRGB を採用)。opacity 成分は現行のグラデ stop (角 0.85 / ポインタ側 0.35)
    /// と一致させることでレーザーの透け感を保つ。
    ///
    /// DR-0013 変更点:
    ///   - `laserTipHalfWidth` / `laserColorMid` 廃止 (3 stop → 2 stop、頂点 1 点集約)
    ///   - `laserStandoffPx` 新設 (px 固定値、既定 40 = 旧 v1 と同値)
    func testDefaultsMatchCurrentImplementationInitialValues() {
        let d = DisplaySettings.defaults
        // タイミング (OverlayViewModel var 初期値と同値)
        XCTAssertEqual(d.laserShowDebounce, 0.1)
        XCTAssertEqual(d.inactivityThreshold, 0.3)
        XCTAssertEqual(d.laserFadeOutDuration, 0.25)
        XCTAssertEqual(d.focusFlashDuration, 0.5)
        XCTAssertEqual(d.focusFlashInitialOpacity, 0.6)
        // DR-0013 追記 M-1: stroke 厚み / blur 半径の default 固定 (旧 hardcode の 6 / 3 を移設)。
        XCTAssertEqual(d.focusFlashStrokeWidth, 6.0,
                       "旧 LaserOverlayView.focusFlashView の hardcode 値 (6px) を default で保つ")
        XCTAssertEqual(d.focusFlashBlurRadius, 3.0,
                       "旧 LaserOverlayView.focusFlashView の hardcode 値 (3px) を default で保つ")
        XCTAssertEqual(d.waveDuration, 0.35)
        XCTAssertEqual(d.waveBandMM, 30)
        XCTAssertEqual(d.waveInitialOpacity, 0.5)
        // 太さ (LaserGeometry static 定数と同値) + DR-0013 の standoff px 固定
        XCTAssertEqual(d.laserCornerHalfWidth, Double(LaserGeometry.defaultCornerHalfWidth))
        XCTAssertEqual(d.laserStandoffPx, 40.0,
                       "DR-0013: 消える範囲半径は px 固定 40 (旧 v1 の固定 40px を復刻)")
        // 機能トグル (旧 AppDelegate の var 初期値)
        XCTAssertEqual(d.warpEnabled, true, "境界ワープは既定で on (v1 から継続)")
        XCTAssertEqual(d.presentationModeEnabled, false, "プレゼンテーションモードは既定で off")
        XCTAssertEqual(d.focusFlashEnabled, false, "フォーカスフラッシュは既定で off (DR-0009 Phase A の保守判断)")
        // 色 (semantic 実測近似の固定 sRGB、opacity は現行グラデ stop 0.85 / 0.35)。
        // hex は defaults 定義側と同じリテラルを再走査して不変性を固定する (= リファクタで
        // ずれた場合にここで即検出)。DR-0013 で mid 廃止 (2 stop 化)。
        XCTAssertEqual(d.laserColorNear.hexString, "#FF4245D9", "Color.red 近似 + opacity 0.85 (グラデ角側)")
        XCTAssertEqual(d.laserColorFar.hexString,  "#FFFFFF59", "Color.white + opacity 0.35 (ポインタ側)")
        XCTAssertEqual(d.focusFlashColor.hexString, "#0091FFFF", "Color.blue 近似 + opacity 1.0 (ウィンドウ枠)")
        XCTAssertEqual(d.waveColor.hexString,       "#3CD3FEFF", "Color.cyan 近似 + opacity 1.0 (波動)")
    }

    /// DR-0013 tolerant decode: **廃止フィールド** (`laserColorMid` / `laserTipHalfWidth`) を持つ旧 JSON を
    /// 読み込んでも、Codable の未知キー無視で自然に捨てられ、他フィールドは無事に取り込まれる。
    /// これにより古い保存値からの migration がユーザに見えない (再保存で新スキーマに揃う)。
    func testTolerantDecodeIgnoresRemovedFieldsFromOldJSON() throws {
        // 旧スキーマ相当の JSON (廃止フィールドを含み、新フィールド laserStandoffPx は欠落)
        let oldJSON = """
        {
            "laserColorMid": "#FFD600A6",
            "laserTipHalfWidth": 0.5,
            "laserShowDebounce": 0.42
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: oldJSON)
        // 廃止フィールドは無視 (decode 側で読まないので存在しても影響なし)
        XCTAssertEqual(decoded.laserShowDebounce, 0.42, "生きているフィールドは尊重される")
        // 新フィールド (欠落) はデフォルトで補完
        XCTAssertEqual(decoded.laserStandoffPx, DisplaySettings.defaults.laserStandoffPx,
                       "新フィールドは欠落時に default (40) で補完")
        // 他フィールドも default 補完
        XCTAssertEqual(decoded.laserColorNear, DisplaySettings.defaults.laserColorNear)
        XCTAssertEqual(decoded.laserColorFar, DisplaySettings.defaults.laserColorFar)
    }

    /// DR-0013 新フィールド `laserStandoffPx` を含む JSON を保存 → 読み込みで往復する。
    /// tolerant decode の「新フィールド default 補完」パスと、通常 encode の両方を固定する。
    func testStandoffPxRoundTripPreservesArbitraryValues() throws {
        var settings = DisplaySettings.defaults
        settings.laserStandoffPx = 25
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: data)
        XCTAssertEqual(decoded.laserStandoffPx, 25, "任意値でも encode/decode 往復")
    }

    // MARK: - タブ単位リセット

    /// resettingLaser は Laser タブに属するフィールドだけを default に戻し、
    /// 他タブのフィールド (機能トグル / 波動) は保持する (= タブ独立性)。
    func testResettingLaserRestoresOnlyLaserFields() {
        var s = DisplaySettings.defaults
        s.warpEnabled = false                                        // 一般タブ (保持されるべき)
        s.laserShowDebounce = 0.5                                    // レーザータブ (戻るべき)
        s.laserColorNear = RGBAColor.parseHex("#123456FF")!          // レーザータブ (戻るべき)
        s.waveDuration = 0.99                                        // フォーカスフラッシュタブ (保持されるべき)

        let r = s.resettingLaser()
        XCTAssertEqual(r.warpEnabled, false, "一般タブは変更なし")
        XCTAssertEqual(r.waveDuration, 0.99, "フォーカスフラッシュタブは変更なし")
        XCTAssertEqual(r.laserShowDebounce, DisplaySettings.defaults.laserShowDebounce, "Laser 側は default")
        XCTAssertEqual(r.laserColorNear, DisplaySettings.defaults.laserColorNear, "Laser 側の色も default")
    }

    /// resettingGeneral は機能トグルだけを default に戻す。
    func testResettingGeneralRestoresOnlyToggles() {
        var s = DisplaySettings.defaults
        s.warpEnabled = false
        s.presentationModeEnabled = true
        s.focusFlashEnabled = true
        s.laserShowDebounce = 0.99  // 保持されるべき

        let r = s.resettingGeneral()
        XCTAssertEqual(r.warpEnabled, DisplaySettings.defaults.warpEnabled)
        XCTAssertEqual(r.presentationModeEnabled, DisplaySettings.defaults.presentationModeEnabled)
        XCTAssertEqual(r.focusFlashEnabled, DisplaySettings.defaults.focusFlashEnabled)
        XCTAssertEqual(r.laserShowDebounce, 0.99, "Laser 側は変更なし")
    }

    /// resettingFocusFlash はウィンドウ枠 + 波動を default に戻し、レーザー / 一般タブは保持。
    /// DR-0013 追記 M-1: focusFlashStrokeWidth / focusFlashBlurRadius もフォーカスフラッシュタブ配下
    /// (「ウィンドウ枠」セクション) のため、reset 対象に含まれることを固定する。
    func testResettingFocusFlashRestoresOnlyFlashAndWave() {
        var s = DisplaySettings.defaults
        s.warpEnabled = false                    // 一般 (保持)
        s.laserShowDebounce = 0.99               // レーザー (保持)
        s.focusFlashDuration = 0.99              // フラッシュ (戻る)
        s.focusFlashStrokeWidth = 15             // フラッシュ / stroke (戻る)
        s.focusFlashBlurRadius = 10              // フラッシュ / blur (戻る)
        s.waveBandMM = 99                        // 波動 (戻る)
        s.waveColor = RGBAColor.parseHex("#00000000")!  // 波動 (戻る)

        let r = s.resettingFocusFlash()
        XCTAssertEqual(r.warpEnabled, false)
        XCTAssertEqual(r.laserShowDebounce, 0.99)
        XCTAssertEqual(r.focusFlashDuration, DisplaySettings.defaults.focusFlashDuration)
        XCTAssertEqual(r.focusFlashStrokeWidth, DisplaySettings.defaults.focusFlashStrokeWidth,
                       "stroke 厚みも default に戻る (フォーカスフラッシュタブ配下)")
        XCTAssertEqual(r.focusFlashBlurRadius, DisplaySettings.defaults.focusFlashBlurRadius,
                       "blur 半径も default に戻る (フォーカスフラッシュタブ配下)")
        XCTAssertEqual(r.waveBandMM, DisplaySettings.defaults.waveBandMM)
        XCTAssertEqual(r.waveColor, DisplaySettings.defaults.waveColor)
    }

    // MARK: - SettingsStore (UserDefaults 経路) の読み書き

    /// UserDefaults 空の時は defaults が返る (= 初回起動時にユーザが「何もいじっていない」
    /// と同じ挙動)。SettingsStore.load 経由も同じ。
    func testStoreWithEmptyDefaultsReturnsDefaultValues() {
        let ud = makeIsolatedDefaults()
        let loaded = SettingsStore.load(from: ud)
        XCTAssertEqual(loaded, DisplaySettings.defaults)
    }

    /// SettingsStore.settings への代入は didSet で UserDefaults に保存され、
    /// 別の SettingsStore インスタンスからロードすると同値が復元できる
    /// (= 起動をまたいだ永続化の骨格)。
    func testStoreWritesToUserDefaultsAndReloadRecoversSameValue() {
        let ud = makeIsolatedDefaults()
        let store1 = SettingsStore(userDefaults: ud)
        store1.settings.laserShowDebounce = 0.42
        store1.settings.laserColorNear = RGBAColor.parseHex("#ABCDEF11")!

        let store2 = SettingsStore(userDefaults: ud)
        XCTAssertEqual(store2.settings.laserShowDebounce, 0.42)
        XCTAssertEqual(store2.settings.laserColorNear, RGBAColor.parseHex("#ABCDEF11")!)
    }

    // MARK: - live apply (SettingsStore → OverlayViewModel)

    /// DR-0012 決定 2「変更は即座に全 OverlayViewModel へ反映」の配線検証。
    /// AppDelegate の購読ハンドラが呼び出す抽出済み extension `applyDisplayParameters(to:)` を
    /// 直接呼んで、VM の全該当 var がストアの値に更新されることを固定する
    /// (= AppDelegate 側の for-loop がこの extension を呼ぶだけの薄い配線であるための土台)。
    func testApplyDisplayParametersUpdatesAllVMFieldsFromSettings() {
        var s = DisplaySettings.defaults
        s.laserShowDebounce = 0.42
        s.inactivityThreshold = 0.55
        s.laserFadeOutDuration = 0.11
        s.laserCornerHalfWidth = 12
        s.laserStandoffPx = 25  // DR-0013: px 固定 standoff
        s.laserColorNear = RGBAColor.parseHex("#010203FF")!
        s.laserColorFar = RGBAColor.parseHex("#070809BB")!
        s.focusFlashDuration = 0.9
        s.focusFlashInitialOpacity = 0.3
        s.focusFlashColor = RGBAColor.parseHex("#0A0B0CCC")!
        s.focusFlashStrokeWidth = 9
        s.focusFlashBlurRadius = 4
        s.waveDuration = 0.77
        s.waveBandMM = 77
        s.waveInitialOpacity = 0.22
        s.waveColor = RGBAColor.parseHex("#0D0E0FDD")!

        let display = Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100), pose: .identity)
        let state = AppState.initial(displays: [display])
        let vm = OverlayViewModel(initialState: state)

        s.applyDisplayParameters(to: vm)

        XCTAssertEqual(vm.laserShowDebounce, 0.42)
        XCTAssertEqual(vm.inactivityThreshold, 0.55)
        XCTAssertEqual(vm.laserFadeOutDuration, 0.11)
        XCTAssertEqual(vm.laserCornerHalfWidth, 12)
        XCTAssertEqual(vm.laserStandoffPx, 25)
        XCTAssertEqual(vm.laserColorNear, s.laserColorNear)
        XCTAssertEqual(vm.laserColorFar, s.laserColorFar)
        XCTAssertEqual(vm.focusFlashDuration, 0.9)
        XCTAssertEqual(vm.focusFlashInitialOpacity, 0.3)
        XCTAssertEqual(vm.focusFlashColor, s.focusFlashColor)
        XCTAssertEqual(vm.focusFlashStrokeWidth, 9,
                       "M-1: stroke 厚みも VM に流れる (旧 hardcode 6px を SettingsStore 経由に置換)")
        XCTAssertEqual(vm.focusFlashBlurRadius, 4,
                       "M-1: blur 半径も VM に流れる (旧 hardcode 3px を SettingsStore 経由に置換)")
        XCTAssertEqual(vm.waveDuration, 0.77)
        XCTAssertEqual(vm.waveBandMM, 77)
        XCTAssertEqual(vm.waveInitialOpacity, 0.22)
        XCTAssertEqual(vm.waveColor, s.waveColor)
    }

    // MARK: - helper

    /// テスト間で汚染されない UserDefaults suite を毎回作る。既存 PersistenceBootTests と同じパターン。
    private func makeIsolatedDefaults(suite: String = "LaserGuide.SettingsStoreTests.\(UUID().uuidString)") -> UserDefaults {
        let ud = UserDefaults(suiteName: suite)!
        ud.removePersistentDomain(forName: suite)
        return ud
    }
}
