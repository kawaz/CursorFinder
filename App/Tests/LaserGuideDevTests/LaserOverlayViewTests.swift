// LaserOverlayView 用の純関数テスト (DR-0013 決定 1: ウィンドウ枠アウトライン描画 + 追記 C-1)
//
// 2 関数の役割分担:
//   - `windowFrameLocalRect(windowFrame:displayBounds:)`: 震源ウィンドウ frame ∩ display の可視 bbox
//     (**判定用途**: 描画対象があるかを nil 判定で見る、返り値の 4 辺を stroke してはいけない)
//   - `windowFrameShiftedToDisplay(windowFrame:displayBounds:)`: windowFrame **全体** を display 起点で
//     view-local にシフトした rect (**描画用途**: 負値 / display 幅超過を含む、SwiftUI 側 .clipped()
//     で自 display 領域に切る前提)
//
// この 2 関数の対で「モニタまたぎ時に境界辺 (実際のウィンドウ枠でない側の辺) が描画されない」意味論を
// 実現する。旧実装 (intersection の 4 辺を stroke) は DR-0013 追記の C-1 で報告された欠陥
// (「両 overlay の境界辺が繋がって display 境界に太い線が乗る」) を生んでいた。
//
// 検証輪郭 (DR-0013 検証 + 追記 C-1):
//   (a) windowFrameLocalRect: 全体が display 内 → shifted view-local rect
//   (b) windowFrameLocalRect: 一部だけが display と重なる (intersection にクリップ)
//   (c) windowFrameLocalRect: display の完全外 → nil (描画スキップ signal)
//   (d) windowFrameLocalRect: 境界で接するだけ (幅 or 高さ 0) → nil
//   (e) windowFrameShiftedToDisplay: display 内 window は intersection と同じ shifted rect を返す
//       (負値 / 超過は発生しない、両関数が一致)
//   (f) windowFrameShiftedToDisplay: display 境界を跨ぐ window は **負値 / display 幅超過**を含む
//       shifted rect を返す (intersection でない、描画用の窓全体 rect であることの固定)
import XCTest
import CoreGraphics
@testable import LaserGuideDev
import LaserGuideCore

final class LaserOverlayViewTests: XCTestCase {

    // (a): windowFrame が自 display 内に完全に収まる場合、返却 rect は windowFrame を displayBounds.min
    //      で減算しただけの「shifted」view-local rect。次のフォーカス変化までここが描画対象になる。
    func testWindowFrameLocalRectShiftsToViewLocalWhenFullyInside() {
        // display bounds: 内蔵 Retina を模した実機値 (原点 0,0 の primary 想定)
        let display = LogicalRect(minX: 0, minY: 0, maxX: 2056, maxY: 1329)
        // window: display の内部にある通常の矩形
        let window = LogicalRect(minX: 100, minY: 200, maxX: 500, maxY: 700)

        guard let result = windowFrameLocalRect(windowFrame: window, displayBounds: display) else {
            XCTFail("windowFrame は display に完全包含なので nil ではなく shifted rect が返るはず")
            return
        }
        XCTAssertEqual(result.minX, 100, accuracy: 1e-9, "displayBounds.minX=0 を減算しただけ")
        XCTAssertEqual(result.minY, 200, accuracy: 1e-9)
        XCTAssertEqual(result.maxX, 500, accuracy: 1e-9)
        XCTAssertEqual(result.maxY, 700, accuracy: 1e-9)
    }

    // (a'): display の原点が非ゼロ (二次モニタで CG global の 負座標領域にある LG UltraGear 等) でも
    //       減算だけで view-local に落ちる。DR-0005 の「pose を経由しない、CG global 単純減算」規律
    //       (LaserGeometry.viewLocal と同じ思想) を windowFrame にも適用することの固定。
    func testWindowFrameLocalRectHandlesNonZeroOriginDisplay() {
        // LG UltraGear を模した display (原点が (-258, -1440))
        let display = LogicalRect(minX: -258, minY: -1440, maxX: 3182, maxY: 0)
        // window: display 内部の任意矩形 (負座標を含む)
        let window = LogicalRect(minX: -100, minY: -1000, maxX: 500, maxY: -500)

        guard let result = windowFrameLocalRect(windowFrame: window, displayBounds: display) else {
            XCTFail("負原点 display 内の window は shifted rect を返すはず")
            return
        }
        // (-100) - (-258) = 158
        XCTAssertEqual(result.minX, 158, accuracy: 1e-9)
        // (-1000) - (-1440) = 440
        XCTAssertEqual(result.minY, 440, accuracy: 1e-9)
        // 500 - (-258) = 758
        XCTAssertEqual(result.maxX, 758, accuracy: 1e-9)
        // (-500) - (-1440) = 940
        XCTAssertEqual(result.maxY, 940, accuracy: 1e-9)
    }

    // (b): windowFrame が display 境界を跨ぐ場合、intersection だけを view-local に返す。
    //      「モニタまたぎのウィンドウは各 overlay が自分の担当部分だけを描く」DR-0013 決定 1 の
    //      核心を固定する (跨いだ側の overlay は自分側の切り取り rect を持つ)。
    func testWindowFrameLocalRectClipsToIntersectionOnBoundaryCrossing() {
        // 左 display: 0..1000 × 0..800
        let leftDisplay = LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800)
        // window: 左 display の右半分 + 右 display 側にはみ出す (600..1300 × 100..500)
        let window = LogicalRect(minX: 600, minY: 100, maxX: 1300, maxY: 500)

        guard let result = windowFrameLocalRect(windowFrame: window, displayBounds: leftDisplay) else {
            XCTFail("左 display と 400px 幅の overlap があるので描画対象、nil であってはならない")
            return
        }
        // intersection: 600..1000 × 100..500 → view-local (600, 100)-(1000, 500)
        XCTAssertEqual(result.minX, 600, accuracy: 1e-9, "window.minX と display.minX の max")
        XCTAssertEqual(result.minY, 100, accuracy: 1e-9)
        XCTAssertEqual(result.maxX, 1000, accuracy: 1e-9, "window.maxX と display.maxX の min (display 端で clip)")
        XCTAssertEqual(result.maxY, 500, accuracy: 1e-9)
    }

    // (c): windowFrame が完全に自 display の外にあれば nil。この overlay は描画をスキップする。
    //      隣モニタで発火したフォーカスフラッシュを、自 overlay が空 rect で描画しようとしない保証。
    func testWindowFrameLocalRectReturnsNilWhenWindowIsCompletelyOutside() {
        let display = LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800)
        // 右隣モニタ (x=1000..) のみを占めるウィンドウ
        let outsideWindow = LogicalRect(minX: 1200, minY: 100, maxX: 1800, maxY: 500)

        let result = windowFrameLocalRect(windowFrame: outsideWindow, displayBounds: display)

        XCTAssertNil(result, "display の外にあるウィンドウは描画対象外 (nil で描画スキップ)")
    }

    // (d): 境界で接するだけ (幅 or 高さ 0 の intersection) は「重ならない」扱いで nil。
    //      継ぎ目 (display 境界) にきっかり載る windowFrame で空 rect の描画を発火させないためのガード
    //      (SwiftUI の 0px rect は不要な GraphicsContext 呼び出しになるだけで実害はないが、
    //       意図として「重なりが厳密に必要」を明示する)。
    func testWindowFrameLocalRectReturnsNilOnEdgeTouch() {
        let display = LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800)
        // 右端で接する window (minX = display.maxX)
        let rightEdgeTouch = LogicalRect(minX: 1000, minY: 100, maxX: 1500, maxY: 500)
        XCTAssertNil(windowFrameLocalRect(windowFrame: rightEdgeTouch, displayBounds: display),
                     "境界で接するだけの window は nil (幅 0 の intersection)")

        // 上端で接する window (minY = display.maxY)
        let bottomEdgeTouch = LogicalRect(minX: 200, minY: 800, maxX: 600, maxY: 1000)
        XCTAssertNil(windowFrameLocalRect(windowFrame: bottomEdgeTouch, displayBounds: display),
                     "境界で接するだけの window は nil (高さ 0 の intersection)")
    }

    // MARK: - windowFrameShiftedToDisplay (DR-0013 追記 C-1: 描画用 rect の意味論)

    // (e): windowFrame が display 内部に完全包含される場合、shifted rect は windowFrameLocalRect が
    //      返す intersection と一致する (負値 / 超過は発生しない = 両関数の返り値が bit 単位で等価)。
    //      これにより「display 内包時は描画 rect と可視 bbox が同じ」自明な軸が固定される。
    func testWindowFrameShiftedToDisplayEqualsIntersectionWhenFullyInside() {
        let display = LogicalRect(minX: 0, minY: 0, maxX: 2056, maxY: 1329)
        let window = LogicalRect(minX: 100, minY: 200, maxX: 500, maxY: 700)

        let shifted = windowFrameShiftedToDisplay(windowFrame: window, displayBounds: display)
        guard let intersection = windowFrameLocalRect(windowFrame: window, displayBounds: display) else {
            XCTFail("前提: display 内包の window は intersection nil であってはならない")
            return
        }
        XCTAssertEqual(shifted.minX, intersection.minX, accuracy: 1e-9,
                       "display 内包時は shifted と intersection の minX が一致")
        XCTAssertEqual(shifted.minY, intersection.minY, accuracy: 1e-9)
        XCTAssertEqual(shifted.maxX, intersection.maxX, accuracy: 1e-9,
                       "display 内包時は shifted と intersection の maxX が一致 (超過なし)")
        XCTAssertEqual(shifted.maxY, intersection.maxY, accuracy: 1e-9)
    }

    // (f): display 境界を跨ぐ windowFrame は shifted rect が **負値 / display 幅超過** を含む。
    //      **描画用途** としては、この負値・超過を含む rect 全体を Rectangle().stroke() の frame として
    //      配置し、SwiftUI 側の .clipped() で自 display 領域 [0, displayWidth] × [0, displayHeight] に
    //      切ることで「隣 display 側の 4 辺は描画されない」を実現する。
    //
    //      このテストの返り値は **intersection ではない** (windowFrameLocalRect の返り値と異なる) こと
    //      が肝で、旧実装 (intersection の 4 辺を stroke → 境界に線が乗る C-1 欠陥) との構造的な違いを
    //      固定する。
    func testWindowFrameShiftedToDisplayKeepsFullWindowRectAcrossBoundary() {
        // 左 display: 0..1000 × 0..800
        let leftDisplay = LogicalRect(minX: 0, minY: 0, maxX: 1000, maxY: 800)
        // window: 左 display を跨ぎ 600..1300 × 100..500 (300px が右 display 側にはみ出す)
        let window = LogicalRect(minX: 600, minY: 100, maxX: 1300, maxY: 500)

        let shifted = windowFrameShiftedToDisplay(windowFrame: window, displayBounds: leftDisplay)
        // 単純減算: (600-0, 100-0, 1300-0, 500-0) = (600, 100, 1300, 500)
        // 特に maxX=1300 は display 幅 (=1000) を超過する = windowFrame 全体が保存されている証拠
        XCTAssertEqual(shifted.minX, 600, accuracy: 1e-9)
        XCTAssertEqual(shifted.minY, 100, accuracy: 1e-9)
        XCTAssertEqual(shifted.maxX, 1300, accuracy: 1e-9,
                       "display 幅 (1000) を超える maxX が保存される (描画用 rect は windowFrame 全体)")
        XCTAssertEqual(shifted.maxY, 500, accuracy: 1e-9)

        // 対比のため windowFrameLocalRect (= intersection) は maxX=1000 (display 端で clip される)。
        // 描画関数側は shifted (maxX=1300) を stroke frame にし、SwiftUI の clip で display 端を切る。
        // 旧実装は intersection (maxX=1000) を frame にしていたため display 境界 (x=1000) に stroke が乗り
        // 「両 overlay の境界辺が繋がって太い線」の欠陥 (C-1) を生んでいた。
        guard let intersection = windowFrameLocalRect(windowFrame: window, displayBounds: leftDisplay) else {
            XCTFail("前提: 交差ありなので intersection nil ではない")
            return
        }
        XCTAssertNotEqual(intersection.maxX, shifted.maxX,
                          "モニタまたぎ時、shifted と intersection の maxX は違う (描画側は windowFrame 全体を保持)")
    }

    // (f'): 左側 display の左端を跨ぐ場合、shifted の minX は **負値**。SwiftUI の .clipped() で
    //       [0, displayWidth] × [0, displayHeight] に切られるため、左端に沿った辺 (display 境界の
    //       内側 = 実際のウィンドウ枠でない側) は描画されない。負値保持を明示テストする。
    func testWindowFrameShiftedToDisplayKeepsNegativeCoordinateAcrossLeftBoundary() {
        // 右 display: 1000..2000 × 0..800 (CG global で origin.x=1000)
        let rightDisplay = LogicalRect(minX: 1000, minY: 0, maxX: 2000, maxY: 800)
        // window: 右 display の左端を跨いで 700..1200 × 100..500 (右 display 内から見ると minX=-300)
        let window = LogicalRect(minX: 700, minY: 100, maxX: 1200, maxY: 500)

        let shifted = windowFrameShiftedToDisplay(windowFrame: window, displayBounds: rightDisplay)
        XCTAssertEqual(shifted.minX, -300, accuracy: 1e-9,
                       "display の外 (左側) にはみ出す成分は負値のまま保存される (SwiftUI .clipped() で切る前提)")
        XCTAssertEqual(shifted.maxX, 200, accuracy: 1e-9, "1200 - 1000 = 200 (display 内側の右端)")
        XCTAssertEqual(shifted.minY, 100, accuracy: 1e-9)
        XCTAssertEqual(shifted.maxY, 500, accuracy: 1e-9)
    }
}
