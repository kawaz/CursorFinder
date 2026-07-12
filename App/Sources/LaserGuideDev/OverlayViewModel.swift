// OverlayViewModel (DR-0004: 描画は state 購読、individual action を舐めない)
//
// AppRuntime.stateDidChange と、権限 fallback 時の NSEvent monitor からの mouse 位置更新を
// 1 か所にまとめ、SwiftUI ObservableObject として overlay に流す。
//
// 現在マウス位置の source of truth:
//   - 権限あり (通常経路): AppRuntime.state.currentMouse (Store が更新する)
//   - 権限なし (fallback): NSEvent global monitor (permission fallback 起動時のみ購読)
// どちらも同じ CG y-down 論理座標として `currentMouseLocation` に反映される。
//
// レーザーの表示ライフサイクル (2026-07-10 #2 → 2026-07-11 第 4 ラウンドで opacity ベースに拡張):
//   非表示 → (連続移動が laserShowDebounce 継続) → 表示 (opacity=1)
//   表示 → (移動停止から inactivityThreshold) → laserFadeOutDuration かけてフェードアウト
//   フェード中 → (移動再開) → 即フル輝度復帰 (デバウンス無し)
//
// 描画更新のスロットル (2026-07-10 第 2-3 ラウンド、kawaz 裁定「スロットルは即値で使う一択」):
//   tap 経由 (apply(state:)) も drag monitor 経由 (apply(mouseLocation:)) も OS のイベント
//   レポートレートに比例した高頻度で呼ばれうる (毎回 @Published 発火だと SwiftUI 再評価コストが
//   積み重なりドラッグが重くなる、kawaz 実機報告)。リーディング+トレーリングエッジ型スロットルで
//   合流させる: 前回反映から flushInterval 以上空いた入力は即時反映 (体感遅延を足さない)、
//   interval 内の入力は最新値だけを保持し残り時間で 1 回だけ trailing 反映 (中間値は捨てる)。
//   トレーリングオンリー (全入力を一律待たせる) は静止→動き出しの初動に遅延を足すので採らない。
import Foundation
import AppKit
import Combine
import LaserGuideCore

// 表示表現型 (PresentationClickEvent / ClickCirclePresentation / FocusFlashPresentation) は
// OverlayPresentation.swift に分離。

public final class OverlayViewModel: ObservableObject {
    @Published public var state: AppState
    @Published public var currentMouseLocation: LogicalPoint?
    /// レーザーの表示不透明度 (0 = 非表示、1 = フル表示)。立ち上がりは連続移動が laserShowDebounce
    /// 継続して初めて 1 になり (偶発的な微小移動で出さない)、消灯は移動停止から inactivityThreshold
    /// 後 laserFadeOutDuration かけて 0 へ減衰する。減衰中の移動再開はデバウンス無しで即 1 に復帰。
    @Published public var laserOpacity: Double = 0
    /// プレゼンテーションモード on 時のクリック可視化。off 時 / mouseUp 後の減衰完了時は nil。
    @Published public var clickCircle: ClickCirclePresentation?
    /// フォーカスフラッシュ (DR-0009 Phase A) の現在描画状態。
    /// state.focusFlash の generation 変化を検知して立ち上げ、focusFlashDuration にかけて減衰する。
    /// 減衰完了時 / focus flash 機能 off 時は nil。
    @Published public var focusFlash: FocusFlashPresentation?
    /// フォーカス波動 (DR-0011 決定 5)。focusFlash と同じ generation 検知でモニタ縁と併せて立ち上がる。
    @Published public var wave: WavePresentation?
    /// 波動発火時点で固定した隣接物理レイアウトのスナップショット。view の mm→px 変換に使う。
    @Published public var wavePlacements: [WavePlacement] = []

    /// ポインタ移動停止からレーザーの消灯 (フェード開始) までの猶予
    /// (v1 の Config.Timing.inactivityThreshold=0.3 と同値)。
    public var inactivityThreshold: TimeInterval = 0.3

    /// レーザー表示開始のデバウンス: この時間以上「連続して」移動が続いて初めて表示する
    /// (タッチパッドに触れただけの偶発的な微小移動では表示しない、実機裁定 0.3 → 0.1)。テスト用に注入可能。
    public var laserShowDebounce: TimeInterval = 0.1

    /// レーザー消灯時のフェードアウト時間 (秒)。即消しではなくスーッと消える体感のための値。
    /// 0.4 は実機で「もう少し早くても良い」(2026-07-11 第 4 ラウンド裁定) → 0.25。テスト用に注入可能。
    public var laserFadeOutDuration: TimeInterval = 0.25

    /// coalesce タイマーの周期 (60Hz = 約16.67ms)。テストで注入できるよう var にしておく。
    public var flushInterval: TimeInterval = 1.0 / 60.0

    /// mouseUp 後のクリックサークル消滅時間 (秒)。テスト用に注入可能。
    public var clickFadeDuration: TimeInterval = 0.3
    /// mouseDown 時のサークル初期不透明度。
    public var clickInitialOpacity: Double = 0.6

    /// フォーカスフラッシュのフェード時間 (秒)。task 指示「~0.5s でフェードアウト」に沿う。
    public var focusFlashDuration: TimeInterval = 0.5
    /// フォーカスフラッシュの初期不透明度。0.6 前後にすることでシステム標準の accent 系ハイライトと
    /// 近い体感になる (実機フィードバックで再調整余地あり)。
    public var focusFlashInitialOpacity: Double = 0.6

    /// 波動の進行時間 (秒) / リング帯幅 (mm) / 初期不透明度。DR-0011 決定 3 起点の実機チューニング値
    /// (第 5 ラウンド: 0.7s は「遅くてウザい」裁定 → 0.35s へ)。
    public var waveDuration: TimeInterval = 0.35
    public var waveBandMM: Double = 30
    public var waveInitialOpacity: Double = 0.5

    private var inactivityWorkItem: DispatchWorkItem?
    /// 現在の連続移動の開始時刻 (systemUptime 秒)。非表示中の移動で記録を開始し、
    /// laserShowDebounce を超えて移動が継続したら表示に昇格する。移動停止で nil に戻る
    /// (= 次の移動はまた新しい連続移動として数え直す)。
    private var movementStartedAt: TimeInterval?
    private var laserFadeTimer: Timer?
    private var pendingState: AppState?
    private var pendingMouseLocation: LogicalPoint?
    /// `.drag` フェーズの point 更新も他の高頻度入力 (state / mouseLocation) と同じ 60Hz coalesce
    /// に合流させる (down/up は体感直結のため即時のまま、drag だけ event-rate 発火だった過去の違反を修正)。
    private var pendingClickDragPoint: LogicalPoint?
    /// 前回 flush の時刻 (systemUptime 秒)。リーディングエッジ判定 (前回から interval 以上
    /// 空いていれば即時反映) に使う。初期値 -∞ 相当で最初の入力は必ず即時反映になる。
    private var lastFlushAt: TimeInterval = -.greatestFiniteMagnitude
    private var flushTimer: Timer?
    private var clickFadeTimer: Timer?
    private var focusFlashFadeTimer: Timer?
    /// 直近で立ち上げた focus flash の generation。次回 apply(state:) 時に state.focusFlash?.generation
    /// と比較し、増えていれば新規発火として立ち上げ直す (同一 displayId でも再発火する)。
    private var lastFocusFlashGeneration: UInt64 = 0
    private var waveTimer: Timer?

    public init(initialState: AppState, initialMouse: LogicalPoint? = nil) {
        self.state = initialState
        self.currentMouseLocation = initialMouse
        // 初期 state 時点で focusFlash が既にセットされていても VM 生成時に「見なかった発火」を
        // 立ち上げないよう、last カウンタを synchronize しておく (通常は 0)。
        self.lastFocusFlashGeneration = initialState.focusFlash?.generation ?? 0
    }

    public func apply(state: AppState) {
        pendingState = state
        scheduleFlush()
    }

    public func apply(mouseLocation: LogicalPoint) {
        pendingMouseLocation = mouseLocation
        scheduleFlush()
    }

    /// リーディング+トレーリングエッジ型スロットルの入口 (第 3 ラウンド裁定「即値で使う一択」)。
    /// - 前回 flush から flushInterval 以上経過 → その場で flush (リーディングエッジ、遅延ゼロ)
    /// - interval 内 → 残り時間の one-shot timer を 1 個だけ仕掛ける (トレーリングエッジ)。
    ///   タイマー稼働中の追加入力は pending 値の上書きだけで済む (中間値は捨てる)
    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastFlushAt
        if elapsed >= flushInterval {
            flush()
            return
        }
        let timer = Timer(timeInterval: flushInterval - elapsed, repeats: false) { [weak self] _ in
            self?.flush()
        }
        flushTimer = timer
        // .common: ウィンドウドラッグ等 (.eventTracking モード) の main run loop 中でもタイマーが
        // 発火するようにする。.default だけだとドラッグ中はタイマーが止まり、coalesce のつもりが
        // 「ドラッグ終了までまとめて 1 回」に化けて元の問題 (ドラッグ中に追従しない) が再発する。
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        lastFlushAt = ProcessInfo.processInfo.systemUptime
        if let s = pendingState {
            pendingState = nil
            applyStateImmediately(s)
        }
        if let loc = pendingMouseLocation {
            pendingMouseLocation = nil
            applyMouseLocationImmediately(loc)
        }
        if let dragPoint = pendingClickDragPoint {
            pendingClickDragPoint = nil
            applyClickDragImmediately(dragPoint)
        }
    }

    private func applyStateImmediately(_ state: AppState) {
        self.state = state
        // state 更新は mouseMoved 以外 (displayConfigurationChanged / calibration / settings) でも
        // 呼ばれるため、位置が実際に変わった時のみ activity として扱う。
        if let cur = state.currentMouse?.point {
            if cur != self.currentMouseLocation {
                self.currentMouseLocation = cur
                markActive()
            }
        }
        // DR-0009: state.focusFlash.generation が前回より進んでいれば新規発火として立ち上げる。
        // 同一 displayId でも generation が進めば再発火する (連続切替時の Cmd-Tab 連打・
        // 同一モニタ内アプリ切替を反映)。generation が変わらない state 更新
        // (displayConfigurationChanged 等) では何もしない。
        if let ff = state.focusFlash, ff.generation != lastFocusFlashGeneration {
            lastFocusFlashGeneration = ff.generation
            startFocusFlash(displayId: ff.displayId)
            startWave(displays: state.displays, displayId: ff.displayId, windowFrame: ff.windowFrame)
        }
    }

    private func applyMouseLocationImmediately(_ mouseLocation: LogicalPoint) {
        if mouseLocation != currentMouseLocation {
            currentMouseLocation = mouseLocation
            markActive()
        }
    }

    /// coalesce された `.drag` point を実際に `clickCircle` へ反映する (60Hz flush からのみ呼ぶ)。
    /// 表示中のサークルが無ければ何もしない (up 後に届いた drag は無視、既存の意図を保持)。
    private func applyClickDragImmediately(_ point: LogicalPoint) {
        guard let current = clickCircle else { return }
        clickCircle = ClickCirclePresentation(point: point, opacity: current.opacity)
    }

    /// プレゼンテーションモード時のクリックイベントを適用する。
    /// - down: 現在の減衰タイマーを止めて initial opacity で表示開始 (即時)
    /// - drag: 既に表示中のサークルがあれば point だけ更新 (opacity 不変)。up 後の drag
    ///   (= clickCircle が nil) は無視 — down を経ていないドラッグはサークル対象外。OS のイベント
    ///   レポートレートに比例した高頻度で飛んでくるため、down/up と違い即時代入せず 60Hz coalesce
    ///   (pendingClickDragPoint + flush) に合流させる (「@Published を event-rate で発火させない」方針)。
    /// - up: opacity を clickFadeDuration にわたって 0 まで減衰、完了で clickCircle=nil。
    ///   減衰開始位置は最後に受け取った point (= down 直後の up ならその point、drag を
    ///   経ていれば最後の drag point)。coalesce 未反映の pending drag point は fade 開始前に
    ///   同期的に反映してから読む (取りこぼし防止)
    public func apply(presentationClick event: PresentationClickEvent) {
        switch event.phase {
        case .down:
            pendingClickDragPoint = nil
            clickFadeTimer?.invalidate()
            clickFadeTimer = nil
            clickCircle = ClickCirclePresentation(point: event.point, opacity: clickInitialOpacity)
        case .drag:
            guard clickCircle != nil else { return }
            pendingClickDragPoint = event.point
            scheduleFlush()
        case .up:
            // fade 開始位置が「最後の drag 位置」になる契約 (仕様コメント上記) を守るため、
            // まだ flush されていない drag point があれば先に同期反映する。
            if let dragPoint = pendingClickDragPoint {
                pendingClickDragPoint = nil
                applyClickDragImmediately(dragPoint)
            }
            clickFadeTimer?.invalidate()
            clickFadeTimer = nil
            guard let current = clickCircle else { return }
            // 減衰: 30ms 刻みで initial opacity / (clickFadeDuration / step) 分ずつ減らす。
            let step: TimeInterval = 0.03
            let ticks = max(1, Int(clickFadeDuration / step))
            let delta = current.opacity / Double(ticks)
            var opacity = current.opacity
            let timer = Timer(timeInterval: step, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                opacity -= delta
                // 2026-07-10 レビュー指摘 minor-6: fade 中でも別ボタンの drag が届き得る
                // (複数ボタン同時押し)。point を up 時点で capture した固定値ではなく毎 tick
                // `clickCircle?.point` を読み直すことで、drag による位置更新を fade が
                // 巻き戻さないようにする (drag が来なければ current.point のまま不変)。
                let point = self.clickCircle?.point ?? current.point
                if opacity <= 0 {
                    self.clickCircle = nil
                    t.invalidate()
                    self.clickFadeTimer = nil
                } else {
                    self.clickCircle = ClickCirclePresentation(point: point, opacity: opacity)
                }
            }
            clickFadeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// プレゼンテーションモード off 遷移時に呼ぶ。減衰中でも即座にサークルを消す。
    /// coalesce 待ちの drag point (`applyClickDragImmediately` は `clickCircle` nil で
    /// no-op のため実害は無いが、次回 on 時に無駄な flush 処理を残さないため) も破棄する。
    public func clearPresentationClick() {
        pendingClickDragPoint = nil
        clickFadeTimer?.invalidate()
        clickFadeTimer = nil
        clickCircle = nil
    }

    /// フォーカスフラッシュを立ち上げてフェードアウトさせる (DR-0009 Phase A)。
    /// state 経由の generation 変化検知から呼ばれる内部関数。
    ///
    /// 減衰は clickCircle 側と同じ pattern: 30ms 刻みで `focusFlashDuration / step` 回に分けて
    /// opacity を減らし、0 に達したら nil に戻す。SwiftUI の暗黙 animation ではなく AppKit Timer で
    /// 明示的に段階更新するのは、キャリブレーション画面表示中の main run loop 占有下でも
    /// 予測可能な速度で減衰させるため (プレゼンテーションクリックと同じ理由)。
    private func startFocusFlash(displayId: String) {
        focusFlashFadeTimer?.invalidate()
        focusFlashFadeTimer = nil
        focusFlash = FocusFlashPresentation(displayId: displayId, opacity: focusFlashInitialOpacity)

        let step: TimeInterval = 0.03
        let ticks = max(1, Int(focusFlashDuration / step))
        let delta = focusFlashInitialOpacity / Double(ticks)
        var opacity = focusFlashInitialOpacity
        let capturedId = displayId
        let timer = Timer(timeInterval: step, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            opacity -= delta
            if opacity <= 0 {
                self.focusFlash = nil
                t.invalidate()
                self.focusFlashFadeTimer = nil
            } else {
                self.focusFlash = FocusFlashPresentation(displayId: capturedId, opacity: opacity)
            }
        }
        focusFlashFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// フォーカス波動 (DR-0011 決定 5)。generation 変化検知で startFocusFlash と併せて立ち上がる。
    /// `displays` から隣接物理レイアウトを構築し `wavePlacements` へ固定 (発火の瞬間のみ再計算、
    /// view 側基準がぶれないようにするため)。震源 displayId の placement が無ければ発火しない
    /// (state 不整合時のみ)。進行は他エフェクトと同じ 30ms 刻み Timer で progress を 0→1 に進める。
    private func startWave(displays: [Display], displayId: String, windowFrame: LogicalRect) {
        waveTimer?.invalidate()
        waveTimer = nil
        let placements = WaveLayout.placements(displays: displays)
        wavePlacements = placements
        guard let epicenterPlacement = placements.first(where: { $0.displayId == displayId }) else {
            wave = nil
            return
        }
        let epicenterMM = epicenterPlacement.toMM(windowFrame)
        let maxDistanceMM = WaveGeometry.maxDistanceMM(epicenter: epicenterMM, placements: placements)
        let (bandMM, initialOpacity) = (waveBandMM, waveInitialOpacity)
        let step: TimeInterval = 0.03
        let ticks = max(1, Int(waveDuration / step))
        let deltaProgress = 1.0 / Double(ticks)
        var progress = 0.0
        func makePresentation() -> WavePresentation {
            .at(progress: progress, epicenterMM: epicenterMM, maxDistanceMM: maxDistanceMM,
                bandMM: bandMM, initialOpacity: initialOpacity)
        }
        wave = makePresentation()
        let timer = Timer(timeInterval: step, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            progress += deltaProgress
            if progress >= 1 {
                self.wave = nil
                t.invalidate()
                self.waveTimer = nil
            } else {
                self.wave = makePresentation()
            }
        }
        waveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// フォーカスフラッシュ機能 off 遷移時に呼ぶ。減衰中でも即座に消し、次回の generation 変化
    /// でも state.focusFlash?.generation との差分検知が正しく行われるよう lastFocusFlashGeneration
    /// は state の値に合わせておく (off 中の発火をカウントし、再 on 時に「見なかった 1 回」を
    /// 再生しないため = 「off の間の発火は捨てる」を明示する)。
    public func clearFocusFlash() {
        focusFlashFadeTimer?.invalidate()
        focusFlashFadeTimer = nil
        focusFlash = nil
        waveTimer?.invalidate()
        waveTimer = nil
        wave = nil
        lastFocusFlashGeneration = state.focusFlash?.generation ?? 0
    }

    /// ポインタ移動 (位置変化) のたびに呼ばれる (スロットル済み ≤60Hz)。
    private func markActive() {
        let now = ProcessInfo.processInfo.systemUptime
        if laserOpacity > 0 {
            // 表示中 (フェード減衰中含む): 直前まで見えていたレーザーの継続なので
            // デバウンスは課さず即フル輝度に復帰する。
            laserFadeTimer?.invalidate()
            laserFadeTimer = nil
            laserOpacity = 1
        } else {
            // 非表示中: 連続移動が laserShowDebounce 継続して初めて表示する
            // (タッチパッドに触れただけの単発的な微小移動では出さない)。
            let startedAt = movementStartedAt ?? now
            movementStartedAt = startedAt
            if now - startedAt >= laserShowDebounce {
                laserOpacity = 1
            }
        }
        // 移動停止の検知 (トレーリングデバウンス): 位置変化が inactivityThreshold 途切れたら停止。
        inactivityWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.movementStopped()
        }
        inactivityWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + inactivityThreshold, execute: item)
    }

    /// 移動停止時: 連続移動の起点をリセットし (次の移動はデバウンスからやり直し)、
    /// 表示中ならフェードアウトを開始する。
    private func movementStopped() {
        movementStartedAt = nil
        guard laserOpacity > 0 else { return }
        laserFadeTimer?.invalidate()
        let step: TimeInterval = 0.03
        let ticks = max(1, Int(laserFadeOutDuration / step))
        let delta = 1.0 / Double(ticks)
        let timer = Timer(timeInterval: step, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let next = self.laserOpacity - delta
            if next <= 0 {
                self.laserOpacity = 0
                t.invalidate()
                self.laserFadeTimer = nil
            } else {
                self.laserOpacity = next
            }
        }
        laserFadeTimer = timer
        // .common: フェード中にウィンドウドラッグ等の .eventTracking モードへ入っても減衰が止まらないように。
        RunLoop.main.add(timer, forMode: .common)
    }
}
