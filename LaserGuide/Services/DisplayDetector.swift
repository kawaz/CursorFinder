// DisplayDetector.swift
import Cocoa
import Combine

/// ディスプレイ検出サービス
class DisplayDetector: ObservableObject {
    static let shared = DisplayDetector()
    
    @Published private(set) var workspace: WorkspaceConfiguration
    
    private let configurationManager = ConfigurationManager.shared
    private var displayChangeObserver: Any?
    
    private init() {
        // 初期ワークスペースを読み込み
        self.workspace = configurationManager.loadOrCreateWorkspace()
        
        NSLog("🖥️ DisplayDetector initialized with \(workspace.displays.count) displays")
    }
    
    /// ディスプレイ変更の監視を開始
    func startMonitoring() {
        guard displayChangeObserver == nil else {
            NSLog("⚠️ DisplayDetector already monitoring")
            return
        }
        
        NSLog("🖥️ DisplayDetector monitoring started")
        
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayChange()
        }
    }
    
    /// 監視を停止
    func stopMonitoring() {
        if let observer = displayChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            displayChangeObserver = nil
            NSLog("🖥️ DisplayDetector monitoring stopped")
        }
    }
    
    /// ディスプレイ変更を処理
    private func handleDisplayChange() {
        NSLog("🔄 Display configuration changed")
        
        // ワークスペースを再読み込み
        workspace = configurationManager.loadOrCreateWorkspace()
        
        NSLog("✅ Workspace reloaded with \(workspace.displays.count) displays")
        
        // 通知を送信
        NotificationCenter.default.post(
            name: Notification.Name("LaserGuide.DisplayConfigurationChanged"),
            object: workspace
        )
    }
    
    /// 手動でワークスペースを再読み込み
    func reloadWorkspace() {
        handleDisplayChange()
    }
    
    deinit {
        stopMonitoring()
    }
}

