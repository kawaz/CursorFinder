// FocusFlashObserver — 純関数部分 (`resolveFocusDisplay` / `focusedWindowAction` /
// AX 通知列登録) のテスト。
//
// 対象範囲:
//   (1) `resolveFocusDisplay`: 「AX から取れた window frame + 現在の displays」→ displayId の解決
//   (2) `focusedWindowAction`: 上記解決結果に元 frame を添えて `.focusedWindowChanged` 用の Action を組む
//   (3) `observedAXNotifications` / `installAXNotifications` / `removeAXNotifications` (DR-0013 決定 2):
//       AXObserver 実物を作らず、注入した closure 経由で「呼ばれた CFString 列」を assert し、
//       3 通知が定数列通りに登録・解除されることを固定する
//
// 該当なし (unit test 対象外):
//   - AXObserver の C コールバック配線 / RunLoop source の登録・解除 / AXObserverCreate 失敗時 degrade。
//     これらは実プロセスの AX 挙動と macOS RunLoop に依存し、XCTest プロセス内で
//     再現性ある assertion にできない。実機確認 (docs/runbooks/v3-dev-run.md) で覆う:
//       * 同一アプリ内で Cmd-` / ダイアログ open による窓切替でエフェクトが発火する
//       * AX 非対応アプリ (Terminal 等の一部) では NSLog の AXError が Console に出て、
//         アプリ切替時のみ発火する degrade 挙動になる
//       * トグル off / アプリ終了で AXObserver が leak しない (Instruments で確認)
//   - AX 経由の座標変換 (`convertAXFrameToCGGlobal`): AX が返す y-down 値を identity で通すだけの
//     境界関数。実機観測 (2026-07-12, 14 アプリ × CGWindowList 突合で全一致) が根拠。
import XCTest
import ApplicationServices
@testable import LaserGuideDev
import LaserGuideCore

final class FocusFlashObserverTests: XCTestCase {

    private func makeDisplays() -> [Display] {
        return [
            Display(id: "A", logicalBounds: LogicalRect(minX: 0, minY: 0, maxX: 1920, maxY: 1080), pose: .identity),
            Display(id: "B", logicalBounds: LogicalRect(minX: 1920, minY: 0, maxX: 3840, maxY: 1080), pose: .identity),
        ]
    }

    // MARK: - resolveFocusDisplay

    /// (1) ウィンドウ中心が display "A" の矩形に包含されれば "A" を返す (通常経路)。
    func testResolveReturnsContainingDisplayWhenWindowCenterIsInsideIt() {
        let displays = makeDisplays()
        // 中心 (400, 400) は A の内部
        let frame = LogicalRect(minX: 100, minY: 100, maxX: 700, maxY: 700)
        let r = resolveFocusDisplay(windowFrame: frame, displays: displays)
        XCTAssertEqual(r?.displayId, "A")
        XCTAssertEqual(r?.windowCenter, LogicalPoint(x: 400, y: 400))
    }

    /// (1') 隣モニタ B に中心があれば "B" を返す。境界を跨ぐ frame でも中心が判定基準。
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

    /// (3) displays が空なら nil。呼び出し側 (FocusFlashObserver.dispatchIfResolvable) は
    ///     nil を受けて dispatch をスキップする契約。
    func testResolveReturnsNilWhenDisplaysEmpty() {
        let frame = LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        XCTAssertNil(resolveFocusDisplay(windowFrame: frame, displays: []))
    }

    // MARK: - focusedWindowAction

    /// (A) 解決成功時、`.focusedWindowChanged` を返し、`windowFrame` は入力 frame そのまま (震源座標を
    ///     縮退させずに reducer へ渡す契約: DR-0011 決定 4)。displayId は resolveFocusDisplay 結果と一致。
    func testFocusedWindowActionReturnsWindowChangedActionWithOriginalFrame() {
        let displays = makeDisplays()
        // 中心 (2500, 500) は B の内部。frame は角丸位置ではなく resolver に渡した原値がそのまま Action に載る。
        let frame = LogicalRect(minX: 2200, minY: 200, maxX: 2800, maxY: 800)
        let action = focusedWindowAction(windowFrame: frame, displays: displays)
        XCTAssertEqual(action, .focusedWindowChanged(displayId: "B", windowFrame: frame))
    }

    /// (B) displays が空なら Action を組めない (= nil)。呼び出し側は dispatch をスキップする。
    ///     display 情報が届く前の起動タイミングでの空振り無害化。
    func testFocusedWindowActionReturnsNilWhenNoDisplays() {
        let frame = LogicalRect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        XCTAssertNil(focusedWindowAction(windowFrame: frame, displays: []))
    }

    /// (C) frame が全 display の外でも、resolveFocusDisplay の fallback (距離最小) で解決される限り
    ///     Action は発火する。震源座標として fallback 相手モニタではなく **元 frame** が保持されることを固定
    ///     (波動は元 frame を震源として計算するため、fallback で座標が歪んではならない)。
    func testFocusedWindowActionKeepsOriginalFrameEvenWhenFallbackResolves() {
        let displays = makeDisplays()
        let frame = LogicalRect(minX: 500, minY: -1000, maxX: 1500, maxY: 0)  // 上外
        let action = focusedWindowAction(windowFrame: frame, displays: displays)
        // displayId は最近接 A、windowFrame は入力そのまま (中心が A 内に変換されたりしない)
        XCTAssertEqual(action, .focusedWindowChanged(displayId: "A", windowFrame: frame))
    }

    // MARK: - DR-0013: AX 通知列の定数化と登録関数注入

    /// DR-0013 決定 2: 3 通知列 (`kAXFocusedWindowChanged` / `kAXMainWindowChanged` / `kAXWindowCreated`)
    /// が `observedAXNotifications` にこの順序で並ぶ。実装 (`installAXObserver`) はこの定数列を舐めるだけで
    /// 3 通知を登録するため、順序と要素の固定が回帰検出になる。**kAXFocusedUIElementChanged は含まない**
    /// (テキストフィールド間フォーカスで大量発火するため意図的に除外、DR-0013 不採用案)。
    func testObservedAXNotificationsContainsExactlyThreeExpectedNotifications() {
        let observed = FocusFlashObserver.observedAXNotifications.map { $0 as String }
        XCTAssertEqual(observed, [
            kAXFocusedWindowChangedNotification as String,
            kAXMainWindowChangedNotification as String,
            kAXWindowCreatedNotification as String
        ], "3 通知が定数列に定義順で並ぶ")

        // Negative: 除外通知が含まれていないこと (kAXFocusedUIElementChanged の意図的除外を assert)。
        XCTAssertFalse(observed.contains(kAXFocusedUIElementChangedNotification as String),
                       "kAXFocusedUIElementChanged は UX ノイズになるため購読しない (DR-0013 不採用案)")
    }

    /// DR-0013 決定 2: `installAXNotifications` は与えられた register closure を各通知について 1 回ずつ、
    /// `observedAXNotifications` の順序で呼ぶ。テストは AXObserver 実物なしで「呼ばれた列」を記録する
    /// mock を差し込んで、通知列が固定順で登録経路に流れることを固定する
    /// (= `installAXObserver` の副作用注入部が 3 通知を漏らさず登録する契約)。
    func testInstallAXNotificationsInvokesRegisterForAllObservedNotificationsInOrder() {
        var recorded: [String] = []
        FocusFlashObserver.installAXNotifications { notif in
            recorded.append(notif as String)
        }
        XCTAssertEqual(recorded, [
            kAXFocusedWindowChangedNotification as String,
            kAXMainWindowChangedNotification as String,
            kAXWindowCreatedNotification as String
        ], "installAXNotifications は 3 通知を定数列順で register に流す")
    }

    /// 対称: `removeAXNotifications` も同じ順序で unregister を呼ぶ (`tearDownAXObserver` の
    /// AXObserverRemoveNotification 経路で 3 通知全てが解除されることの固定 — 解除漏れは AXObserver leak
    /// の直接原因になるため regression 検出)。
    func testRemoveAXNotificationsInvokesUnregisterForAllObservedNotificationsInOrder() {
        var recorded: [String] = []
        FocusFlashObserver.removeAXNotifications { notif in
            recorded.append(notif as String)
        }
        XCTAssertEqual(recorded, [
            kAXFocusedWindowChangedNotification as String,
            kAXMainWindowChangedNotification as String,
            kAXWindowCreatedNotification as String
        ], "removeAXNotifications は 3 通知を定数列順で unregister に流す")
    }

    /// installAXNotifications / removeAXNotifications は notifications 引数を差し替えできる
    /// (= 任意の CFString 列を受けて register / unregister を順に呼ぶ純関数として動く)。
    /// 実装は `observedAXNotifications` をデフォルト実引数として使う契約なので、テストは
    /// 差し替えられることの確認までにとどめる (実運用では常に default で呼ばれる)。
    func testInstallAXNotificationsAcceptsCustomNotificationListForFlexibility() {
        var recorded: [String] = []
        let custom: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString
        ]
        FocusFlashObserver.installAXNotifications(notifications: custom) { notif in
            recorded.append(notif as String)
        }
        XCTAssertEqual(recorded, [
            kAXWindowCreatedNotification as String,
            kAXFocusedWindowChangedNotification as String
        ], "任意の通知列を受けて順に register を呼ぶ純関数として振る舞う")
    }
}
