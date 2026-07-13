// applySettingsCore (DR-0012 live apply の核ロジック) の分岐を副作用フックで検証する。
//
// 検証輪郭 (レビュー m-5 対応 — トグル副作用の無テストがバグを許した反省):
//   - 初回適用 (previous == nil) では全機能トグル副作用が 1 回ずつ発火する (C-2 起動時 warp 尊重の下敷き)
//   - 表示パラメータ (色 / 太さ) は毎回全 VM に再適用される (M-1 rebuild 経路の下敷き)
//   - 差分検知: previous と等しい分岐は副作用が発火しない (連打抑制)
//   - **副作用フックは必ず新値 `current` を受け取る** (C-1 willSet stale read 回帰防止 — 旧値を
//     受け取ってしまう回帰があれば new value と old value の乖離が現れるため、mock 側で
//     受信引数を記録して assert する)
import XCTest
@testable import LaserGuideDev
import LaserGuideCore

final class SettingsSideEffectsTests: XCTestCase {

    /// mock 用の記録 — 各フック呼び出しの引数を並べて保持し、assert で順序と値を検証する。
    private final class Recorder {
        var warpCalls: [Bool] = []
        var presentationCalls: [DisplaySettings] = []
        var focusFlashCalls: [DisplaySettings] = []
        var menuUpdateCalls: [DisplaySettings] = []
        var applyDisplayParamCalls: [DisplaySettings] = []
    }

    private func makeEffects(_ rec: Recorder) -> SettingsSideEffects {
        SettingsSideEffects(
            setWarpEnabled: { rec.warpCalls.append($0) },
            applyPresentationMode: { rec.presentationCalls.append($0) },
            applyFocusFlash: { rec.focusFlashCalls.append($0) },
            updateMenuStates: { rec.menuUpdateCalls.append($0) },
            applyDisplayParametersToAllViewModels: { rec.applyDisplayParamCalls.append($0) })
    }

    // MARK: - 初回適用

    /// previous=nil (= 起動直後の初回適用) では全機能トグル副作用が 1 回ずつ発火し、
    /// メニューと表示パラメータも 1 回ずつ反映される。これが C-2「起動時 warpEnabled=false 保存を
    /// setWarpEnabled(false) 経由で尊重する」経路の下敷き。
    func testInitialApplyFiresAllToggleSideEffectsOnce() {
        let rec = Recorder()
        let effects = makeEffects(rec)
        var settings = DisplaySettings.defaults
        settings.warpEnabled = false                 // 保存 OFF の想定
        settings.presentationModeEnabled = true      // 保存 ON の想定
        settings.focusFlashEnabled = true            // 保存 ON の想定

        applySettingsCore(previous: nil, current: settings, effects: effects)

        XCTAssertEqual(rec.warpCalls, [false], "起動時 warp OFF を副作用として明示的に流す")
        XCTAssertEqual(rec.presentationCalls.count, 1)
        XCTAssertEqual(rec.focusFlashCalls.count, 1)
        XCTAssertEqual(rec.menuUpdateCalls.count, 1)
        XCTAssertEqual(rec.applyDisplayParamCalls.count, 1, "表示パラメータも初回で全 VM に反映")
        // C-1 の下敷き: 副作用が受け取った settings は current 値 (= 新値) と一致する
        XCTAssertEqual(rec.presentationCalls[0].presentationModeEnabled, true)
        XCTAssertEqual(rec.focusFlashCalls[0].focusFlashEnabled, true)
    }

    // MARK: - 差分検知 (連打抑制)

    /// previous == current の分岐 (トグル変化なし) では副作用が発火しない。ColorPicker で色だけ変えた
    /// ような「機能トグル不変 / 表示パラメータのみ変化」の apply で、tap を余分に stop/start しないこと。
    /// 表示パラメータ側 (applyDisplayParametersToAllViewModels) と updateMenuStates は毎回発火する。
    func testUnchangedTogglesDoNotRefireSideEffects() {
        let rec = Recorder()
        let effects = makeEffects(rec)
        var next = DisplaySettings.defaults
        next.laserColorNear = RGBAColor.parseHex("#112233FF")!  // 色だけ変える

        applySettingsCore(previous: .defaults, current: next, effects: effects)

        XCTAssertEqual(rec.warpCalls, [], "warp 不変 → setWarpEnabled 発火せず")
        XCTAssertEqual(rec.presentationCalls, [], "presentation 不変 → applyPresentationMode 発火せず")
        XCTAssertEqual(rec.focusFlashCalls, [], "focusFlash 不変 → applyFocusFlash 発火せず")
        XCTAssertEqual(rec.menuUpdateCalls.count, 1, "menu 更新は毎回同期 (差分検知しない = idempotent)")
        XCTAssertEqual(rec.applyDisplayParamCalls.count, 1, "表示パラメータは毎回全 VM に再適用 (M-1 下敷き)")
    }

    // MARK: - 新値で分岐 (C-1 willSet stale read 回帰防止)

    /// previous=(warp=false) → current=(warp=true) の遷移で setWarpEnabled(true) が呼ばれる
    /// (逆方向は呼ばれない)。willSet stale read の回帰があれば「新値と反対の boolean」が渡る
    /// はずなので、fitness function として引数値を assert する。
    func testWarpToggleForwardsNewValueToSideEffect() {
        let rec = Recorder()
        let effects = makeEffects(rec)
        var prev = DisplaySettings.defaults
        prev.warpEnabled = false
        var curr = DisplaySettings.defaults
        curr.warpEnabled = true

        applySettingsCore(previous: prev, current: curr, effects: effects)

        XCTAssertEqual(rec.warpCalls, [true],
                       "遷移 false→true で setWarpEnabled(true) が 1 回。willSet stale read があると false が渡ってしまう")
    }

    /// focusFlashEnabled の遷移も同じく新値を受ける (C-1 の完全なフィットネス関数、
    /// 旧実装で bug が最も顕在化したフィールド)。
    func testFocusFlashToggleForwardsNewSettingsToSideEffect() {
        let rec = Recorder()
        let effects = makeEffects(rec)
        var prev = DisplaySettings.defaults
        prev.focusFlashEnabled = false
        var curr = DisplaySettings.defaults
        curr.focusFlashEnabled = true

        applySettingsCore(previous: prev, current: curr, effects: effects)

        XCTAssertEqual(rec.focusFlashCalls.count, 1)
        XCTAssertEqual(rec.focusFlashCalls[0].focusFlashEnabled, true,
                       "副作用が受け取った settings は current (= 新値)。stale read があると false が届く")
    }

    // MARK: - rebuild 経路の再適用シミュレーション (M-1)

    /// rebuildOverlays は新規 VM を作るため、その直後に SettingsStore の表示パラメータを再適用する必要が
    /// ある (旧実装は applyPresentationMode() だけを呼び、色 / 太さがデフォルトへ巻き戻るバグを内包していた)。
    /// AppDelegate.rebuildOverlays 内で `for vm in overlays { settings.applyDisplayParameters(to: vm) }` を
    /// 呼ぶことは AppDelegate 側の直接テストは重いため、ここでは「applyDisplayParameters(to:) 単体が
    /// 全フィールドを VM に反映する」ことを固定し、rebuild で同じ関数を再利用できることを担保する。
    func testApplyDisplayParametersIsIdempotentAndUsableForRebuildPath() {
        let display = Display(id: "A",
                              logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100),
                              pose: .identity)
        let state = AppState.initial(displays: [display])
        let vm = OverlayViewModel(initialState: state)

        var settings = DisplaySettings.defaults
        settings.laserCornerHalfWidth = 21
        settings.waveBandMM = 42
        settings.laserColorNear = RGBAColor.parseHex("#01020304")!

        // rebuild 直後の new VM は defaults のまま。1 回目 apply でストア値へ揃う。
        settings.applyDisplayParameters(to: vm)
        XCTAssertEqual(vm.laserCornerHalfWidth, 21)
        XCTAssertEqual(vm.waveBandMM, 42)
        XCTAssertEqual(vm.laserColorNear, settings.laserColorNear)

        // 2 回目 apply (= 続けて rebuild したケース) でも同じ値。idempotent。
        settings.applyDisplayParameters(to: vm)
        XCTAssertEqual(vm.laserCornerHalfWidth, 21)
        XCTAssertEqual(vm.waveBandMM, 42)
    }
}
