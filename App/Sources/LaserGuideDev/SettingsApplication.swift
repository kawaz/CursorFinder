// SettingsApplication (DR-0012)
//
// SettingsStore に値を書き込んだあと、その値を OverlayViewModel / 機能配線 / メニューへ実際に
// 反映する部分を集約する。SettingsStore.swift 側は「値の永続化」に責務を絞り、本ファイルは
// 「値の live apply とテスト可能な副作用ハンドリング」を持つ。
//
// - `DisplaySettings.applyDisplayParameters(to:)`: 1 VM への表示パラメータ反映 (色 / 太さ /
//   タイミング / 波動パラメータ)
// - `SettingsSideEffects`: 機能トグル副作用の注入型 (レビュー m-5、closure ベースなので
//   テスト時 mock 差替えが容易)
// - `applySettingsCore(previous:current:effects:)`: 差分検知と副作用フックの呼び出しを
//   テスト可能な自由関数として切り出したもの (AppDelegate.applySettings が薄い adapter に
//   なる根拠)
import Foundation

// MARK: - Settings side effects (テスト可能な形の副作用注入)

/// DR-0012 の live apply で叩く副作用のフック集合 (レビュー m-5)。
/// AppDelegate 実運用時は各 closure に実装 (`tap.start/stop` / observer 起動 / メニュー state 更新等) を
/// 渡す。テストでは closure に「呼ばれた事実と引数を記録するだけの mock」を差し込み、`applySettingsCore`
/// の分岐 (差分検知 / 新値で判断 / 全 VM へ再適用) を副作用フックのシグナルで検証する。
///
/// **必ず新値 (`settings`) を受ける形にしている理由 (レビュー C-1)**: Combine の `@Published` は
/// `willSet` タイミングで sink に emit する仕様のため、sink 内から自身の `settingsStore.settings`
/// を読むと旧値が返る。副作用側で「computed mirror」を暗黙参照する経路を作らないよう、フック
/// シグネチャで settings を必ず引数として受ける。
public struct SettingsSideEffects {
    /// warp 分岐が変化したときに呼ぶ (start / stop の実行はここから)。
    public var setWarpEnabled: (Bool) -> Void
    /// プレゼンテーションモード分岐が変化したときに呼ぶ。settings 全体を渡すのは、将来
    /// presentation 側で色などの追加設定を参照する余地を残すため (Phase 1 では on/off のみ使用)。
    public var applyPresentationMode: (DisplaySettings) -> Void
    /// フォーカスフラッシュ分岐が変化したときに呼ぶ。同上。
    public var applyFocusFlash: (DisplaySettings) -> Void
    /// メニュー item の checked state を settings 値に合わせて反映する。
    public var updateMenuStates: (DisplaySettings) -> Void
    /// 全 OverlayViewModel に対して `settings.applyDisplayParameters(to:)` を実行する
    /// (色 / 太さ / タイミング / 波動パラメータ)。
    public var applyDisplayParametersToAllViewModels: (DisplaySettings) -> Void

    public init(
        setWarpEnabled: @escaping (Bool) -> Void,
        applyPresentationMode: @escaping (DisplaySettings) -> Void,
        applyFocusFlash: @escaping (DisplaySettings) -> Void,
        updateMenuStates: @escaping (DisplaySettings) -> Void,
        applyDisplayParametersToAllViewModels: @escaping (DisplaySettings) -> Void
    ) {
        self.setWarpEnabled = setWarpEnabled
        self.applyPresentationMode = applyPresentationMode
        self.applyFocusFlash = applyFocusFlash
        self.updateMenuStates = updateMenuStates
        self.applyDisplayParametersToAllViewModels = applyDisplayParametersToAllViewModels
    }
}

/// DR-0012 live apply の核ロジック (レビュー m-5 でテスト可能にするため独立関数化)。
///
/// - `previous == nil` のときは「初回適用」= トグル差分は全て「変化あり」扱いとして 1 回ずつ発火する
///   (起動直後に永続化 OFF を必ず適用する経路を確保するため、レビュー C-2 の下敷き)。
/// - **副作用は全て新値 (`current`) を引数として渡す**。旧実装のように AppDelegate の computed mirror
///   (`self.warpEnabled` = `settingsStore.settings.warpEnabled`) を暗黙に読むと willSet 中の stale
///   read で 1 周遅れになる (C-1)。ここで settings を明示的に配ることで stale read を構造的に排除。
public func applySettingsCore(
    previous: DisplaySettings?,
    current: DisplaySettings,
    effects: SettingsSideEffects
) {
    // 1) 表示パラメータ (色 / 太さ / タイミング) は毎回全 VM に再適用 (差分検知の必要なし、
    //    stored property への代入は idempotent なので低頻度呼び出しでは無害)。
    effects.applyDisplayParametersToAllViewModels(current)

    // 2) 機能トグルは差分検知で 1 回だけ副作用を発火。previous=nil (= 起動直後の初回適用) では
    //    全て発火する扱い (previous?.x != current.x が nil != false でも true になる Swift の
    //    optional 比較挙動により、自動的にこの意味になる)。
    if previous?.warpEnabled != current.warpEnabled {
        effects.setWarpEnabled(current.warpEnabled)
    }
    if previous?.presentationModeEnabled != current.presentationModeEnabled {
        effects.applyPresentationMode(current)
    }
    if previous?.focusFlashEnabled != current.focusFlashEnabled {
        effects.applyFocusFlash(current)
    }

    // 3) メニューは毎回同期 (差分検知しない — トグル ON→ON でも state を再セットして無害)。
    effects.updateMenuStates(current)
}

// MARK: - Live apply

extension DisplaySettings {
    /// SettingsStore の値を 1 つの OverlayViewModel に反映する (DR-0012 live apply)。
    /// AppDelegate の購読ハンドラは overlay ごとに本関数を呼ぶ。テスト側は同一関数を直接
    /// 呼び出して VM の var への反映を検証する (private な AppDelegate.applySettings に依存しない)。
    /// 対象は「色 / 太さ / タイミング / 波動パラメータ」= reducer に影響しない描画関連のみ。
    /// 機能トグル (warp / presentationMode / focusFlash) は tap / observer / sharingType 側の副作用
    /// を伴うので本関数の責務外 (AppDelegate.applySettings で個別に扱う)。
    public func applyDisplayParameters(to vm: OverlayViewModel) {
        vm.laserShowDebounce = laserShowDebounce
        vm.inactivityThreshold = inactivityThreshold
        vm.laserFadeOutDuration = laserFadeOutDuration
        vm.laserCornerHalfWidth = laserCornerHalfWidth
        vm.laserStandoffPx = laserStandoffPx
        vm.laserColorNear = laserColorNear
        vm.laserColorFar = laserColorFar
        vm.focusFlashDuration = focusFlashDuration
        vm.focusFlashInitialOpacity = focusFlashInitialOpacity
        vm.focusFlashColor = focusFlashColor
        vm.waveDuration = waveDuration
        vm.waveBandMM = waveBandMM
        vm.waveInitialOpacity = waveInitialOpacity
        vm.waveColor = waveColor
    }
}
