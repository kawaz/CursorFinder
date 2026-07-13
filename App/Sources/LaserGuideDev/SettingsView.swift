// SettingsView (DR-0012) — SwiftUI ネイティブの設定 TabView
//
// 4 タブ構成 (一般 / レーザー / フォーカスフラッシュ / キャリブレーション)。
// 数値は Slider + 現在値表示 (単位付き)、色は ColorPicker、タブ単位の「デフォルトに戻す」ボタン。
//
// このファイルは UI 層のみで、ロジックは SettingsStore と CalibrationBridge に閉じている。
// SwiftUI View 自体の描画テストは実機確認に委ね、SettingsStore 側 (encode/decode/tolerant/reset)
// と AppDelegate 配線 (live apply) を単体テストする。
import SwiftUI
import WebKit

/// SettingsView が保持する初期タブ / タブ切替通知の識別子。
public enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case laser
    case focusFlash
    case calibration

    var label: String {
        switch self {
        case .general: return "一般"
        case .laser: return "レーザー"
        case .focusFlash: return "フォーカスフラッシュ"
        case .calibration: return "キャリブレーション"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let calibrationView: CalibrationTabView
    @State private var selectedTab: SettingsTab

    init(store: SettingsStore, calibrationView: CalibrationTabView, initialTab: SettingsTab) {
        self.store = store
        self.calibrationView = calibrationView
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(store: store)
                .tabItem { Label(SettingsTab.general.label, systemImage: "gearshape") }
                .tag(SettingsTab.general)

            LaserSettingsTab(store: store)
                .tabItem { Label(SettingsTab.laser.label, systemImage: "scope") }
                .tag(SettingsTab.laser)

            FocusFlashSettingsTab(store: store)
                .tabItem { Label(SettingsTab.focusFlash.label, systemImage: "sparkles") }
                .tag(SettingsTab.focusFlash)

            calibrationView
                .tabItem { Label(SettingsTab.calibration.label, systemImage: "rectangle.on.rectangle") }
                .tag(SettingsTab.calibration)
        }
        .padding()
        .frame(minWidth: 1000, minHeight: 640)
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.selectTabNotification)) { note in
            if let tab = note.object as? SettingsTab { selectedTab = tab }
        }
    }
}

// MARK: - タブ本体

private struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("機能") {
                Toggle("境界ワープ", isOn: $store.settings.warpEnabled)
                Toggle("プレゼンテーションモード", isOn: $store.settings.presentationModeEnabled)
                Toggle("フォーカスフラッシュ", isOn: $store.settings.focusFlashEnabled)
            }
            Section {
                Button("このタブをデフォルトに戻す") { store.settings = store.settings.resettingGeneral() }
            }
        }
        .padding()
    }
}

private struct LaserSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            Form {
                Section("タイミング") {
                    SliderRow(label: "表示デバウンス", unit: "s", range: 0...1, step: 0.05,
                              value: $store.settings.laserShowDebounce)
                    SliderRow(label: "非アクティブ非表示閾値", unit: "s", range: 0.1...2.0, step: 0.05,
                              value: $store.settings.inactivityThreshold)
                    SliderRow(label: "フェードアウト時間", unit: "s", range: 0...1, step: 0.05,
                              value: $store.settings.laserFadeOutDuration)
                }
                Section("形状 (px)") {
                    SliderRow(label: "角側半幅", unit: "px", range: 1...32, step: 0.5,
                              value: $store.settings.laserCornerHalfWidth)
                    SliderRow(label: "頂点辺半幅", unit: "px", range: 0.25...8, step: 0.25,
                              value: $store.settings.laserTipHalfWidth)
                }
                Section("グラデーション色") {
                    RGBAColorRow(label: "角側", color: $store.settings.laserColorNear)
                    RGBAColorRow(label: "中央", color: $store.settings.laserColorMid)
                    RGBAColorRow(label: "ポインタ側", color: $store.settings.laserColorFar)
                }
                Section {
                    Button("このタブをデフォルトに戻す") { store.settings = store.settings.resettingLaser() }
                }
            }
            .padding()
        }
    }
}

private struct FocusFlashSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        ScrollView {
            Form {
                Section("モニタ縁") {
                    SliderRow(label: "持続時間", unit: "s", range: 0.1...2.0, step: 0.05,
                              value: $store.settings.focusFlashDuration)
                    SliderRow(label: "初期不透明度", unit: "", range: 0...1, step: 0.05,
                              value: $store.settings.focusFlashInitialOpacity)
                    RGBAColorRow(label: "色", color: $store.settings.focusFlashColor)
                }
                Section("波動 (DR-0011)") {
                    SliderRow(label: "進行時間", unit: "s", range: 0.1...2.0, step: 0.05,
                              value: $store.settings.waveDuration)
                    SliderRow(label: "帯幅", unit: "mm", range: 5...100, step: 1,
                              value: $store.settings.waveBandMM)
                    SliderRow(label: "初期不透明度", unit: "", range: 0...1, step: 0.05,
                              value: $store.settings.waveInitialOpacity)
                    RGBAColorRow(label: "色", color: $store.settings.waveColor)
                }
                Section {
                    Button("このタブをデフォルトに戻す") { store.settings = store.settings.resettingFocusFlash() }
                }
            }
            .padding()
        }
    }
}

// MARK: - 共通コントロール

/// Slider + label + 現在値表示 + 単位ラベルの 1 行 (数値パラメータ全般で使い回す)。
private struct SliderRow: View {
    let label: String
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label).frame(minWidth: 180, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            // 現在値は Slider 直後に固定幅で並べる (値が動いても行がガタつかないよう width 固定)。
            Text("\(formatted) \(unit)").monospacedDigit().frame(width: 80, alignment: .trailing)
        }
    }

    private var formatted: String {
        // step が整数刻みなら 0 桁、それ以外は 2 桁で四捨五入。
        if step == floor(step) { return String(format: "%.0f", value) }
        return String(format: "%.2f", value)
    }
}

/// RGBAColor 用の 1 行: ラベル + ColorPicker + hex 表示 (アルファ込みは ColorPicker が扱う)。
private struct RGBAColorRow: View {
    let label: String
    @Binding var color: RGBAColor

    var body: some View {
        HStack {
            Text(label).frame(minWidth: 180, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { color.swiftUIColor },
                set: { color = RGBAColor($0) }
            ), supportsOpacity: true)
            .labelsHidden()
            Text(color.hexString).monospacedDigit().frame(width: 100, alignment: .trailing)
        }
    }
}

// MARK: - CalibrationTabView (NSViewRepresentable)

/// キャリブレーションタブ本体。CalibrationBridge が保持する WKWebView をそのまま表示する。
/// NSViewRepresentable なので macOS 標準の SwiftUI レイアウト経路に乗り、他タブと同じ frame /
/// autoresize を共有する。teardown は SettingsWindowController.windowWillClose に集約。
struct CalibrationTabView: NSViewRepresentable {
    let bridge: CalibrationBridge

    func makeNSView(context: Context) -> WKWebView {
        bridge.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 状態同期は AppDelegate → SettingsWindowController.applyCalibrationState 経由で
        // bridge.apply(state:) を呼ぶルートに集約 (SwiftUI の update パスでは行わない、
        // JSON 変換コストを SwiftUI 再評価と切り離すため)。
    }
}
