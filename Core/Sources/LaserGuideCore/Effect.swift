// Effect (DR-0004: 副作用は reduce の外、Effect インタープリタが実行する)
//
// - rewriteEventLocation: ワープの主機構。tap callback 内で同期実行され、結果が callback の
//   返り値 (書き換え済みイベント) に反映される契約 (通常の非同期 effect とは異なる、DR-0004)
// - persist: ユーザ編集セグメントと設定の永続化
// - reenableTap: tap timeout/userInput からの回復
// - notifyPermissionLost: アクセシビリティ権限失効のユーザ通知 (ワープ degrade と対)
import Foundation

/// persist effect が運ぶ永続化対象。DR-0007 決定 2/6/7 の Persistence/PersistedWorkspaceV3 に
/// 一本化した (2026-07-10 team-lead 追加指示、commit b20daaf の永続化スキーマ導入に追従):
///
/// - 従来型 `PersistedWorkspace(userSegments, configuration)` は pose を運ばない実装漏れがあった。
///   キャリブレーション確定 (.commit) で pose を書き換えても保存に載らず、再起動で失われていた
/// - `PersistedWorkspaceV3` は hardwareId 単位で pose + そのモニタ発の userSegments を持つので、
///   キャリブレーション結果が確実に永続化される
/// - configuration (edgeEpsilon 等) は現行 V3 スキーマに含まれない (Persistence/ の所有者が
///   拡張する時に追加される想定)。Phase 1 の Effect インタープリタ (AppDelegate.handlePersist)
///   も UserDefaults 経路が未実装 (NSLog のみ) なので、この乖離は当面問題にならない
public enum Effect: Equatable, Sendable {
    case rewriteEventLocation(LogicalPoint)
    case persist(PersistedWorkspaceV3)
    case reenableTap
    case notifyPermissionLost
}
