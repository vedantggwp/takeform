import SwiftUI
import WebKit

struct PreviewWebView: NSViewRepresentable {
    @Bindable var store: PreviewStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "takeformPreview")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard let origin = store.origin else { return }
        let page = store.selectedPage == "diagnostic" ? "diagnostic.html" : "bundle/index.html"
        let target = origin.appending(path: page)
        if view.url != target { view.load(URLRequest(url: target)) }
        context.coordinator.dispatchPendingCommand(to: view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let store: PreviewStore
        private var dispatchedCommandVersion = -1

        init(store: PreviewStore) { self.store = store }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "takeformPreview", message.frameInfo.isMainFrame,
                  let origin = store.origin,
                  message.frameInfo.securityOrigin.protocol == origin.scheme,
                  message.frameInfo.securityOrigin.host == origin.host,
                  message.frameInfo.securityOrigin.port == origin.port,
                  store.isExpectedMainDocument(message.frameInfo.request.url),
                  let data = try? JSONSerialization.data(withJSONObject: message.body),
                  let response = try? JSONDecoder().decode(PreviewResponse.self, from: data) else {
                store.state.fail(PreviewFailure.malformedResponse)
                return
            }
            store.acknowledge(response)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let origin = store.origin,
                  let targetFrame = navigationAction.targetFrame,
                  url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
                  !targetFrame.isMainFrame || store.isExpectedMainDocument(url) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard store.isExpectedMainDocument(webView.url) else { return }
            store.markSent(store.commandForRequestedFrame(load: true))
            dispatchPendingCommand(to: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            store.state.fail(error)
            store.helperStatus = "The selected page failed to load."
        }

        func dispatchPendingCommand(to webView: WKWebView) {
            guard dispatchedCommandVersion != store.commandVersion,
                  let command = store.pendingCommand,
                  let data = try? JSONEncoder().encode(command),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return }
            dispatchedCommandVersion = store.commandVersion
            webView.callAsyncJavaScript(
                "window.takeformPreviewCommand(command)",
                arguments: ["command": object],
                in: nil,
                in: .page,
                completionHandler: { [weak self] result in
                    if case let .failure(error) = result { self?.store.state.fail(error) }
                }
            )
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
