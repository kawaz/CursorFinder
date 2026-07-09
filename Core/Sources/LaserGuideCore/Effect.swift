// Effect (DR-0004: 副作用は reduce の外、Effect インタープリタが実行する)
//
// - rewriteEventLocation: ワープの主機構。tap callback 内で同期実行され、結果が callback の
//   返り値 (書き換え済みイベント) に反映される契約 (通常の非同期 effect とは異なる、DR-0004)
// - persist: ユーザ編集セグメントと設定の永続化
// - reenableTap: tap timeout/userInput からの回復
// - notifyPermissionLost: アクセシビリティ権限失効のユーザ通知 (ワープ degrade と対)
import Foundation

/// persist effect が運ぶ永続化対象。displays は OS 自動検出の再現物なので含めない
/// (再起動時は displayConfigurationChanged で都度作り直す)。
public struct PersistedWorkspace: Equatable, Sendable {
    public var userSegments: [PassSegment]
    public var configuration: AppConfiguration
    public init(userSegments: [PassSegment], configuration: AppConfiguration) {
        self.userSegments = userSegments
        self.configuration = configuration
    }
}

public enum Effect: Equatable, Sendable {
    case rewriteEventLocation(LogicalPoint)
    case persist(PersistedWorkspace)
    case reenableTap
    case notifyPermissionLost
}
