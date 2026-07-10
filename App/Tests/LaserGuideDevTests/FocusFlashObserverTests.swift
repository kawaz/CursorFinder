// FocusFlashObserver — 所属モニタ解決の純関数部分 (`resolveFocusDisplay`) のテスト。
//
// AX / NSWorkspace 経路は実機依存なので unit test では覆えない (Phase A 実機確認事項)。
// ここで固定するのは「AX から取れた窓 frame と現在の displays から displayId を選ぶ」ロジックのみ:
//
//   (1) ウィンドウ中心が包含される display があればその id を返す (通常経路)
//   (2) どの display にも含まれない場合は中心点との L2 距離最小の display にフォールバック
//       (フルスクリーン化直後 / 複数モニタ境界跨ぎのウィンドウで発火が空振りしないため)
//   (3) displays が空なら nil (呼び出し側で発火をスキップさせる契約)
import XCTest
@testable import LaserGuideDev
import LaserGuideCore

final class FocusFlashObserverTests: XCTestCase {

    private func makeDisplays() -> [Display] {
        return [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
    }

    /// (1) ウィンドウ中心が display "A" の矩形に包含されれば "A" を返す。
    func testResolveReturnsContainingDisplayWhenWindowCenterIsInsideIt() {
        let displays = makeDisplays()
        // 中心 (400, 400) は A の内部
        let frame = LogicalRect(minX: 100, minY: 100, maxX: 700, maxY: 700)
        let r = resolveFocusDisplay(windowFrame: frame, displays: displays)
        XCTAssertEqual(r?.displayId, "A")
        XCTAssertEqual(r?.windowCenter, LogicalPoint(x: 400, y: 400))
    }

    /// (1') 隣モニタ B に中心があれば "B" を返す。境界を跨ぐ形の frame でも中心が判定基準。
    func testResolvePicksAdjacentDisplayWhenCenterIsInsideIt() {
        let displays = makeDisplays()
        // A/B の継ぎ目 x=1920 を跨ぐが、中心 (2000, 500) は B 側
        let frame = LogicalRect(minX: 1800, minY: 100, maxX: 2200, maxY: 900)
        let r = resolveFocusDisplay(windowFrame: frame, displays: displays)
        XCTAssertEqual(r?.displayId, "B")
    }

    /// (2) どの display にも含まれない中心座標なら距離最小の display にフォールバック。
    ///     フルスクリーン中や画面外に飛んだ window でも発火が空振りしない挙動を担保する。
    func testResolveFallsBackToNearestDisplayWhenCenterOutsideAll() {
        let displays = makeDisplays()
        // 全モニタの上方 (y<0) にある frame — どちらの display にも包含されない
        // 中心 (1000, -500) は A の中心 (960, 540) の方が B の中心 (2880, 540) より近い
        let frame = LogicalRect(minX: 500, minY: -1000, maxX: 1500, maxY: 0)
        let r = resolveFocusDisplay(windowFrame: frame, displays: displays)
        XCTAssertEqual(r?.displayId, "A", "外側点でも距離最小の display が選ばれる")
    }

    /// (3) displays が空なら nil。呼び出し側 (FocusFlashObserver.handleAppActivation) は
    ///     nil を受けて dispatch をスキップする契約。
    func testResolveReturnsNilWhenDisplaysEmpty() {
        let frame = LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        XCTAssertNil(resolveFocusDisplay(windowFrame: frame, displays: []))
    }
}
