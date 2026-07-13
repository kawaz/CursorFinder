// OverlayViewModel の coalesce (60Hz 合流) テスト (2026-07-10 第 2 ラウンド フィードバック #5)
//
// tap 経由 (apply(state:)) / drag monitor 経由 (apply(mouseLocation:)) はどちらも高頻度
// (OS のイベントレポートレートに比例) に呼ばれうる。毎回 @Published を即時発火すると SwiftUI の
// 再評価コストがイベントレートに比例して積み重なる (kawaz 実機報告: レーザー非表示中でも
// ドラッグが重かった)。ここでは「呼んだ瞬間には反映されず、flushInterval 後の coalesce
// タイマーでまとめて反映される」「1 interval 内の複数回呼び出しは最後の値だけが残る」
// ことを固定する。
import XCTest
import Combine
import CoreGraphics
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

    /// main run loop を回しながら条件成立を待つ。タイマー減衰 (fade) 系の検証は
    /// 「この壁時計時刻には完了しているはず」を assert すると共有 CI runner の負荷で
    /// Timer 発火が遅延した時に破綻する (2026-07-11 の main CI 初回実走行で実際に発生)。
    /// 検証の意図は「最終的にその状態へ到達する」ことなので、到達を待って assert する。
    /// timeout は「遅い runner でも確実に足りる」側に倒す (到達すれば即 return するので
    /// 速い環境でテストが遅くなることはない)。
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
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

        XCTAssertTrue(waitUntil { vm.currentMouseLocation == LogicalPoint(x: 3, y: 3) },
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

        XCTAssertTrue(waitUntil { vm.currentMouseLocation == LogicalPoint(x: 600, y: 600) },
                      "trailing flush で最新 state が反映")
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

        // 負の検証 (「表示されない」) は到達待ちができないので、flush が確実に済む猶予だけ回す
        waitUntil(timeout: 0.1) { false }
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
        vm.inactivityThreshold = 10  // 遅い CI runner の待機中に「停止」扱いへ落ちないよう実質無効化

        let start = ProcessInfo.processInfo.systemUptime
        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))
        XCTAssertEqual(vm.laserOpacity, 0, "開始直後はまだ表示しない")

        // デバウンス時間を確実に跨いでから移動を継続する (壁時計固定でなく経過時間で判定)
        XCTAssertTrue(waitUntil { ProcessInfo.processInfo.systemUptime - start >= 0.06 })
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
        // 停止判定 (inactivityThreshold=0.03) を確実に跨ぐ猶予を回してから次の単発移動。
        // gap (0.5s) > デバウンス (0.3s) にしてあるため、もし起点リセットが壊れていたら
        // 「経過時間の合算でデバウンス超え → 表示」となり、この test が検出する。
        waitUntil(timeout: 0.5) { false }
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

        // 「段階的に減衰する」の検証は壁時計時刻でのサンプリングだと遅い CI runner で
        // 破綻する (2026-07-11 main CI 初回実走行で発生) ため、@Published の全遷移を
        // 記録して「最終的に 0 へ到達」+「中間値を経由した」の 2 点で固定する。
        var observed: [Double] = []
        let sub = vm.$laserOpacity.sink { observed.append($0) }
        defer { sub.cancel() }

        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))
        XCTAssertEqual(vm.laserOpacity, 1)

        XCTAssertTrue(waitUntil { vm.laserOpacity == 0 }, "停止後、最終的に完全に消える")
        XCTAssertTrue(observed.contains { $0 > 0 && $0 < 1 },
                      "0 と 1 の中間値を経由して減衰している (即消しではない)")
    }

    /// フェード中の移動再開は即フル輝度に復帰する (直前まで見えていたレーザーの継続なので
    /// 表示デバウンスは課さない)。
    func testMovementDuringFadeRestoresFullOpacityImmediately() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.005
        vm.inactivityThreshold = 0.05
        // フェードを十分長くし、遅い CI runner でも「フェード開始〜介入」の間に 0 まで
        // 落ち切らないようにする (fade 開始の検知は waitUntil で行い、壁時計に依存しない)
        vm.laserFadeOutDuration = 5

        // 表示状態を作る (デバウンスを回避するため一時的に 0 で点灯させる)
        vm.laserShowDebounce = 0
        vm.apply(mouseLocation: LogicalPoint(x: 1, y: 1))
        XCTAssertEqual(vm.laserOpacity, 1)
        vm.laserShowDebounce = 10  // 復帰にデバウンスが誤適用されたら即検出できる大きい値

        XCTAssertTrue(waitUntil { vm.laserOpacity < 1 }, "前提: フェードが進行中")
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

        XCTAssertTrue(waitUntil { vm.clickCircle == nil },
                      "clickFadeDuration 経過後に clickCircle=nil に戻る")
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

        XCTAssertTrue(waitUntil { vm.clickCircle?.point == LogicalPoint(x: 500, y: 600) },
                      "trailing flush で最後の drag 位置が反映")
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

        XCTAssertTrue(waitUntil { vm.clickCircle == nil }, "前提: fade 完了で nil")

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
        next.focusFlash = FocusFlashState(
            displayId: "A", windowFrame: LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100), generation: 1)
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
        s1.focusFlash = FocusFlashState(
            displayId: "A", windowFrame: LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100), generation: 1)
        vm.apply(state: s1)

        // 1 回目の減衰がはっきり進むまで待つ (0.45 未満 = initial 0.6 から複数 tick 分減衰。
        // 再発火直後との比較マージンを確保し、遅い runner での際どい大小比較を避ける)
        XCTAssertTrue(waitUntil { (vm.focusFlash?.opacity ?? 1) < 0.45 }, "前提: 1 回目の減衰が進む")
        let opacityAfterFirst = vm.focusFlash?.opacity ?? 0

        var s2 = makeState(mouse: nil)
        s2.focusFlash = FocusFlashState(
            displayId: "A", windowFrame: LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100), generation: 2)
        vm.apply(state: s2)

        // 前回 flush から 0.45s 以上経過しているのでリーディングエッジで即時反映される
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
        s1.focusFlash = FocusFlashState(
            displayId: "A", windowFrame: LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100), generation: 1)
        vm.apply(state: s1)  // 初回 state はリーディングエッジで即時反映
        XCTAssertNotNil(vm.focusFlash)

        vm.clearFocusFlash()
        XCTAssertNil(vm.focusFlash, "clearFocusFlash で即座に消える")

        // 同じ generation (=1) の state をもう一度流しても再生しない (見なかったとして扱う)。
        // 負の検証なので、trailing flush が確実に済む猶予だけ回してから assert する
        vm.apply(state: s1)
        waitUntil(timeout: 0.1) { false }
        XCTAssertNil(vm.focusFlash, "同じ generation で再発火しない")
    }

    // MARK: - フォーカス波動 (DR-0011)

    /// state.focusFlash の generation 変化 (nil→非 nil) で wave が立ち上がり、mm 空間の震源が
    /// windowFrame から正しく写像され、進行に伴い radiusMM が単調増加し、waveDuration 経過後に
    /// nil へ遷移する (= startWave のライフサイクル一巡の固定)。
    func testWaveRisesOnFocusChangeRadiusMonotonicallyIncreasesThenClears() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02
        vm.waveDuration = 0.3  // テスト時間短縮
        vm.waveInitialOpacity = 0.5

        let windowFrame = LogicalRect(minX: 100, minY: 100, maxX: 300, maxY: 300)
        var next = makeState(mouse: nil)
        next.focusFlash = FocusFlashState(displayId: "A", windowFrame: windowFrame, generation: 1)
        vm.apply(state: next)

        XCTAssertNotNil(vm.wave, "初回 state はリーディングエッジで即時立ち上がる")
        // makeState の display は DisplayPose.identity (translate=(0,0), scale=1) の単一 display 構成。
        // WaveLayout.placements は anchor (= 論理 (0,0) を含むこの display) の mmRect.min を (0,0) に
        // 置くため、mm 空間は論理 px 空間と恒等写像になり、震源 mmRect は windowFrame とビット一致する
        // (WavePlacement.toMM: mmRect.minX + (p.x - logicalBounds.minX) * scaleX = 0 + p.x * 1)。
        XCTAssertEqual(vm.wave?.epicenterMM, PhysicalRect(minX: 100, minY: 100, maxX: 300, maxY: 300))
        XCTAssertEqual(vm.wavePlacements.first?.displayId, "A",
                       "発火時に隣接物理レイアウトのスナップショットが wavePlacements に固定される")

        // radiusMM は progress=p*(maxDistanceMM+bandMM) で単調増加する (WaveGeometry.radiusMM)。
        // @Published の全遷移を記録して非減少性を確認する (壁時計固定サンプリングは CI 共有 runner の
        // Timer 遅延で破綻した実績があるため禁則、ファイル冒頭 waitUntil コメント参照)。
        var observedRadii: [Double] = []
        let sub = vm.$wave.sink { presentation in
            if let r = presentation?.radiusMM { observedRadii.append(r) }
        }
        defer { sub.cancel() }

        XCTAssertTrue(waitUntil { vm.wave == nil }, "waveDuration 経過後に消滅する")
        XCTAssertGreaterThanOrEqual(observedRadii.count, 2, "複数回の tick で radiusMM が記録されている")
        for i in 1..<observedRadii.count {
            XCTAssertGreaterThanOrEqual(observedRadii[i], observedRadii[i - 1], "radiusMM は単調増加(非減少)")
        }
    }

    /// 同じ displayId でも state.focusFlash.generation が進めば、進行中の波が古いタイマーごと
    /// 破棄され、新しい windowFrame を震源とする波に置き換わる (focusFlash 側の再発火と対称の輪郭、
    /// DR-0011 決定 4 のウィンドウ単位フォーカス観測が連続発火しても震源が正しく更新されることの固定)。
    func testWaveRefiresWithNewEpicenterOnGenerationIncrement() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02
        vm.waveDuration = 2.0  // 減衰完了前に再発火させる

        let frame1 = LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        var s1 = makeState(mouse: nil)
        s1.focusFlash = FocusFlashState(displayId: "A", windowFrame: frame1, generation: 1)
        vm.apply(state: s1)
        XCTAssertEqual(vm.wave?.epicenterMM, PhysicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100))

        XCTAssertTrue(waitUntil { (vm.wave?.radiusMM ?? 0) > 0 }, "前提: 1 回目の波が進行中 (radiusMM > 0)")

        let frame2 = LogicalRect(minX: 500, minY: 500, maxX: 700, maxY: 700)
        var s2 = makeState(mouse: nil)
        s2.focusFlash = FocusFlashState(displayId: "A", windowFrame: frame2, generation: 2)
        vm.apply(state: s2)

        XCTAssertNotNil(vm.wave, "再発火で復活")
        XCTAssertEqual(vm.wave?.epicenterMM, PhysicalRect(minX: 500, minY: 500, maxX: 700, maxY: 700),
                       "generation が進めば古いタイマーは破棄され、新しい震源の波に置き換わる")
    }

    /// clearFocusFlash() で focusFlash と併せて wave も即座に nil へ戻る
    /// (DR-0011 決定 5: 波動とウィンドウ枠フラッシュは併存するライフサイクルなので off 遷移も対称)。
    func testClearFocusFlashRemovesWaveImmediately() {
        let vm = OverlayViewModel(initialState: makeState(mouse: nil))
        vm.flushInterval = 0.02
        vm.waveDuration = 2.0

        var s1 = makeState(mouse: nil)
        s1.focusFlash = FocusFlashState(
            displayId: "A", windowFrame: LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100), generation: 1)
        vm.apply(state: s1)
        XCTAssertNotNil(vm.wave, "前提: 波が発火している")

        vm.clearFocusFlash()
        XCTAssertNil(vm.wave, "clearFocusFlash で wave も即座に消える")
    }

    // MARK: - waveMMToLocalTransform (M-2: 描画用 transform と WavePlacement.localPx の同一性)

    /// `waveMMToLocalTransform` (LaserOverlayView.waveView がインラインで組んでいた
    /// CGAffineTransform を切り出した App 層純関数) を複数の mm 点に適用した結果が、
    /// Core でテスト済みの `WavePlacement.localPx(fromMM:)` と一致することを固定する。
    /// これにより「描画用 transform が Core の写像と食い違う」回帰を検出できる。
    /// 異方 scale (scaleX ≠ scaleY) の fixture を含めることで、軸別スケールの取り違え
    /// (例: scaleX と scaleY を逆に使う) も検出できるようにする。
    func testWaveMMToLocalTransformMatchesWavePlacementLocalPx() {
        // 異方 scale (縦横で mm/px 比が異なる、実機の混合 DPI を模した fixture)。
        let placement = WavePlacement(
            displayId: "A",
            logicalBounds: LogicalRect(minX: 100, minY: 50, maxX: 1100, maxY: 850),
            scaleX: 0.2, scaleY: 0.25,
            mmRect: PhysicalRect(minX: -40, minY: 30, maxX: 160, maxY: 230))

        let transform = waveMMToLocalTransform(placement)

        // サンプル mm 点: mmRect.min (= local (0,0) になるはず)、mmRect 内部の任意点、
        // mmRect 外部 (波のリングは震源より外側へ広がるため mmRect の外まで転写されうる) の 3 点。
        let samples = [
            PhysicalPoint(x: placement.mmRect.minX, y: placement.mmRect.minY),
            PhysicalPoint(x: 10, y: 100),
            PhysicalPoint(x: -100, y: 500)
        ]
        for mm in samples {
            let expected = placement.localPx(fromMM: mm)
            let actual = CGPoint(x: CGFloat(mm.x), y: CGFloat(mm.y)).applying(transform)
            XCTAssertEqual(Double(actual.x), expected.x, accuracy: 1e-9,
                            "mm=\(mm) の transform 結果 x が WavePlacement.localPx と一致しない")
            XCTAssertEqual(Double(actual.y), expected.y, accuracy: 1e-9,
                            "mm=\(mm) の transform 結果 y が WavePlacement.localPx と一致しない")
        }
    }
}
