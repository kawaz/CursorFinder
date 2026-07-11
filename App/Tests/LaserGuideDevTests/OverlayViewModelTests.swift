// OverlayViewModel の coalesce (60Hz 合流) テスト (2026-07-10 第 2 ラウンド フィードバック #5)
//
// tap 経由 (apply(state:)) / drag monitor 経由 (apply(mouseLocation:)) はどちらも高頻度
// (OS のイベントレポートレートに比例) に呼ばれうる。毎回 @Published を即時発火すると SwiftUI の
// 再評価コストがイベントレートに比例して積み重なる (kawaz 実機報告: レーザー非表示中でも
// ドラッグが重かった)。ここでは「呼んだ瞬間には反映されず、flushInterval 後の coalesce
// タイマーでまとめて反映される」「1 interval 内の複数回呼び出しは最後の値だけが残る」
// ことを固定する。
import XCTest
@testable import LaserGuideDev
import LaserGuideCore

final class OverlayViewModelTests: XCTestCase {

    private func makeState(mouse: LogicalPoint?, displayId: String = "A") -> AppState {
        let display = Display(id: displayId, logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity)
        var state = AppState.initial(displays: [display])
        if let mouse {
            state.previousMouse = MouseHistoryEntry(point: mouse, displayId: displayId)
            state.currentMouse = MouseHistoryEntry(point: mouse, displayId: displayId)
        }
        return state
    }

    /// リーディングエッジ (第 3 ラウンド裁定「即値で使う一択」): 前回反映から flushInterval 以上
    /// 空いた入力 (ここでは VM 生成後の最初の入力) は、タイマーを待たず**その場で反映**される。
    /// 静止→動き出しの初動に人工遅延を足さないことの固定。
    func testFirstMouseLocationAppliesImmediatelyOnLeadingEdge() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02

        vm.laserShowDebounce = 0  // 表示デバウンスは別テストで検証、ここではスロットルに集中

        vm.apply(mouseLocation: LogicalPoint(x: 100, y: 100))
        XCTAssertEqual(vm.currentMouseLocation, LogicalPoint(x: 100, y: 100), "初回入力は即時反映")
        XCTAssertEqual(vm.laserOpacity, 1, "位置が変わったので即表示になる (デバウンス 0)")
    }

    /// トレーリングエッジ (スロットル本体): 直前の反映から interval 内に続く入力は即時反映されず、
    /// 最新値だけが interval 経過後の 1 回の flush でまとめて反映される (中間値は捨てる、
    /// キューに積まない = 高頻度呼び出しでも @Published 発火はレート上限を超えない)。
    func testRapidMouseLocationUpdatesWithinOneIntervalCollapseToLatestValue() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.05

        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))   // リーディングエッジで即時反映
        vm.apply(mouseLocation: LogicalPoint(x: 2, y: 2))   // interval 内 → pending (捨てられる)
        vm.apply(mouseLocation: LogicalPoint(x: 3, y: 3))   // interval 内 → pending を上書き
        XCTAssertEqual(vm.currentMouseLocation, LogicalPoint(x: 1, y: 1),
                       "interval 内の後続入力は即時反映されない (最初の値のまま)")

        let exp = expectation(description: "flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(vm.currentMouseLocation, LogicalPoint(x: 3, y: 3),
                       "トレーリング flush で反映されるのは最後の値のみ (中間値 (2,2) は捨てられる)")
    }

    /// apply(state:) も同じスロットルに乗る (tap 経由の高頻度更新も同じ経路を通ることの固定)。
    /// リーディングエッジで初回は即時、interval 内の後続 state は最新だけが trailing 反映。
    func testApplyStateIsThrottledAndActivatesOnPositionChange() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02
        vm.laserShowDebounce = 0  // 表示デバウンスは別テストで検証、ここではスロットルに集中

        let moved = makeState(mouse: LogicalPoint(x: 500, y: 500))
        vm.apply(state: moved)
        XCTAssertEqual(vm.currentMouseLocation, LogicalPoint(x: 500, y: 500), "初回 state は即時反映")
        XCTAssertEqual(vm.laserOpacity, 1, "位置が変わったので即表示になる (デバウンス 0)")
        XCTAssertEqual(vm.state.currentMouse?.point, LogicalPoint(x: 500, y: 500))

        // interval 内の後続 state は即時反映されず、trailing でまとめて反映される
        let moved2 = makeState(mouse: LogicalPoint(x: 600, y: 600))
        vm.apply(state: moved2)
        XCTAssertEqual(vm.currentMouseLocation, LogicalPoint(x: 500, y: 500), "interval 内は未反映")

        let exp = expectation(description: "flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(vm.currentMouseLocation, LogicalPoint(x: 600, y: 600), "trailing flush で最新 state が反映")
    }

    /// state 更新のうちマウス位置が変化しないもの (displayConfigurationChanged 等) は、
    /// flush 後もレーザーを勝手に表示側へ倒さない (無関係な state 変化で
    /// アイドルフェードが再表示側にリセットされてしまう回帰を防ぐ)。
    func testApplyStateWithUnchangedMouseLocationDoesNotReactivate() {
        let initial = makeState(mouse: LogicalPoint(x: 10, y: 10))
        let vm = OverlayViewModel(initialState: initial, initialMouse: LogicalPoint(x: 10, y: 10))
        vm.flushInterval = 0.02
        vm.laserShowDebounce = 0
        XCTAssertEqual(vm.laserOpacity, 0, "初期状態は非表示")

        // 同じマウス位置のまま state だけ更新 (例: displayConfigurationChanged 相当)
        vm.apply(state: initial)

        let exp = expectation(description: "flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(vm.laserOpacity, 0, "マウス位置が変わっていないので表示されない")
    }

    // MARK: - レーザー表示デバウンス + フェードアウト (2026-07-11 第 4 ラウンド)

    /// 表示デバウンス: 単発の微小移動 (継続時間 < laserShowDebounce) ではレーザーを表示しない
    /// (タッチパッドに触れただけで出るのを防ぐ)。位置の追跡 (currentMouseLocation) 自体は行う。
    func testBriefMovementDoesNotShowLaser() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.005
        vm.laserShowDebounce = 0.2

        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))
        XCTAssertEqual(vm.laserOpacity, 0, "デバウンス未満の移動では表示しない")
        XCTAssertEqual(vm.currentMouseLocation, LogicalPoint(x: 1, y: 1), "位置追跡はデバウンスと無関係に行う")
    }

    /// 表示デバウンス: 連続移動が laserShowDebounce を超えて継続したら表示する。
    func testSustainedMovementShowsLaserAfterDebounce() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.005
        vm.laserShowDebounce = 0.05
        vm.inactivityThreshold = 0.5  // 継続移動の途中で「停止」扱いにならないよう長めに

        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))
        XCTAssertEqual(vm.laserOpacity, 0, "開始直後はまだ表示しない")

        // デバウンス時間を跨いで移動を継続する
        let exp = expectation(description: "sustain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        vm.apply(mouseLocation: LogicalPoint(x: 2, y: 2))

        XCTAssertEqual(vm.laserOpacity, 1, "デバウンスを超えて移動が継続したら表示")
    }

    /// 移動停止で連続移動の起点はリセットされる: 「触る → 止まる → また触る」のような
    /// 断続的な移動は、各回がデバウンス未満なら何度繰り返しても表示されない。
    func testIntermittentBriefMovementsNeverShowLaser() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.005
        vm.laserShowDebounce = 0.3
        vm.inactivityThreshold = 0.03  // すぐ「停止」扱いになるよう短めに

        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))
        // 停止判定 (inactivityThreshold) を跨いでから次の単発移動
        let exp = expectation(description: "gap")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        vm.apply(mouseLocation: LogicalPoint(x: 2, y: 2))

        XCTAssertEqual(vm.laserOpacity, 0,
                       "起点がリセットされるため、断続的な単発移動の合算でデバウンスを超えても表示されない")
    }

    /// フェードアウト: 移動停止から inactivityThreshold 後、即消しではなく laserFadeOutDuration
    /// かけて opacity が段階的に 0 へ減衰する (「スーッと消える」の固定)。
    func testLaserFadesOutGraduallyAfterInactivity() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.005
        vm.laserShowDebounce = 0
        vm.inactivityThreshold = 0.05
        vm.laserFadeOutDuration = 0.3

        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))
        XCTAssertEqual(vm.laserOpacity, 1)

        // 停止 → フェード中間点: 0 と 1 の間の値 (即消しでも維持でもない)
        let mid = expectation(description: "mid-fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { mid.fulfill() }
        wait(for: [mid], timeout: 1.0)
        XCTAssertGreaterThan(vm.laserOpacity, 0, "フェード途中で 0 に落ちていない (即消しではない)")
        XCTAssertLessThan(vm.laserOpacity, 1, "フェードが始まっている (維持でもない)")

        // フェード完了: opacity 0
        let done = expectation(description: "fade-done")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 1.0)
        XCTAssertEqual(vm.laserOpacity, 0, "laserFadeOutDuration 経過で完全に消える")
    }

    /// フェード中の移動再開は即フル輝度に復帰する (直前まで見えていたレーザーの継続なので
    /// 表示デバウンスは課さない)。
    func testMovementDuringFadeRestoresFullOpacityImmediately() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.005
        vm.laserShowDebounce = 10  // 復帰にデバウンスが誤適用されたら即検出できる大きい値
        vm.inactivityThreshold = 0.05
        vm.laserFadeOutDuration = 0.5

        // 表示状態を作る (デバウンスを回避するため一時的に 0 で点灯させる)
        vm.laserShowDebounce = 0
        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))
        XCTAssertEqual(vm.laserOpacity, 1)
        vm.laserShowDebounce = 10

        // フェード中間まで待つ
        let mid = expectation(description: "mid-fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { mid.fulfill() }
        wait(for: [mid], timeout: 1.0)
        XCTAssertLessThan(vm.laserOpacity, 1, "前提: フェードが進行中")
        XCTAssertGreaterThan(vm.laserOpacity, 0, "前提: まだ消えていない")

        vm.apply(mouseLocation: LogicalPoint(x: 2, y: 2))
        XCTAssertEqual(vm.laserOpacity, 1, "フェード中の移動再開はデバウンス無しで即フル復帰")
    }

    // MARK: - プレゼンテーションモード (issue: presentation-mode-capture-toggle)

    /// mouseDown 相当を apply(presentationClick:) で流すと、即座に clickCircle が
    /// initial opacity で表示される (coalesce タイマーは経由しない = 描画 latency を最小化)。
    func testPresentationClickDownShowsCircleImmediately() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.clickInitialOpacity = 0.6
        XCTAssertNil(vm.clickCircle)
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .down, point: LogicalPoint(x: 100, y: 200)))
        XCTAssertNotNil(vm.clickCircle)
        XCTAssertEqual(vm.clickCircle?.point, LogicalPoint(x: 100, y: 200))
        XCTAssertEqual(vm.clickCircle?.opacity, 0.6)
    }

    /// mouseUp 相当で opacity が段階的に減衰し、clickFadeDuration 経過後に nil に戻る。
    func testPresentationClickUpFadesOutAndClears() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.clickInitialOpacity = 0.6
        vm.clickFadeDuration = 0.12  // テスト時間短縮
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .down, point: LogicalPoint(x: 10, y: 20)))
        XCTAssertEqual(vm.clickCircle?.opacity, 0.6)

        vm.apply(presentationClick: PresentationClickEvent(
            phase: .up, point: LogicalPoint(x: 10, y: 20)))
        // 直後は減衰中 (まだ opacity > 0)
        XCTAssertNotNil(vm.clickCircle)

        let exp = expectation(description: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertNil(vm.clickCircle, "clickFadeDuration 経過後に clickCircle=nil に戻る")
    }

    /// 2026-07-10 第 2 ラウンド #2 + 第 3 ラウンド裁定: down 後の drag はサークルの point だけを
    /// 更新し opacity は変えない (= ボタンを押している間カーソルに追従し続ける)。drag は OS の
    /// イベントレポートレートで高頻度に届くため state/mouseLocation と同じスロットルに合流する:
    /// リーディングエッジで最初の drag は即時、interval 内の後続は最新値だけが trailing 反映
    /// (中間値は捨てる)。
    func testPresentationClickDragUpdatesPointViaThrottleWhileKeepingOpacity() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02
        vm.clickInitialOpacity = 0.6
        // down はスロットルを経由しない直接代入 (表示開始のレイテンシを最小化)
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .down, point: LogicalPoint(x: 10, y: 20)))
        XCTAssertEqual(vm.clickCircle?.point, LogicalPoint(x: 10, y: 20))
        XCTAssertEqual(vm.clickCircle?.opacity, 0.6)

        // 最初の drag はリーディングエッジで即時反映
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .drag, point: LogicalPoint(x: 300, y: 400)))
        XCTAssertEqual(vm.clickCircle?.point, LogicalPoint(x: 300, y: 400), "初回 drag は即時反映")

        // interval 内の後続 drag は pending 上書きのみ → trailing flush で最後の値が反映
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .drag, point: LogicalPoint(x: 500, y: 600)))
        XCTAssertEqual(vm.clickCircle?.point, LogicalPoint(x: 300, y: 400), "interval 内は未反映")

        let exp = expectation(description: "flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(vm.clickCircle?.point, LogicalPoint(x: 500, y: 600), "trailing flush で最後の drag 位置が反映")
        XCTAssertEqual(vm.clickCircle?.opacity, 0.6, "drag では opacity が変わらない")
    }

    /// up 後 (= clickCircle が nil に戻った後) に drag が来ても無視される
    /// (= down を経ていないドラッグまでサークルを復活させない)。
    func testPresentationClickDragAfterUpIsIgnored() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.clickInitialOpacity = 0.6
        vm.clickFadeDuration = 0.06  // テスト時間短縮
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .down, point: LogicalPoint(x: 0, y: 0)))
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .up, point: LogicalPoint(x: 0, y: 0)))

        let exp = expectation(description: "fade complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertNil(vm.clickCircle, "前提: fade 完了で nil")

        vm.apply(presentationClick: PresentationClickEvent(
            phase: .drag, point: LogicalPoint(x: 999, y: 999)))
        XCTAssertNil(vm.clickCircle, "down を経ていない drag はサークルを復活させない")
    }

    /// down → drag → up の順で、up 後の減衰は最後の drag 位置から始まる
    /// (= 離した位置にジャンプせず、ドラッグ追従の到達点から消える)。
    func testPresentationClickUpAfterDragFadesFromLastDragPosition() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.clickInitialOpacity = 0.6
        vm.clickFadeDuration = 0.5  // fade 完了前に up 直後の point を確認できるよう長めに
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .down, point: LogicalPoint(x: 0, y: 0)))
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .drag, point: LogicalPoint(x: 100, y: 100)))
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .up, point: LogicalPoint(x: 100, y: 100)))
        // up 直後 (減衰タイマーの初回 tick 前): point は最後の drag 位置のまま
        XCTAssertEqual(vm.clickCircle?.point, LogicalPoint(x: 100, y: 100), "up は最後の drag 位置で減衰開始")
    }

    /// クリック中 (down 直後) に clearPresentationClick() が呼ばれると即座にサークルが消える
    /// (= プレゼンテーションモード off 遷移で減衰を待たず消す振る舞いの固定)。
    func testClearPresentationClickRemovesCircleImmediately() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.apply(presentationClick: PresentationClickEvent(
            phase: .down, point: LogicalPoint(x: 0, y: 0)))
        XCTAssertNotNil(vm.clickCircle)
        vm.clearPresentationClick()
        XCTAssertNil(vm.clickCircle)
    }

    // MARK: - フォーカスフラッシュ (DR-0009 Phase A)

    /// state.focusFlash が nil→非 nil に遷移すると、スロットル経由でも focusFlash が initial
    /// opacity で立ち上がる (= applyStateImmediately が generation 変化を検知して startFocusFlash
    /// を呼ぶ)。初回 state はリーディングエッジで即時反映される。
    func testFocusFlashRisesOnStateFocusChange() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02
        vm.focusFlashInitialOpacity = 0.6
        vm.focusFlashDuration = 1.0  // 直後の消滅を防ぐため長めに

        var next = makeState(mouse: nil)
        next.focusFlash = FocusFlashState(displayId: "A", generation: 1)
        vm.apply(state: next)

        XCTAssertNotNil(vm.focusFlash, "初回 state はリーディングエッジで即時立ち上がる")
        XCTAssertEqual(vm.focusFlash?.displayId, "A")
        // Timer 減衰は非同期なので上限で確認 (立ち上がり直後は initial に近い)
        XCTAssertGreaterThan(vm.focusFlash?.opacity ?? -1, 0.3)
    }

    /// 同じ displayId でも state.focusFlash.generation が進めば opacity が新規発火扱いでリセットされる
    /// (= 同一モニタ内のアプリ切替でも再発火する DR-0009 決定 2 の輪郭)。
    func testFocusFlashRefiresOnSameDisplayWhenGenerationIncrements() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02
        vm.focusFlashInitialOpacity = 0.6
        vm.focusFlashDuration = 2.0  // 減衰完了前に再発火させる

        var s1 = makeState(mouse: nil)
        s1.focusFlash = FocusFlashState(displayId: "A", generation: 1)
        vm.apply(state: s1)

        let exp1 = expectation(description: "first")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        // 少し減衰してから同じ displayId で generation++
        let opacityAfterFirst = vm.focusFlash?.opacity ?? 0

        var s2 = makeState(mouse: nil)
        s2.focusFlash = FocusFlashState(displayId: "A", generation: 2)
        vm.apply(state: s2)

        let exp2 = expectation(description: "second")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)

        XCTAssertNotNil(vm.focusFlash, "再発火で復活")
        // 再発火後の opacity は 1 回目の減衰値より上 (initial 付近まで戻る)
        XCTAssertGreaterThan(vm.focusFlash?.opacity ?? -1, opacityAfterFirst,
                             "generation が進めば opacity が initial 付近にリセットされる")
    }

    /// clearFocusFlash() で減衰中でも即座に nil、かつ lastFocusFlashGeneration が state.focusFlash
    /// に synchronize される (= off 中の発火を「見なかった」ものとして次回 on 時に再生しない)。
    func testClearFocusFlashRemovesImmediatelyAndSyncsGeneration() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02
        vm.focusFlashDuration = 2.0

        var s1 = makeState(mouse: nil)
        s1.focusFlash = FocusFlashState(displayId: "A", generation: 1)
        vm.apply(state: s1)

        let exp1 = expectation(description: "rise")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)
        XCTAssertNotNil(vm.focusFlash)

        vm.clearFocusFlash()
        XCTAssertNil(vm.focusFlash, "clearFocusFlash で即座に消える")

        // 同じ generation (=1) の state をもう一度流しても再生しない (見なかったとして扱う)
        vm.apply(state: s1)
        let exp2 = expectation(description: "no-refire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)
        XCTAssertNil(vm.focusFlash, "同じ generation で再発火しない")
    }
}
