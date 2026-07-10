// CalibrationWindowController (DR-0008: WKWebView + JS を純 view として使う)
//
// - Swift → JS: state 購読 → RenderModel を導出 → 60Hz coalesce で evaluateJavaScript push
// - JS → Swift: WKScriptMessageHandler "laserguide" で CalibrationAction を受ける
// - 資産は Bundle.module 経由で `Resources/calibration/{index,main}.{html,js}` を loadFileURL
//
// 幾何ロジックは Core (RenderModel.derive) が担い、このクラスは配線と JSON 変換のみ。
import AppKit
import Foundation
import LaserGuideCore
import WebKit

final class CalibrationWindowController: NSObject, NSWindowDelegate, WKScriptMessageHandler {

    private let runtime: AppRuntime
    private var window: NSWindow?
    private var webView: WKWebView?

    // 60Hz coalesce: OverlayViewModel と同じ思想で、push を最大 1 フレーム分に間引く。
    // WKWebView の evaluateJavaScript は main queue 前提。
    private var pendingPush: Bool = false
    private var lastPushedJSON: String?

    init(runtime: AppRuntime) {
        self.runtime = runtime
    }

    // MARK: - Show

    /// 既に開いていれば前面に、無ければ新規生成して開く。
    ///
    /// 2026-07-10 実機フィードバック第 2 ラウンド #1: LSUIElement=true (accessory app、
    /// status bar のみでドック無し) の環境ではウィンドウが自動的に最前面へ来ないことがある。
    /// activate → makeKeyAndOrderFront → orderFrontRegardless の順で明示的に前面化を保証する。
    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            return
        }
        let contentRect = NSRect(x: 0, y: 0, width: 1000, height: 640)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let w = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        w.title = "LaserGuide キャリブレーション"
        w.delegate = self
        w.isReleasedWhenClosed = false
        // contentRect の origin (0,0) のまま出すと画面下端に張り付く。画面中央に出す。
        w.center()

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "laserguide")
        config.userContentController = ucc
        // 開発中の DevTools を有効化 (macOS 13.3+ で public)。Phase 2 で条件分岐可。
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: contentRect, configuration: config)
        wv.autoresizingMask = [.width, .height]
        w.contentView = wv
        webView = wv
        window = w

        loadCalibrationHTML(into: wv)

        // 状態購読: 既存の stateDidChange は overlay 側にも配られているので、そちらを壊さないように
        // 追加購読チェインを組む。AppRuntime 側に複数購読 API が無いので、AppDelegate 側で chain する
        // (このコントローラは単体では runtime.stateDidChange を横取りしない)。
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()

        // 初回 push は WebView の didFinish で行いたいが、AppDelegate 側からも apply(state:) で
        // trigger されるので待ち受けだけ用意しておく。
        schedulePush()
    }

    private func loadCalibrationHTML(into wv: WKWebView) {
        // DR-0010: `swift run laserguide-dev` 経路 (SPM) と `.app` 起動経路 (build-app-bundle.sh)
        // の両方をサポートする。SPM は資産を Bundle.module (パッケージ生成の resource bundle) に
        // 置き、.app バンドルは Contents/Resources 直下に置くため、両者から順に検索する。
        guard let url = Self.calibrationIndexURL() else {
            NSLog("[LaserGuide] calibration: index.html not found in Bundle.module nor Bundle.main")
            return
        }
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// キャリブレーション UI の `index.html` を、.app 経路 (`Bundle.main.resourceURL/calibration/`)
    /// と SPM 経路 (`Bundle.module`) の両方から探す。
    ///
    /// 検索順 (2026-07-10 実機フィードバック第 2 ラウンド #1 で反転):
    ///   1. `Bundle.main` の `Contents/Resources/calibration/index.html`: build-app-bundle.sh が
    ///      .app バンドル組み立て時に Resources 直下へコピーした経路。`FileManager.fileExists`
    ///      だけで判定し、**`Bundle.module` に一切触れない**
    ///   2. `Bundle.module.url(forResource:...)`: SPM `resources: [.copy("Resources/calibration")]`
    ///      が展開した bundle。`swift run laserguide-dev` はこの経路を取る
    ///
    /// 順序を .app 優先にした理由: `Bundle.module` は SPM が生成する static computed property で、
    /// 初回アクセス時に `LaserGuideDev_LaserGuideDev.bundle` を探せないと `fatalError` する実装
    /// (Swift 5.9 の生成コード)。.app バンドルは `Contents/Resources/calibration/` に直接資産を
    /// 置くレイアウトで `LaserGuideDev_LaserGuideDev.bundle` 自体が存在しないため、旧実装 (`Bundle.module`
    /// を先に呼ぶ) は .app 環境で毎回この fatalError を踏む可能性があった (開発機では `.build` の
    /// 絶対パスが `Bundle.module` の探索先に偶然残っていて動いていただけ)。`Bundle.main` を先に
    /// `fileExists` だけで判定すれば、.app 環境では `Bundle.module` に到達せずに済む。
    ///
    /// どちらでも見つからない場合は nil を返し、呼び出し側が NSLog で報告する。
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
        guard window != nil else { return }
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
        if pendingPush { return }
        pendingPush = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            guard let self else { return }
            self.pendingPush = false
            self.pushNow()
        }
    }

    private func pushNow() {
        guard let wv = webView, let json = lastPushedJSON else { return }
        // JSON リテラルを直接 JS 文字列に埋めるとエスケープ地獄になるので、
        // JSON.parse(<json>) で一度パースさせる。<json> は JSON literal そのままだが、
        // JavaScript の文字列リテラルとして安全に埋め込むため base64 経由で渡す。
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
        wv.evaluateJavaScript(script) { _, error in
            if let error { NSLog("[LaserGuide] calibration: JS push failed: \(error)") }
        }
    }

    // MARK: - JS → Swift

    // WKScriptMessage の kind 分岐が 6 通り + guard で cyclomatic complexity 11 になるが、
    // 各 case は 1〜3 行の平坦な dispatch でネストは無い。閾値 10 は「絡み合った条件」向け
    // で、フラットな dispatch table 型 switch は例外扱いする。
    // swiftlint:disable:next cyclomatic_complexity
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "laserguide" else { return }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            NSLog("[LaserGuide] calibration: invalid message body: \(message.body)")
            return
        }
        switch kind {
        case "calibration.requestInitialRender":
            // JS 側の boot 時: 現在の state で即座に push
            apply(state: runtime.state)
        case "calibration.dragStart":
            guard let displayId = body["displayId"] as? String else { return }
            runtime.dispatch(.calibration(.dragStart(displayId: displayId)))
        case "calibration.dragMove":
            guard let displayId = body["displayId"] as? String,
                  let pose = body["candidatePose"] as? [String: Any],
                  let candidate = decodePose(pose) else { return }
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

    private func decodePose(_ dict: [String: Any]) -> DisplayPose? {
        guard let translate = dict["translate"] as? [String: Any],
              let tx = (translate["x"] as? NSNumber)?.doubleValue,
              let ty = (translate["y"] as? NSNumber)?.doubleValue,
              let sx = (dict["scaleX"] as? NSNumber)?.doubleValue,
              let sy = (dict["scaleY"] as? NSNumber)?.doubleValue,
              sx > 0, sy > 0 else { return nil }
        return DisplayPose(translate: PhysicalPoint(x: tx, y: ty), scaleX: sx, scaleY: sy)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // JS 側で編集中なら cancel を投げてから閉じる (中間 candidatePose の残留を防ぐ)。
        if runtime.state.calibration.draggingDisplayId != nil
            || !runtime.state.calibration.candidatePoses.isEmpty {
            runtime.dispatch(.calibration(.cancel))
        }
        window = nil
        webView = nil
        lastPushedJSON = nil
    }
}
