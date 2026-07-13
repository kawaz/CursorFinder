// CalibrationBridge (DR-0008 + DR-0012)
//
// キャリブレーション UI (WKWebView + 純ビュー JS) の Swift↔JS 配線とライフサイクルを提供する。
// DR-0012 で独立ウィンドウ (旧 CalibrationWindowController) を廃止し、設定ウィンドウの
// 「キャリブレーション」タブに `CalibrationView` (NSViewRepresentable) から embed する構成に
// 変更した。本クラスは NSWindow を持たず、`webView: WKWebView` を SwiftUI へ渡す提供型として振る舞う。
//
// 責務:
//   - WKWebView の生成 (userContentController 登録 / preferences / 資産ロード)
//   - 状態 push (60Hz coalesce): runtime.stateDidChange 経由の apply(state:) で呼ばれる
//   - JS → Swift 受信: WKScriptMessageHandler "laserguide" で CalibrationAction を dispatch
//
// 幾何ロジックは Core の `RenderModel.derive` が担い、本クラスは配線と JSON 変換のみ。
import AppKit
import Foundation
import LaserGuideCore
import WebKit

final class CalibrationBridge: NSObject, WKScriptMessageHandler {

    private let runtime: AppRuntime
    let webView: WKWebView
    /// ucc.add(self, name:) は self を強参照する (WKUserContentController → CalibrationBridge)。
    /// teardown で remove しないと bridge / WebView / WebContent プロセスがリークするため
    /// (M-2)、controller への参照を保持しておいて解除時に使う。
    private let userContentController: WKUserContentController

    // 60Hz coalesce: OverlayViewModel と同じ思想で、push を最大 1 フレーム分に間引く。
    // pending の実体は DispatchWorkItem にして、teardown 時に cancel() 可能にする (旧実装は
    // asyncAfter closure に直接 [weak self] を貼るだけだったため teardown 後も 16ms 後の push が
    // 走り、既に破棄された WebView に evaluateJavaScript が発火して警告 / クラッシュを招いた、
    // レビュー M-2 併記の n-4)。
    private var pendingPushItem: DispatchWorkItem?
    private var lastPushedJSON: String?

    init(runtime: AppRuntime) {
        self.runtime = runtime
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        self.userContentController = ucc
        config.userContentController = ucc
        // 開発中の DevTools を有効化 (macOS 13.3+ で public)。
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        ucc.add(self, name: "laserguide")
        self.webView.autoresizingMask = [.width, .height]
        loadCalibrationHTML()
    }

    private func loadCalibrationHTML() {
        guard let url = Self.calibrationIndexURL() else {
            NSLog("[LaserGuide] calibration: index.html not found in Bundle.module nor Bundle.main")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// キャリブレーション UI の `index.html` を、.app 経路 (`Bundle.main.resourceURL/calibration/`)
    /// と SPM 経路 (`Bundle.module`) の両方から探す。旧 CalibrationWindowController.calibrationIndexURL
    /// と同じ検索順・同じ理由 (Bundle.module の生成 property が .app 環境で fatalError しうる件
    /// を回避するため fileExists ベースの main 優先探索を行う)。
    static func calibrationIndexURL() -> URL? {
        if let base = Bundle.main.resourceURL {
            let fallback = base.appendingPathComponent("calibration/index.html")
            if FileManager.default.fileExists(atPath: fallback.path) {
                return fallback
            }
        }
        if let url = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "calibration") {
            return url
        }
        return nil
    }

    // MARK: - Push (Swift → JS)

    /// AppDelegate から呼ばれる state 適用。RenderModel を導出して 60Hz で JS に流す。
    func apply(state: AppState) {
        let model = RenderModel.derive(from: state)
        do {
            let data = try JSONEncoder().encode(model)
            if let s = String(data: data, encoding: .utf8) {
                if s == lastPushedJSON { return }  // 変化なしなら何もしない
                lastPushedJSON = s
                schedulePush()
            }
        } catch {
            NSLog("[LaserGuide] calibration: RenderModel encode failed: \(error)")
        }
    }

    private func schedulePush() {
        if pendingPushItem != nil { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPushItem = nil
            self.pushNow()
        }
        pendingPushItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: item)
    }

    private func pushNow() {
        guard let json = lastPushedJSON else { return }
        guard let data = json.data(using: .utf8) else { return }
        let base64 = data.base64EncodedString()
        let script = """
        (function() {
          try {
            const bin = atob('\(base64)');
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            const text = new TextDecoder('utf-8').decode(bytes);
            const model = JSON.parse(text);
            if (window.__laserguideApplyRender) window.__laserguideApplyRender(model);
          } catch (e) { console.error('push decode failed', e); }
        })();
        """
        webView.evaluateJavaScript(script) { _, error in
            if let error { NSLog("[LaserGuide] calibration: JS push failed: \(error)") }
        }
    }

    // MARK: - JS → Swift

    // swiftlint:disable:next cyclomatic_complexity
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "laserguide" else { return }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            NSLog("[LaserGuide] calibration: invalid message body: \(message.body)")
            return
        }
        switch kind {
        case "calibration.requestInitialRender":
            // M-4: JS boot 完了通知。開いた直後の apply(state:) で lastPushedJSON をセットしたが
            // WebView 未ロード時の evaluateJavaScript で捨てられていた場合、この経路の apply が
            // 同一 JSON の dedupe に食われて初期描画が空のままになる (実測)。dedupe を明示バイパスし、
            // 現在 state を必ず 1 回 push し直す。
            lastPushedJSON = nil
            apply(state: runtime.state)
        case "calibration.dragStart":
            guard let displayId = body["displayId"] as? String else { return }
            runtime.dispatch(.calibration(.dragStart(displayId: displayId)))
        case "calibration.dragMove":
            guard let displayId = body["displayId"] as? String,
                  let pose = body["candidatePose"] as? [String: Any],
                  let candidate = Self.decodePose(pose) else { return }
            runtime.dispatch(.calibration(.dragMove(displayId: displayId, candidatePose: candidate)))
        case "calibration.dragEnd":
            runtime.dispatch(.calibration(.dragEnd))
        case "calibration.commit":
            runtime.dispatch(.calibration(.commit))
        case "calibration.cancel":
            runtime.dispatch(.calibration(.cancel))
        default:
            NSLog("[LaserGuide] calibration: unknown kind: \(kind)")
        }
    }

    private static func decodePose(_ dict: [String: Any]) -> DisplayPose? {
        guard let translate = dict["translate"] as? [String: Any],
              let tx = (translate["x"] as? NSNumber)?.doubleValue,
              let ty = (translate["y"] as? NSNumber)?.doubleValue,
              let sx = (dict["scaleX"] as? NSNumber)?.doubleValue,
              let sy = (dict["scaleY"] as? NSNumber)?.doubleValue,
              sx > 0, sy > 0 else { return nil }
        return DisplayPose(translate: PhysicalPoint(x: tx, y: ty), scaleX: sx, scaleY: sy)
    }

    /// 設定ウィンドウを閉じるとき / タブが破棄されるときに呼ぶ。編集中の candidatePose を捨てて
    /// state を安全な状態に戻す (旧 CalibrationWindowController.windowWillClose と同じ責務)。
    ///
    /// M-2 対応: userContentController に登録した self のハンドラを解除する (これをしないと
    /// controller → bridge → WKWebView の強参照鎖が残り、設定ウィンドウ開閉のたびに WebContent
    /// プロセスが積み上がる)。あわせて n-4: 未発火の pending push を cancel して、破棄された
    /// WebView に evaluateJavaScript が届かないようにする。
    func teardown() {
        pendingPushItem?.cancel()
        pendingPushItem = nil
        userContentController.removeScriptMessageHandler(forName: "laserguide")
        if runtime.state.calibration.draggingDisplayId != nil
            || !runtime.state.calibration.candidatePoses.isEmpty {
            runtime.dispatch(.calibration(.cancel))
        }
        lastPushedJSON = nil
    }
}
