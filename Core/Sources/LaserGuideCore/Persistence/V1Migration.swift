// v1 → v3 migration 純関数 (DR-0007 決定 3)
//
// 起動時に v3 の新 key が無く v1 key があれば、v1 `DisplayConfiguration` を読み新スキーマへ
// 変換して保存する。v2 prefix (`LaserGuide.v2.Workspace.*`) は未リリースのため migration
// 対象外 (DR-0007 背景: 「開発者ローカルのみ」)。
//
// 設計上の既知の制約 (report 必読):
//
// 1. **pose.scale の再現不能性 (2026-07-10 team-lead 承認済み)**: v1 PhysicalDisplayLayout は
//    position/size を mm でのみ持ち、px 解像度を保存しない。DR-0005 決定 2 は「scale は
//    解像度と physical size から導出し、キャリブレーションで補正可能」としており、v1 データ
//    だけでは正しい scaleX/scaleY を再構築できない。ここでは scaleX=scaleY=1.0 (恒等) を
//    暫定値として置く。**読み込み側 (App) は migration 結果を使う前に現在の解像度から実 scale
//    を再導出する契約**であり、この暫定値のまま warp 判定に使ってはならない
//    (Persistence 層の外、Swift App 側の責務)。
// 2. **物理空間の Y 軸反転補正**: DR-0005 (2026-07-10 追記) により物理 mm 空間の軸向きは
//    「論理座標と同一の y-down」と確定した。v1 の position は「Bottom-left corner」
//    (v1 コメント原文、DisplayIdentifier.swift:25) で、NSScreen 座標系 (y-up) の adjacency から
//    BFS 算出されている (LaserGuide.v1.backup/ViewModels/CalibrationViewModel.swift:223-243)。
//    v1 の position (bottom-left, y-up) を v3 の translate (top-left 相当, y-down) に変換するには
//    以下の 2 段の変換が必要:
//      (a) bottom-left → top-left: y-up のまま top edge の y 座標を求める = `position.y + height`
//          (y-up は値が大きいほど上なので、bottom より height 分上が top)
//      (b) y-up → y-down: 軸を反転する = `-(...)`
//    合成すると `y_down = -(position.y + size.height)`。x は左右反転がないため補正不要
//    (`x_down = position.x` のまま)。
import Foundation

/// migration 時に「現在の解像度」を外部から与えるための px サイズ。v1 の EdgeZone は
/// 0.0-1.0 の正規化区間しか持たないため、px の logicalStart/logicalEnd へ変換するには
/// 呼び出し側 (App、NSScreen 由来) から各モニタの現在の px 幅・高さを渡してもらう必要がある。
public struct V1CurrentPixelSize: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum V1Migration {
    /// v1 の `DisplayConfiguration` JSON (config_* キーの値) を v3 スキーマへ変換する。
    ///
    /// - Parameters:
    ///   - v1Data: v1 key から読んだ生 JSON (decode 失敗時は nil を返す、呼び出し側は
    ///     「migration 対象データが壊れていた」として v1 key を読み捨ててよい)。
    ///   - currentPixelSizeByHardwareId: 各モニタの現在の px 幅・高さ (hardwareId をキーに)。
    ///     EdgeZone (0-1 正規化) を px の logicalStart/logicalEnd に変換するために必要。
    ///     対応する px サイズが無いモニタの EdgeZone は変換できないため migration 対象外とする
    ///     (該当モニタは userSegments 空で PersistedDisplayV3 を作る)。
    /// - Returns: 変換後の v3 workspace。v1 JSON が decode できなければ nil。
    public static func migrate(
        v1Data: Data,
        currentPixelSizeByHardwareId: [String: V1CurrentPixelSize]
    ) -> PersistedWorkspaceV3? {
        guard let v1Config = try? JSONDecoder().decode(V1DisplayConfiguration.self, from: v1Data) else {
            return nil
        }

        // hardwareId (= V1DisplayIdentifier.stringRepresentation) ごとの pose。
        // scale は恒等 (1.0) の暫定値、y は Y 軸反転補正済み (上記ファイルコメント参照)。
        var poseByHardwareId: [String: DisplayPose] = [:]
        for layout in v1Config.displays {
            let hardwareId = layout.identifier.stringRepresentation
            let yDown = -(layout.position.y + layout.size.height)
            poseByHardwareId[hardwareId] = DisplayPose(
                translate: PhysicalPoint(x: layout.position.x, y: yDown),
                scaleX: 1.0, scaleY: 1.0
            )
        }

        // zoneId -> (hardwareId, side, 0-1 レンジ) の索引。EdgeZonePair から対応関係を辿るために使う。
        let zoneById = Dictionary(uniqueKeysWithValues: v1Config.edgeZones.map { ($0.id, $0) })

        var userSegmentsByHardwareId: [String: [PassSegment]] = [:]
        for pair in v1Config.edgeZonePairs {
            guard let sourceZone = zoneById[pair.sourceZoneId],
                  let targetZone = zoneById[pair.targetZoneId] else {
                continue  // 対応 zone が見つからない壊れたペアは読み捨てる
            }
            guard
                let sourceSegment = makeSegment(
                    zone: sourceZone, idSuffix: "src", pairedIdSuffix: "tgt", pairId: pair.id,
                    currentPixelSizeByHardwareId: currentPixelSizeByHardwareId),
                let targetSegment = makeSegment(
                    zone: targetZone, idSuffix: "tgt", pairedIdSuffix: "src", pairId: pair.id,
                    currentPixelSizeByHardwareId: currentPixelSizeByHardwareId)
            else {
                continue  // 現在の px サイズが無いモニタが絡むペアは変換できないので読み捨てる
            }
            userSegmentsByHardwareId[sourceSegment.displayId, default: []].append(sourceSegment)
            userSegmentsByHardwareId[targetSegment.displayId, default: []].append(targetSegment)
        }

        let allHardwareIds = Set(poseByHardwareId.keys).union(userSegmentsByHardwareId.keys)
        let displays = allHardwareIds.sorted().map { hardwareId in
            PersistedDisplayV3(
                hardwareId: hardwareId,
                pose: poseByHardwareId[hardwareId] ?? .identity,
                userSegments: userSegmentsByHardwareId[hardwareId] ?? []
            )
        }
        return PersistedWorkspaceV3(displays: displays)
    }

    private static func makeSegment(
        zone: V1EdgeZone, idSuffix: String, pairedIdSuffix: String, pairId: UUID,
        currentPixelSizeByHardwareId: [String: V1CurrentPixelSize]
    ) -> PassSegment? {
        guard let pixelSize = currentPixelSizeByHardwareId[zone.displayId] else { return nil }
        let dimension: Double
        switch zone.edge {
        case .top, .bottom: dimension = pixelSize.width
        case .left, .right: dimension = pixelSize.height
        }
        guard let side = Side(v1: zone.edge) else { return nil }
        let id = "v1migration-\(pairId.uuidString)-\(idSuffix)"
        let pairedId = "v1migration-\(pairId.uuidString)-\(pairedIdSuffix)"
        return PassSegment(
            id: id, displayId: zone.displayId, side: side,
            logicalStart: zone.rangeStart * dimension, logicalEnd: zone.rangeEnd * dimension,
            pairedSegmentId: pairedId
        )
    }
}

private extension Side {
    /// v1 EdgeDirection → v3 Side。両者は座標系 (y-up/y-down) が異なっていても「物理的な辺の
    /// 呼び名」自体は同じ意味論 (top = 上辺、bottom = 下辺) なので、文字列としてそのまま対応する。
    init?(v1 direction: V1EdgeDirection) {
        switch direction {
        case .top: self = .top
        case .bottom: self = .bottom
        case .left: self = .left
        case .right: self = .right
        }
    }
}
