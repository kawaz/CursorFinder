// PhysicalLayoutView.swift
import SwiftUI
import SpriteKit

/// 物理配置キャリブレーション画面
struct PhysicalLayoutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displays: [Display] = []
    @State private var originalDisplays: [Display] = []
    @State private var configurationKey: String = ""

    /// SpriteKitシーン
    private var scene: PhysicalLayoutScene {
        let scene = PhysicalLayoutScene()
        scene.scaleMode = .resizeFill
        scene.displays = displays
        scene.onDisplaysChanged = { newDisplays in
            displays = newDisplays
        }
        return scene
    }

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            headerView

            // メインコンテンツ
            HStack(spacing: 0) {
                // 左: 論理配置（参考表示）
                logicalPane
                    .frame(maxWidth: .infinity)

                Divider()

                // 右: 物理配置（SpriteKit）
                physicalPane
                    .frame(maxWidth: .infinity)
            }
            .padding()

            Divider()

            // フッター
            footerView
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            loadConfiguration()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("物理配置キャリブレーション")
                .font(.title2)
                .fontWeight(.bold)

            Text("右側のディスプレイをドラッグして実際の机上の配置に合わせてください")
                .font(.caption)
                .foregroundColor(.secondary)

            if !configurationKey.isEmpty {
                Text("設定: \(configurationKey)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Logical Pane

    private var logicalPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("論理配置")
                    .font(.headline)
                Text("(macOS設定)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            LogicalLayoutCanvas(displays: displays)
                .background(Color.black.opacity(0.03))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Text("システム設定 > ディスプレイ の配置")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("設定を開く") {
                    openDisplaySettings()
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
    }

    // MARK: - Physical Pane

    private var physicalPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("物理配置")
                    .font(.headline)
                Text("(ドラッグで編集)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            SpriteView(scene: scene)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Text("単位: mm（ミリメートル）")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("デフォルトに戻す") {
                resetToDefault()
            }

            Spacer()

            Button("キャンセル") {
                displays = originalDisplays
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("保存") {
                saveConfiguration()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Actions

    private func loadConfiguration() {
        let config = ConfigurationManager.shared.loadOrCreateWorkspace()

        configurationKey = config.configurationKey
        displays = config.displays
        originalDisplays = config.displays

        NSLog("📐 Loaded \(displays.count) displays for calibration")
    }

    private func saveConfiguration() {
        var config = ConfigurationManager.shared.loadOrCreateWorkspace()

        // 物理座標を更新
        for display in displays {
            if let index = config.displays.firstIndex(where: { $0.id == display.id }) {
                config.displays[index].coordinates.physical = display.coordinates.physical
            }
        }

        // 保存
        ConfigurationManager.shared.saveWorkspace(config)
        originalDisplays = displays

        NSLog("📐 Saved physical layout calibration")
    }

    private func resetToDefault() {
        // 論理配置を元に物理配置を再計算（簡易版）
        displays = originalDisplays
        NSLog("📐 Reset to default layout")
    }

    private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Logical Layout Canvas (SwiftUI Canvas)

/// 論理配置を表示するキャンバス（読み取り専用）
struct LogicalLayoutCanvas: View {
    let displays: [Display]

    var body: some View {
        Canvas { context, size in
            guard !displays.isEmpty else { return }

            let bounds = logicalBounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            // スケール計算
            let margin: CGFloat = 30
            let availableWidth = size.width - margin * 2
            let availableHeight = size.height - margin * 2
            let scale = min(availableWidth / bounds.width, availableHeight / bounds.height)

            // オフセット（中央配置）
            let offsetX = margin + (availableWidth - bounds.width * scale) / 2
            let offsetY = margin + (availableHeight - bounds.height * scale) / 2

            // ディスプレイを描画
            for (index, display) in displays.enumerated() {
                let logical = display.coordinates.logical
                let color = displayColor(for: index)

                // 座標変換（Y軸反転）
                let x = offsetX + (logical.position.x - bounds.minX) * scale
                let y = offsetY + (bounds.maxY - logical.position.y - logical.size.height) * scale
                let width = logical.size.width * scale
                let height = logical.size.height * scale

                let rect = CGRect(x: x, y: y, width: width, height: height)

                // 背景
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.2)))

                // 枠線
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: 2)

                // ラベル
                let text = Text(display.display.name)
                    .font(.caption)
                    .foregroundColor(.white)
                context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
    }

    private var logicalBounds: CGRect {
        guard !displays.isEmpty else { return .zero }

        let minX = displays.map { $0.coordinates.logical.position.x }.min() ?? 0
        let minY = displays.map { $0.coordinates.logical.position.y }.min() ?? 0
        let maxX = displays.map { $0.coordinates.logical.position.x + $0.coordinates.logical.size.width }.max() ?? 0
        let maxY = displays.map { $0.coordinates.logical.position.y + $0.coordinates.logical.size.height }.max() ?? 0

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func displayColor(for index: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .green, .purple, .red, .cyan]
        return colors[index % colors.count]
    }
}

// MARK: - Preview

#Preview {
    PhysicalLayoutView()
}
