import SwiftUI
import WebKit

/// SwiftUI host for a persistent `WebScreenModel`: progress bar, back button, error/offline states.
struct WebScreen: View {
    @ObservedObject var model: WebScreenModel
    let title: String

    var body: some View {
        ZStack {
            WebViewHost(webView: model.webView)
                .ignoresSafeArea(edges: .bottom)
                .opacity(model.loadError == nil ? 1 : 0)

            if let error = model.loadError {
                LoadErrorView(error: error, retry: model.reload)
            }
        }
        .overlay(alignment: .top) {
            if model.isLoading, model.progress < 1 {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
            }
        }
        .navigationTitle(model.title.isEmpty ? title : model.title.replacingOccurrences(of: " · TieDown", with: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canGoBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .onAppear { model.loadIfNeeded() }
    }
}

private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> WKWebView { webView }
    func updateUIView(_: WKWebView, context _: Context) {}
}

private struct LoadErrorView: View {
    let error: WebScreenModel.LoadError
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            switch error {
            case .offline:
                Label("You're offline", systemImage: "wifi.slash")
            case .unreachable:
                Label("Can't reach TieDown", systemImage: "server.rack")
            case .failed:
                Label("Couldn't load this page", systemImage: "exclamationmark.triangle")
            }
        } description: {
            switch error {
            case .offline:
                Text("Check your internet connection. This page will reload when you're back online.")
            case let .unreachable(host):
                Text("The server at \(host) isn't responding. It may be down, or this build may point at the wrong server.")
            case let .failed(message):
                Text(message)
            }
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}
