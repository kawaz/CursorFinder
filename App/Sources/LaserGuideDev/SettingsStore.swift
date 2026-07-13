// SettingsStore (DR-0012) — 表示チューニングと機能トグルの単一情報源 (App 層)
//
// 設計要点:
// - `DisplaySettings` は Codable な値型で、UserDefaults の単一 key
//   `LaserGuide.v3.displaySettings` に JSON で保存する (workspace キーとは独立、
//   モニタ構成に依存しないアプリ全体設定)
// - Codable は明示的な `decodeIfPresent` 経路で書き、欠落フィールドはデフォルト値で
//   埋める (tolerant decode)。これにより将来のパラメータ追加で古い保存値が破棄されない
// - 色は `RGBAColor` で保持し、JSON では `#RRGGBBAA` の hex 文字列として単一値エンコード
//   (人間可読で、将来 Codable レビュー時に diff が読みやすい)
// - `SettingsStore` は `ObservableObject`。`@Published var settings` の変更で
//   AppDelegate 側の購読が発火し、全 OverlayViewModel に反映される (live apply)
// - reducer / Core には一切影響を与えない (DR-0004 の Elm 系列を汚さない)
import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - RGBAColor

/// 表示チューニングで扱う RGBA 色 (成分は 0.0...1.0 の Double)。
/// JSON では `#RRGGBBAA` の hex 文字列としてエンコードする。
public struct RGBAColor: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Self.parseHex(s) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "RGBAColor must be #RRGGBBAA hex string, got \(s)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hexString)
    }

    /// 「#RRGGBBAA」形式の hex 文字列 (小文字なし、常に 8 桁)。
    public var hexString: String {
        String(
            format: "#%02X%02X%02X%02X",
            Self.clampByte(r), Self.clampByte(g), Self.clampByte(b), Self.clampByte(a))
    }

    private static func clampByte(_ v: Double) -> Int {
        let x = Int((v.isFinite ? v : 0) * 255.0 + 0.5)
        return max(0, min(255, x))
    }

    /// 「#RRGGBBAA」形式の hex を parse。前置きの `#` は必須、8 桁 (RGBA) のみ許容。
    /// 6 桁 (RGB) の互換は敢えて持たない — 保存経路は常に自身の hexString 出力なので 8 桁固定。
    public static func parseHex(_ s: String) -> RGBAColor? {
        guard s.hasPrefix("#") else { return nil }
        let body = String(s.dropFirst())
        guard body.count == 8, let raw = UInt32(body, radix: 16) else { return nil }
        let r = Double((raw >> 24) & 0xff) / 255.0
        let g = Double((raw >> 16) & 0xff) / 255.0
        let b = Double((raw >> 8) & 0xff) / 255.0
        let a = Double(raw & 0xff) / 255.0
        return RGBAColor(r: r, g: g, b: b, a: a)
    }
}

// MARK: - RGBAColor <-> SwiftUI Color

extension RGBAColor {
    /// SwiftUI Color に変換 (ColorPicker binding 用)。
    public var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// SwiftUI Color → RGBAColor。ColorPicker で受け取った値を Store に書き戻す。
    /// P3 等の非 sRGB は sRGB に変換した近似値になる (システム ColorPicker が返す
    /// NSColor の catalog 色域は一般に sRGB で近似可能な範囲に収まる想定)。
    public init(_ color: Color) {
        let ns = NSColor(color)
        let srgb = ns.usingColorSpace(.sRGB) ?? ns
        self.init(
            r: Double(srgb.redComponent),
            g: Double(srgb.greenComponent),
            b: Double(srgb.blueComponent),
            a: Double(srgb.alphaComponent))
    }
}

// MARK: - DisplaySettings

/// 表示チューニング + 機能トグルの永続化スキーマ (JSON エンコード対象)。
///
/// 各フィールドの初期値は現行の `OverlayViewModel` var 初期値・`LaserGeometry` の default
/// 定数・`LaserOverlayView` のハードコード色から引き継ぐ (DR-0012 決定 3、SettingsStore 導入前後で
/// 挙動を変えないため)。
public struct DisplaySettings: Codable, Equatable, Sendable {
    // MARK: 機能トグル (メニューと双方向同期)
    /// 境界ワープ (event tap による swap)。既存メニューの `warpEnabled` を引き継ぐ。
    public var warpEnabled: Bool
    /// プレゼンテーションモード (sharingType=.readOnly + クリック可視化)。
    public var presentationModeEnabled: Bool
    /// フォーカスフラッシュ (DR-0009 Phase A、DR-0011 で波動と併存)。
    public var focusFlashEnabled: Bool

    // MARK: レーザー — タイミング
    /// 表示デバウンス (この時間以上連続移動が続いて初めて表示)。既定 0.1s。
    public var laserShowDebounce: Double
    /// 移動停止からフェード開始までの猶予。既定 0.3s。
    public var inactivityThreshold: Double
    /// フェードアウト時間。既定 0.25s。
    public var laserFadeOutDuration: Double

    // MARK: レーザー — 形状
    /// 角側の底辺半幅 (px)。既定 8.0 (`LaserGeometry.defaultCornerHalfWidth`)。
    public var laserCornerHalfWidth: Double
    /// ポインタ周辺の「レーザーが届かない」半径 (px)。角→ポインタ方向に沿って target からこの距離だけ
    /// 手前で頂点を作る (DR-0013 決定 3、旧 defaultStandoffRatio/min/max クランプを廃止して固定 px 化)。
    public var laserStandoffPx: Double

    // MARK: レーザー — グラデーション色 (角→ポインタ側の 2 stop、DR-0013)
    /// 角側 (location=0.0) の色。既定 red opacity 0.85。
    public var laserColorNear: RGBAColor
    /// ポインタ側 (location=1.0) の色。既定 white opacity 0.35。
    public var laserColorFar: RGBAColor

    // MARK: フォーカスフラッシュ (ウィンドウ枠、DR-0013)
    /// ウィンドウ枠ハイライトの持続時間。既定 0.5s。
    public var focusFlashDuration: Double
    /// ウィンドウ枠ハイライトの初期不透明度 (フェード開始点)。既定 0.6。
    public var focusFlashInitialOpacity: Double
    /// ウィンドウ枠ハイライトの色 (opacity は上の initial で乗算する形になる)。既定 systemBlue 相当。
    public var focusFlashColor: RGBAColor

    // MARK: フォーカス波動 (DR-0011)
    /// 波動の進行時間。既定 0.35s (第 5 ラウンド実機裁定)。
    public var waveDuration: Double
    /// リング帯幅 (mm)。既定 30mm (DR-0011)。
    public var waveBandMM: Double
    /// 波動の初期不透明度。既定 0.5。
    public var waveInitialOpacity: Double
    /// 波動リングの色。既定 cyan 相当。
    public var waveColor: RGBAColor

    /// 全フィールドのデフォルト値。
    ///
    /// **色の裁定 (DR-0012 決定 6、レビュー M-3 由来)**: 従来描画で使っていた SwiftUI semantic
    /// color (Color.red / Color.white / Color.blue / Color.cyan) は appearance 適応する動的色で、
    /// hex 量子化を経る保存経路と往復一致しない。ここでは **semantic color の実測 sRGB 近似を
    /// 固定値として採用**する (light/dark 適応は失うが、ユーザが ColorPicker で自由に変更できる
    /// ため許容)。opacity 成分は現行のグラデ stop 値 (角 0.85 / ポインタ側 0.35) を維持する。
    ///
    ///   Color.red    ≒ #FF4245  (グラデ角側、opacity 0.85 → alpha 0xD9)
    ///   Color.white  =  #FFFFFF  (グラデポインタ側、opacity 0.35 → alpha 0x59)
    ///   Color.blue   ≒ #0091FF  (ウィンドウ枠、opacity 1.00)
    ///   Color.cyan   ≒ #3CD3FE  (波動、        opacity 1.00)
    ///
    /// タイミング系のデフォルトも本フィールドから参照される (OverlayViewModel の対応 var 初期化子で
    /// `DisplaySettings.defaults.laserShowDebounce` を読む形。二重管理の防止、レビュー n-6)。
    ///
    /// **DR-0013 変更**: mid 色 / tipHalfWidth を廃止 (3 stop → 2 stop、頂点 1 点集約)、
    /// 消える半径は `laserStandoffPx` (px 固定値、既定 40) に統一。
    ///
    /// hex リテラルは private helper `hexLiteral(_:)` を通す (= force-unwrap を隠す、8 桁固定を保証、
    /// 不正リテラルはビルド起動時に fatalError で早期検出)。
    public static let defaults = DisplaySettings(
        warpEnabled: true,
        presentationModeEnabled: false,
        focusFlashEnabled: false,
        laserShowDebounce: 0.1,
        inactivityThreshold: 0.3,
        laserFadeOutDuration: 0.25,
        laserCornerHalfWidth: 8.0,
        laserStandoffPx: 40.0,
        laserColorNear: hexLiteral("#FF4245D9"),
        laserColorFar: hexLiteral("#FFFFFF59"),
        focusFlashDuration: 0.5,
        focusFlashInitialOpacity: 0.6,
        focusFlashColor: hexLiteral("#0091FFFF"),
        waveDuration: 0.35,
        waveBandMM: 30.0,
        waveInitialOpacity: 0.5,
        waveColor: hexLiteral("#3CD3FEFF"))

    /// 定数リテラルとして 8 桁 hex を parse する内部ヘルパ。parse 失敗はコード内の typo なので
    /// 開発時に即座に検出したい (fatalError)。force-unwrap を型内に閉じ込めて defaults の可読性を保つ。
    private static func hexLiteral(_ s: String) -> RGBAColor {
        guard let c = RGBAColor.parseHex(s) else {
            fatalError("DisplaySettings.hexLiteral: invalid #RRGGBBAA literal \(s)")
        }
        return c
    }

    /// tolerant decode: 未知 (欠落) フィールドはデフォルト値で埋める。将来のパラメータ追加で
    /// 古い保存 JSON が破棄されないようにするための必須設計 (DR-0012 検証の輪郭 1)。
    ///
    /// **割り切り (レビュー m-3)**: フィールド単位の fallback は「欠落キー」に対してのみ効き、
    /// 「キーは存在するが型が壊れている」ケースでは全 decode が throw し、`SettingsStore.load` の
    /// catch で全 defaults にフォールバックする → 次回保存で他フィールドの正常値も上書きされて消える。
    /// フィールドごとに個別 do/catch を書くと Codable ボイラープレートが 20 倍近くに膨らむため、
    /// **Phase 1 は「欠落は寛容 / 型破損は全戻り」の割り切り**を採用する。実運用では JSON 破損は
    /// 手動編集以外で起きにくく、起きても ColorPicker / Slider で再調整できるコストは低い。
    /// フィールド単位 fallback が必要になる兆候 (= 破損報告) が出たら Phase 2 で書き足す。
    ///
    /// **DR-0013 廃止フィールド**: `laserColorMid` / `laserTipHalfWidth` は decode 側で読まない
    /// (旧 JSON にキーが残っていても Codable の未知キー無視で自然に捨てられる)。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        self.warpEnabled = try c.decodeIfPresent(Bool.self, forKey: .warpEnabled) ?? d.warpEnabled
        self.presentationModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .presentationModeEnabled) ?? d.presentationModeEnabled
        self.focusFlashEnabled = try c.decodeIfPresent(Bool.self, forKey: .focusFlashEnabled) ?? d.focusFlashEnabled
        self.laserShowDebounce = try c.decodeIfPresent(Double.self, forKey: .laserShowDebounce) ?? d.laserShowDebounce
        self.inactivityThreshold = try c.decodeIfPresent(Double.self, forKey: .inactivityThreshold) ?? d.inactivityThreshold
        self.laserFadeOutDuration = try c.decodeIfPresent(Double.self, forKey: .laserFadeOutDuration) ?? d.laserFadeOutDuration
        self.laserCornerHalfWidth = try c.decodeIfPresent(Double.self, forKey: .laserCornerHalfWidth) ?? d.laserCornerHalfWidth
        self.laserStandoffPx = try c.decodeIfPresent(Double.self, forKey: .laserStandoffPx) ?? d.laserStandoffPx
        self.laserColorNear = try c.decodeIfPresent(RGBAColor.self, forKey: .laserColorNear) ?? d.laserColorNear
        self.laserColorFar = try c.decodeIfPresent(RGBAColor.self, forKey: .laserColorFar) ?? d.laserColorFar
        self.focusFlashDuration = try c.decodeIfPresent(Double.self, forKey: .focusFlashDuration) ?? d.focusFlashDuration
        self.focusFlashInitialOpacity = try c.decodeIfPresent(Double.self, forKey: .focusFlashInitialOpacity) ?? d.focusFlashInitialOpacity
        self.focusFlashColor = try c.decodeIfPresent(RGBAColor.self, forKey: .focusFlashColor) ?? d.focusFlashColor
        self.waveDuration = try c.decodeIfPresent(Double.self, forKey: .waveDuration) ?? d.waveDuration
        self.waveBandMM = try c.decodeIfPresent(Double.self, forKey: .waveBandMM) ?? d.waveBandMM
        self.waveInitialOpacity = try c.decodeIfPresent(Double.self, forKey: .waveInitialOpacity) ?? d.waveInitialOpacity
        self.waveColor = try c.decodeIfPresent(RGBAColor.self, forKey: .waveColor) ?? d.waveColor
    }

    // 通常 init (直接値を渡すため)
    public init(
        warpEnabled: Bool,
        presentationModeEnabled: Bool,
        focusFlashEnabled: Bool,
        laserShowDebounce: Double,
        inactivityThreshold: Double,
        laserFadeOutDuration: Double,
        laserCornerHalfWidth: Double,
        laserStandoffPx: Double,
        laserColorNear: RGBAColor,
        laserColorFar: RGBAColor,
        focusFlashDuration: Double,
        focusFlashInitialOpacity: Double,
        focusFlashColor: RGBAColor,
        waveDuration: Double,
        waveBandMM: Double,
        waveInitialOpacity: Double,
        waveColor: RGBAColor
    ) {
        self.warpEnabled = warpEnabled
        self.presentationModeEnabled = presentationModeEnabled
        self.focusFlashEnabled = focusFlashEnabled
        self.laserShowDebounce = laserShowDebounce
        self.inactivityThreshold = inactivityThreshold
        self.laserFadeOutDuration = laserFadeOutDuration
        self.laserCornerHalfWidth = laserCornerHalfWidth
        self.laserStandoffPx = laserStandoffPx
        self.laserColorNear = laserColorNear
        self.laserColorFar = laserColorFar
        self.focusFlashDuration = focusFlashDuration
        self.focusFlashInitialOpacity = focusFlashInitialOpacity
        self.focusFlashColor = focusFlashColor
        self.waveDuration = waveDuration
        self.waveBandMM = waveBandMM
        self.waveInitialOpacity = waveInitialOpacity
        self.waveColor = waveColor
    }

    // MARK: タブ単位リセット (SettingsView の「デフォルトに戻す」で使う)

    /// 「一般」タブに属するフィールドをデフォルト値に戻した新しい値を返す (機能トグル)。
    public func resettingGeneral() -> DisplaySettings {
        var copy = self
        copy.warpEnabled = Self.defaults.warpEnabled
        copy.presentationModeEnabled = Self.defaults.presentationModeEnabled
        copy.focusFlashEnabled = Self.defaults.focusFlashEnabled
        return copy
    }

    /// 「レーザー」タブ (色 + 太さ + タイミング + 消える半径) をデフォルトに戻す。
    public func resettingLaser() -> DisplaySettings {
        var copy = self
        copy.laserShowDebounce = Self.defaults.laserShowDebounce
        copy.inactivityThreshold = Self.defaults.inactivityThreshold
        copy.laserFadeOutDuration = Self.defaults.laserFadeOutDuration
        copy.laserCornerHalfWidth = Self.defaults.laserCornerHalfWidth
        copy.laserStandoffPx = Self.defaults.laserStandoffPx
        copy.laserColorNear = Self.defaults.laserColorNear
        copy.laserColorFar = Self.defaults.laserColorFar
        return copy
    }

    /// 「フォーカスフラッシュ」タブ (ウィンドウ枠 + 波動) をデフォルトに戻す。
    public func resettingFocusFlash() -> DisplaySettings {
        var copy = self
        copy.focusFlashDuration = Self.defaults.focusFlashDuration
        copy.focusFlashInitialOpacity = Self.defaults.focusFlashInitialOpacity
        copy.focusFlashColor = Self.defaults.focusFlashColor
        copy.waveDuration = Self.defaults.waveDuration
        copy.waveBandMM = Self.defaults.waveBandMM
        copy.waveInitialOpacity = Self.defaults.waveInitialOpacity
        copy.waveColor = Self.defaults.waveColor
        return copy
    }
}

// MARK: - SettingsStore

/// 表示チューニングと機能トグルの単一情報源 (App 層 ObservableObject)。
///
/// 変更するたびに UserDefaults へ JSON 保存する。購読側 (AppDelegate) は `$settings` を
/// Combine で購読し、全 OverlayViewModel と各種機能配線に反映する (live apply)。
public final class SettingsStore: ObservableObject {
    /// UserDefaults の保存 key (DR-0012 決定 2: workspace とは独立の全体設定)。
    public static let userDefaultsKey = "LaserGuide.v3.displaySettings"

    /// 現在の設定値。SwiftUI ColorPicker/Slider から書き戻す + AppDelegate 購読で
    /// 全 VM へ反映するための単一 source。
    @Published public var settings: DisplaySettings {
        didSet {
            // 変更のたびに保存する (体感遅延は最大 60Hz のスライダ操作で 60 回/秒の write
            // が発生するが、UserDefaults は in-memory キャッシュを持つため実測問題無し。
            // 気になれば debounce を後付けする、Phase 1 は shortest path)。
            save(settings, to: defaults)
        }
    }

    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.settings = Self.load(from: userDefaults)
    }

    /// 保存 JSON を読む。失敗 (未保存 / decode 失敗) はデフォルト値を返す。
    /// tolerant decode により古いバージョンの JSON でも新規パラメータはデフォルトで補完される。
    public static func load(from defaults: UserDefaults) -> DisplaySettings {
        guard let data = defaults.data(forKey: userDefaultsKey) else { return .defaults }
        do {
            return try JSONDecoder().decode(DisplaySettings.self, from: data)
        } catch {
            NSLog("[LaserGuide] SettingsStore: decode failed, using defaults: \(error)")
            return .defaults
        }
    }

    private func save(_ settings: DisplaySettings, to defaults: UserDefaults) {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: Self.userDefaultsKey)
        } catch {
            NSLog("[LaserGuide] SettingsStore: encode failed: \(error)")
        }
    }
}

// SettingsSideEffects / applySettingsCore / DisplaySettings.applyDisplayParameters(to:) は
// SettingsApplication.swift に移動 (レビュー n-5: file_length 抑止解消のためのファイル分割)。
