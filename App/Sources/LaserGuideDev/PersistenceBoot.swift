// PersistenceBoot (DR-0007 決定 1-5)
//
// AppDelegate 起動時の永続化配線を純関数寄りにまとめる:
//   1. v3 key があれば decode → Reconcile.reconcile で現構成へ適用
//   2. v3 が無く v1 の非 temporary key があれば V1Migration.migrate → 3-part hardwareId を
//      現構成の 4-part hardwareId へ canonicalize → v3 key として保存
//   3. どちらも無ければ nil (呼び出し側は AppState.initial で os コピー初期化)
//   4. 上記いずれの場合も、v1 の `.temporary` プレビューキーは読み捨て削除する
//      (DR-0007 決定 5)
//
// scale の再導出:
//   pose.scale は「現在の解像度 + CGDisplayScreenSize から都度導出」する契約 (DR-0005 決定 2)。
//   保存値は V1Migration 経由では identity プレースホルダ (1.0)、v3 保存では前回書き込み時の
//   値なので、いずれもここで現構成の scale で上書きする。translate は保存値をそのまま尊重する
//   (キャリブレーション結果の本体)。
//
// 3-part vs 4-part hardwareId (2026-07-10 発見の実装矛盾、report 済):
//   V1DisplayIdentifier.stringRepresentation = "vendor-model-serial" (V1Schema.swift:22)
//   DisplaySnapshotProvider.hardwareId       = "vendor-model-serial-unit" (DisplaySnapshotProvider.swift:100)
//   v1 migration の出力は 3-part のままなので、そのままだと Reconcile が現構成 (4-part) と
//   マッチしない。ここで「3-part → 4-part」対応表を現 snapshot 列から作って書き換える。
//   同モデル 2 枚が同じ 3-part に潰れる衝突ケースは対応表からドロップする (v1 自体が同モデル
//   2 枚を区別できないため、そもそも v1 側で片方の設定が失われている構造上の問題)。
import Foundation
import LaserGuideCore

/// UserDefaults を Core の KeyValueStore プロトコルに適合させる薄いラッパ (DR-0007)。
///
/// - `data(forKey:)` / `removeObject(forKey:)` は UserDefaults の既存メソッドとシグネチャが
///   完全一致するため、追加実装不要で自動適合する。
/// - `set(_:forKey:)` は UserDefaults 側が `Any?` を取る一方、protocol は `Data` を要求する。
///   Swift の protocol 適合は厳密シグネチャ一致を要求するため、Data 版を明示的に足して
///   Any? 経路へ委譲する。
/// - `allKeys()` は UserDefaults には無いので `dictionaryRepresentation()` の keys から作る。
extension UserDefaults: @retroactive KeyValueStore {
    public func set(_ data: Data, forKey key: String) {
        // NSDictionary bridging 経由の Any? overload へ委譲。Data は plist 型なので UserDefaults は
        // そのまま格納する (Base64 化されない、`data(forKey:)` で往復可能)。
        self.set(data as Any?, forKey: key)
    }

    public func allKeys() -> [String] {
        Array(self.dictionaryRepresentation().keys)
    }
}

/// 起動時 load 処理の結果。純関数として単体テスト可能にするため、
/// AppState 構築を呼び出し側 (AppDelegate) に委ねる形にした。
public struct PersistenceBootResult: Equatable {
    public enum Outcome: Equatable {
        /// v3 保存 or v1 migration から再構成が取れたケース。scale は現構成で上書き済み。
        case usedPersisted(ReconcileResult)
        /// v3/v1 いずれも見つからなかった (初回起動想定)。AppDelegate は AppState.initial に倒す。
        case noPersistence
    }
    public let outcome: Outcome
    public let didMigrateFromV1: Bool
    public let temporaryKeysDeleted: [String]

    public init(outcome: Outcome, didMigrateFromV1: Bool, temporaryKeysDeleted: [String]) {
        self.outcome = outcome
        self.didMigrateFromV1 = didMigrateFromV1
        self.temporaryKeysDeleted = temporaryKeysDeleted
    }
}

public enum PersistenceBoot {

    /// 起動時 load: v3 → v1 → none の順で試し、v1 経由時は canonicalize + v3 key へ保存する。
    /// v1 の `.temporary` キーは常に読み捨てて削除する (DR-0007 決定 5)。
    ///
    /// - Parameters:
    ///   - store: 永続化バックエンド (本番は UserDefaults.standard、テストは InMemoryKeyValueStore)
    ///   - currentSnapshots: DisplaySnapshotProvider.scan() の結果
    ///   - currentScaleByHardwareId: 各 v3 hardwareId → 現構成の scale (mm/px)。保存値の scale を
    ///     この値で上書きする (DR-0005 決定 2、V1Migration の identity プレースホルダ対応)
    ///   - currentPixelSizeByHardwareId: 各 v3 hardwareId → px 幅・高さ (V1Migration の EdgeZone
    ///     0-1 正規化区間を logicalStart/End へ変換するため)
    public static func loadAndPersist(
        store: KeyValueStore,
        currentSnapshots: [DisplaySnapshot],
        currentScaleByHardwareId: [String: (scaleX: Double, scaleY: Double)],
        currentPixelSizeByHardwareId: [String: V1CurrentPixelSize]
    ) -> PersistenceBootResult {
        let workspaceKey = PersistenceKeyV3.workspaceKey(
            hardwareIds: currentSnapshots.map(\.id))

        // v3 保存の読み込み。decodeTolerantly で「未来 version」も安全に nil 化される。
        if let data = store.data(forKey: workspaceKey),
           let persisted = PersistedWorkspaceV3.decodeTolerantly(data) {
            let temporaryKeysDeleted = removeV1TemporaryKeys(store: store)
            let reconciled = reconcileWithScaleOverride(
                persisted: persisted, currentSnapshots: currentSnapshots,
                currentScaleByHardwareId: currentScaleByHardwareId)
            return PersistenceBootResult(
                outcome: .usedPersisted(reconciled),
                didMigrateFromV1: false,
                temporaryKeysDeleted: temporaryKeysDeleted)
        }

        // v1 non-temporary key を探して migrate。複数見つかった場合は最初に decode 成功したものを採用
        // (v1 自身は displays 集合ごとに別 key を書くが、現構成に一致する v1 key を優先的に選ぶ)。
        let allKeys = store.allKeys()
        let v1Keys = allKeys.filter(PersistenceKeyV1.isPersistentConfigKey)
        let v1PixelSize = buildV1PixelSizeMap(currentPixelSizeByHardwareId)
        var migratedRaw: PersistedWorkspaceV3?
        for key in v1Keys.sorted() {  // sorted で再現性のあるテストにする
            guard let data = store.data(forKey: key) else { continue }
            if let m = V1Migration.migrate(v1Data: data, currentPixelSizeByHardwareId: v1PixelSize) {
                migratedRaw = m
                break
            }
        }
        let temporaryKeysDeleted = removeV1TemporaryKeys(store: store)

        if let migratedRaw {
            let canonical = canonicalizeV1ToV3HardwareIds(
                migratedRaw, currentSnapshots: currentSnapshots)
            // v3 key として保存 (次回起動から v3 経路で読める)。
            if let encoded = try? canonical.encoded() {
                store.set(encoded, forKey: workspaceKey)
            }
            let reconciled = reconcileWithScaleOverride(
                persisted: canonical, currentSnapshots: currentSnapshots,
                currentScaleByHardwareId: currentScaleByHardwareId)
            return PersistenceBootResult(
                outcome: .usedPersisted(reconciled),
                didMigrateFromV1: true,
                temporaryKeysDeleted: temporaryKeysDeleted)
        }

        return PersistenceBootResult(
            outcome: .noPersistence,
            didMigrateFromV1: false,
            temporaryKeysDeleted: temporaryKeysDeleted)
    }

    /// persist effect の書き込み経路。AppDelegate.handlePersist から呼ばれる。
    /// workspaceKey は displays 集合が変わったら別 key になるので、encode 失敗時のみ log を残す
    /// (成功時の log は AppDelegate 側で必要なら足す)。
    public static func persist(
        _ workspace: PersistedWorkspaceV3, to store: KeyValueStore
    ) {
        let key = PersistenceKeyV3.workspaceKey(
            hardwareIds: workspace.displays.map(\.hardwareId))
        guard let data = try? workspace.encoded() else { return }
        store.set(data, forKey: key)
    }

    // MARK: - internal helpers (テストのため internal 公開)

    /// 現構成の scale で pose.scale を上書きした上で Reconcile.reconcile を実行する。
    /// translate は保存値をそのまま尊重する (キャリブレーション結果の本体、DR-0005 決定 2)。
    static func reconcileWithScaleOverride(
        persisted: PersistedWorkspaceV3, currentSnapshots: [DisplaySnapshot],
        currentScaleByHardwareId: [String: (scaleX: Double, scaleY: Double)]
    ) -> ReconcileResult {
        let overridden = PersistedWorkspaceV3(
            version: persisted.version,
            displays: persisted.displays.map { d -> PersistedDisplayV3 in
                guard let scale = currentScaleByHardwareId[d.hardwareId] else { return d }
                return PersistedDisplayV3(
                    hardwareId: d.hardwareId,
                    pose: DisplayPose(
                        translate: d.pose.translate,
                        scaleX: scale.scaleX, scaleY: scale.scaleY),
                    userSegments: d.userSegments)
            })
        return Reconcile.reconcile(persisted: overridden, currentSnapshots: currentSnapshots)
    }

    /// v3 4-part hardwareId ("vendor-model-serial-unit") を v1 3-part id ("vendor-model-serial")
    /// にマップして、V1Migration に渡す px サイズ辞書を作る。3-part への衝突は最初の一件を優先
    /// (= 同モデル 2 枚が同じ 3-part に潰れるケース、v1 自身が区別できていない前提なので
    /// どちらを採用しても v1 側の意味論的損失は同等)。
    static func buildV1PixelSizeMap(
        _ v3Map: [String: V1CurrentPixelSize]
    ) -> [String: V1CurrentPixelSize] {
        var out: [String: V1CurrentPixelSize] = [:]
        for (v3Id, size) in v3Map {
            let parts = v3Id.split(separator: "-")
            guard parts.count >= 3 else { continue }
            let v1Id = parts.prefix(3).joined(separator: "-")
            if out[v1Id] == nil { out[v1Id] = size }
        }
        return out
    }

    /// V1Migration 結果の 3-part hardwareId / PassSegment.displayId を、現構成の 4-part v3
    /// hardwareId に書き換える。「3-part → 4-part」対応表は現 snapshot 列の unique 対応から作る
    /// (衝突する 3-part は対応表から除外し、そこに乗る display と segment は結果から drop する)。
    static func canonicalizeV1ToV3HardwareIds(
        _ migrated: PersistedWorkspaceV3, currentSnapshots: [DisplaySnapshot]
    ) -> PersistedWorkspaceV3 {
        var v1ToV3: [String: String] = [:]
        var collided: Set<String> = []
        for snap in currentSnapshots {
            let parts = snap.id.split(separator: "-")
            guard parts.count >= 3 else { continue }
            let v1Id = parts.prefix(3).joined(separator: "-")
            if v1ToV3[v1Id] != nil {
                collided.insert(v1Id)
                v1ToV3.removeValue(forKey: v1Id)
            } else if !collided.contains(v1Id) {
                v1ToV3[v1Id] = snap.id
            }
        }
        // 4-part id はそのまま、3-part id は v1ToV3 経由でリマップ。解決不能な id は drop。
        func rewriteId(_ id: String) -> String? {
            let parts = id.split(separator: "-")
            if parts.count == 4 { return id }
            if parts.count == 3 { return v1ToV3[id] }
            return nil
        }
        let newDisplays: [PersistedDisplayV3] = migrated.displays.compactMap { d in
            guard let newHwId = rewriteId(d.hardwareId) else { return nil }
            let newSegments: [PassSegment] = d.userSegments.compactMap { seg in
                guard let newSegDisplayId = rewriteId(seg.displayId) else { return nil }
                return PassSegment(
                    id: seg.id, displayId: newSegDisplayId, side: seg.side,
                    logicalStart: seg.logicalStart, logicalEnd: seg.logicalEnd,
                    pairedSegmentId: seg.pairedSegmentId)
            }
            return PersistedDisplayV3(
                hardwareId: newHwId, pose: d.pose, userSegments: newSegments)
        }
        return PersistedWorkspaceV3(version: migrated.version, displays: newDisplays)
    }

    /// v1 の `.temporary` プレビューキーを列挙して削除し、削除したキー一覧を返す (DR-0007 決定 5)。
    @discardableResult
    static func removeV1TemporaryKeys(store: KeyValueStore) -> [String] {
        let keys = store.allKeys().filter(PersistenceKeyV1.isTemporaryKey)
        for k in keys { store.removeObject(forKey: k) }
        return keys
    }
}
