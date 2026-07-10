// KeyValueStore プロトコルと in-memory 実装のテスト (DR-0007: UserDefaults 抽象)
//
// App 側の実装 (UserDefaults) はここでは検証できない (Foundation.UserDefaults への準拠は
// App/ 配線時に追加する想定)。ここでは「プロトコルが要求する契約」を in-memory 実装で固定し、
// 他の Persistence 純関数のテストがこの実装を安全に使えることを保証する。
import XCTest
@testable import LaserGuideCore

final class InMemoryKeyValueStoreTests: XCTestCase {

    /// 基本の get/set/remove が素直に動くこと。
    func testSetGetRemoveRoundTrip() {
        let store = InMemoryKeyValueStore()
        XCTAssertNil(store.data(forKey: "k"))

        let payload = "hello".data(using: .utf8)!
        store.set(payload, forKey: "k")
        XCTAssertEqual(store.data(forKey: "k"), payload)

        store.removeObject(forKey: "k")
        XCTAssertNil(store.data(forKey: "k"))
    }

    /// allKeys() が現在保持しているキーを過不足なく列挙する (v1 `.temporary` 残骸キーの
    /// 列挙・削除に必要な契約、DR-0007 決定 5)。
    func testAllKeysReflectsCurrentContents() {
        let store = InMemoryKeyValueStore()
        store.set(Data(), forKey: "a")
        store.set(Data(), forKey: "b")
        XCTAssertEqual(Set(store.allKeys()), Set(["a", "b"]))

        store.removeObject(forKey: "a")
        XCTAssertEqual(Set(store.allKeys()), Set(["b"]))
    }

    /// initial: で事前投入したデータもプロトコル経由で読める (テストの fixture 注入経路)。
    func testInitialContentsAreAccessibleThroughProtocol() {
        let store: KeyValueStore = InMemoryKeyValueStore(initial: ["pre": Data([1, 2, 3])])
        XCTAssertEqual(store.data(forKey: "pre"), Data([1, 2, 3]))
    }

    /// 同一キーへの set は上書きする (追記ではない)。
    func testSetOverwritesExistingValue() {
        let store = InMemoryKeyValueStore()
        store.set(Data([1]), forKey: "k")
        store.set(Data([2]), forKey: "k")
        XCTAssertEqual(store.data(forKey: "k"), Data([2]))
    }

    /// 存在しないキーの removeObject は無害 (crash しない)。
    func testRemovingNonexistentKeyIsNoOp() {
        let store = InMemoryKeyValueStore()
        store.removeObject(forKey: "does-not-exist")
        XCTAssertNil(store.data(forKey: "does-not-exist"))
    }
}
