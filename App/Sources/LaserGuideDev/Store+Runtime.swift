// Store runtime (DR-0004: store 1 個・同期 reduce・action リングバッファ・Effect インタープリタ)
//
// - AppRuntime は AppState を保持し、`dispatch(_:)` で reduce → effects を同期実行する
// - dispatch は main run loop 上でのみ呼ばれる契約 (CGEventTap callback は main run loop に載る)
// - 状態変化通知は `stateDidChange` クロージャで購読側 (オーバーレイ) に配る
// - Effect のうち rewriteEventLocation は tap callback 側で「返り値」として扱う特殊経路
//   (DR-0004 の同期性契約)。ここではリスト内から取り出す助け関数を提供する
import Foundation
import LaserGuideCore

/// Effect インタープリタの委譲先。runtime 外の world (tap 再有効化, 永続化, 通知) を注入する。
public protocol EffectInterpreter: AnyObject {
    func handlePersist(_ workspace: PersistedWorkspaceV3)
    func handleReenableTap()
    func handleNotifyPermissionLost()
}

/// DR-0004 に従う唯一の store。main run loop 上で同期駆動する薄いラッパ。
public final class AppRuntime {
    public private(set) var state: AppState
    public private(set) var log: ActionLog

    /// 状態の read-only な購読口。dispatch 完了時 (最後の effect 実行後) にコールバックされる。
    public var stateDidChange: ((AppState) -> Void)?

    private weak var interpreter: EffectInterpreter?

    public init(initial: AppState, actionLogCapacity: Int = 4096) {
        self.state = initial
        self.log = ActionLog(capacity: actionLogCapacity)
    }

    public func setInterpreter(_ i: EffectInterpreter) { self.interpreter = i }

    /// 通常経路の action 投入。返り値の effect リストのうち rewriteEventLocation 以外を同期実行する。
    /// tap callback 経路は `dispatchForTap(_:)` を使い、rewriteEventLocation を返り値として受ける。
    public func dispatch(_ action: Action) {
        let (nextState, effects) = Store.reduce(state, action)
        state = nextState
        log.append(action)
        for e in effects {
            switch e {
            case .rewriteEventLocation:
                // 非 tap 経路 (displayConfigurationChanged 等) では発生しない。
                // 万一 reduce が返しても副作用は tap callback 経路でのみ意味がある。
                continue
            case let .persist(w):
                interpreter?.handlePersist(w)
            case .reenableTap:
                interpreter?.handleReenableTap()
            case .notifyPermissionLost:
                interpreter?.handleNotifyPermissionLost()
            }
        }
        stateDidChange?(state)
    }

    /// tap callback 専用の dispatch。返り値の rewriteEventLocation を呼び出し側に返し、
    /// callback 内で event.location 書き換えとして即座に反映する契約 (DR-0004)。
    /// rewriteEventLocation 以外の effect は通常経路と同様同期実行する。
    public func dispatchForTap(_ action: Action) -> LogicalPoint? {
        let (nextState, effects) = Store.reduce(state, action)
        state = nextState
        log.append(action)
        var rewrite: LogicalPoint?
        for e in effects {
            switch e {
            case let .rewriteEventLocation(p):
                rewrite = p
            case let .persist(w):
                interpreter?.handlePersist(w)
            case .reenableTap:
                interpreter?.handleReenableTap()
            case .notifyPermissionLost:
                interpreter?.handleNotifyPermissionLost()
            }
        }
        stateDidChange?(state)
        return rewrite
    }
}
