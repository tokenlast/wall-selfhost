import SwiftUI
import WebKit

struct GIFBrowserView: View {
    @ObservedObject var store: WallGIFStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddedToast = false
    @State private var showingAddedFlash = false
    @State private var toastGeneration = 0
    @State private var searchText = ""
    @State private var searchRequest: GifCitiesSearchRequest?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("GIFCITIES")
                    .font(.custom("Helvetica", size: 15).weight(.bold))
                    .tracking(0.5)

                TextField("SEARCH", text: $searchText)
                    .font(.custom("Helvetica", size: 15))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit(submitSearch)
                    .padding(.horizontal, 10)
                    .frame(width: 260, height: 36)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                    .accessibilityLabel("Search GifCities")
                    .accessibilityIdentifier("wall.gif.search")

                Spacer()

                if let message = store.importMessage {
                    Text(message)
                        .font(.custom("Helvetica", size: 13))
                        .foregroundColor(.black.opacity(0.62))
                        .lineLimit(1)
                }

                if store.isImporting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.black)
                }

                InstantActionButton(action: { dismiss() }) {
                    Text("DONE")
                        .font(.custom("Helvetica", size: 13).weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color.black)
                }
                .accessibilityIdentifier("wall.gif.done")
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .background(Color.white)

            Rectangle()
                .fill(Color.black)
                .frame(height: 1)

            GifCitiesWebView(
                searchRequest: searchRequest,
                onSearchFocusRequested: { existingValue in
                    if !existingValue.isEmpty { searchText = existingValue }
                    DispatchQueue.main.async { searchFocused = true }
                },
                onGIFTapped: { url in
                    guard !store.isImporting else { return }
                    store.importGIF(from: url)
                }
            )
        }
        .allowsHitTesting(!store.isImporting)
        .background(Color.white)
        .preferredColorScheme(.light)
        .overlay {
            if showingAddedFlash {
                Color.white.opacity(0.72)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if showingAddedToast {
                Text("GIF ADDED")
                    .font(.custom("Helvetica", size: 18).weight(.bold))
                    .tracking(0.5)
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 46)
                    .background(Color.black)
                    .transition(.opacity)
                    .padding(.bottom, 28)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: store.addedCount) { count in
            toastGeneration = count
            withAnimation(.linear(duration: 0.04)) {
                showingAddedFlash = true
                showingAddedToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                guard toastGeneration == count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    showingAddedFlash = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                guard toastGeneration == count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    showingAddedToast = false
                }
            }
        }
        .onDisappear { store.clearImportMessage() }
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchRequest = GifCitiesSearchRequest(query: query)
        searchFocused = false
    }
}

struct GIFLauncherButton: View {
    let action: () -> Void

    var body: some View {
        InstantActionButton(action: action) {
            Text(".gif")
                .font(.custom("Helvetica", size: 15).weight(.bold))
                .foregroundColor(.white)
                .frame(width: 48, height: 40)
                .background(Color.black)
        }
        .accessibilityLabel("Open GifCities")
    }
}

private struct GifCitiesSearchRequest: Equatable {
    let id = UUID()
    let query: String
}

private struct GifCitiesWebView: UIViewRepresentable {
    let searchRequest: GifCitiesSearchRequest?
    let onSearchFocusRequested: (String) -> Void
    let onGIFTapped: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSearchFocusRequested: onSearchFocusRequested,
            onGIFTapped: onGIFTapped
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "wallGIF")
        controller.add(context.coordinator, name: "wallSearchFocus")
        controller.addUserScript(WKUserScript(
            source: Self.tapInterceptor,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: URL(string: "https://gifcities.org/")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSearchFocusRequested = onSearchFocusRequested
        context.coordinator.onGIFTapped = onGIFTapped
        guard let request = searchRequest,
              context.coordinator.lastSearchRequestID != request.id else { return }
        context.coordinator.lastSearchRequestID = request.id

        var components = URLComponents(string: "https://gifcities.org/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: request.query),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "page_size", value: "200")
        ]
        if let url = components.url {
            webView.load(URLRequest(url: url))
        }
    }

    static let tapInterceptor = """
    (function() {
      if (window.__wallGifTapInstalled) return;
      window.__wallGifTapInstalled = true;
      document.addEventListener('click', function(event) {
        var field = event.target && event.target.closest ? event.target.closest('input[type="search"]') : null;
        if (!field) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        window.webkit.messageHandlers.wallSearchFocus.postMessage(field.value || '');
      }, true);
      document.addEventListener('click', function(event) {
        var image = event.target && event.target.closest ? event.target.closest('img') : null;
        if (!image) return;
        var source = image.currentSrc || image.src || '';
        try {
          var url = new URL(source, document.baseURI);
          if (url.protocol === 'https:' && url.hostname === 'blob.gifcities.org' && url.pathname.toLowerCase().endsWith('.gif')) {
            event.preventDefault();
            event.stopPropagation();
            window.webkit.messageHandlers.wallGIF.postMessage(url.href);
          }
        } catch (_) {}
      }, true);
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var onSearchFocusRequested: (String) -> Void
        var onGIFTapped: (URL) -> Void
        var lastSearchRequestID: UUID?

        init(
            onSearchFocusRequested: @escaping (String) -> Void,
            onGIFTapped: @escaping (URL) -> Void
        ) {
            self.onSearchFocusRequested = onSearchFocusRequested
            self.onGIFTapped = onGIFTapped
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "wallSearchFocus":
                onSearchFocusRequested(message.body as? String ?? "")
            case "wallGIF":
                guard let string = message.body as? String,
                      let url = URL(string: string) else { return }
                onGIFTapped(url)
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let host = navigationAction.request.url?.host?.lowercased() else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(host == "gifcities.org" || host == "www.gifcities.org" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url,
               let host = url.host?.lowercased(),
               host == "gifcities.org" || host == "www.gifcities.org" {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
