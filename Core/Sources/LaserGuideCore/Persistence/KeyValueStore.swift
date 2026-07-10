// UserDefaults 抽象 (DR-0007): 純関数側 (App 側実装は別途配線) から永続化層を切り離す。
//
// - Core は「キーに対する Data の get/set/remove/allKeys」だけを要求する。UserDefaults 固有の
//   API (register, synchronize 等) は持ち込まない。
// - App 側は `extension UserDefaults: KeyValueStore {}` 相当の薄い適合を書けば足りる想定
//   (本ファイルはプロトコル定義のみ、実装は App/ 配線時に追加する)。
import Foundation

public protocol KeyValueStore {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeObject(forKey key: String)
    /// UserDefaults.dictionaryRepresentation().keys 相当。v1 の `.temporary` 残骸キーの
    /// 列挙・削除 (DR-0007 決定 5) に使う。
    func allKeys() -> [String]
}

/// テスト用 in-memory 実装。App 側の UserDefaults 実装と同じ契約でロジックを検証するために使う。
public final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: Data] = [:]

    public init(initial: [String: Data] = [:]) {
        self.storage = initial
    }

    public func data(forKey key: String) -> Data? {
        storage[key]
    }

    public func set(_ data: Data, forKey key: String) {
        storage[key] = data
    }

    public func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }

    public func allKeys() -> [String] {
        Array(storage.keys)
    }
}
