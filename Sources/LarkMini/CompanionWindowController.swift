import AppKit
import WebKit

@MainActor
final class CompanionWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let shared = CompanionWindowController()

    private let webView: WKWebView
    private var policy: CompanionNavigationPolicy?

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        webView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Companion"
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SiftCompanionWindow")
        window.center()

        self.webView = webView
        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(baseURL: URL, path: String?) {
        let target = CompanionConfig.targetURL(base: baseURL, path: path) ?? baseURL
        policy = CompanionNavigationPolicy(baseURL: baseURL)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: target))
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch policy?.decision(for: url) ?? .allow {
        case .allow:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .external:
            if isMainFrame {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        switch policy?.decision(for: url) ?? .allow {
        case .allow:
            webView.load(URLRequest(url: url))
        case .external:
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        switch type {
        case .camera, .microphone, .cameraAndMicrophone:
            decisionHandler(.grant)
        @unknown default:
            decisionHandler(.prompt)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let filename = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var destination = directory.appendingPathComponent(filename)
        let stem = destination.deletingPathExtension().lastPathComponent
        let suffix = destination.pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = "\(stem) \(index)" + (suffix.isEmpty ? "" : ".\(suffix)")
            destination = directory.appendingPathComponent(name)
            index += 1
        }
        completionHandler(destination)
    }
}
