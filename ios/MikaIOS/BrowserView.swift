import SwiftUI
import WebKit
struct BrowserView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var address="https://www.google.com"
    @State private var web=WKWebView()
    @State private var error=""
    var body: some View {
        VStack(spacing:0) {
            HStack {TextField("网址",text:$address).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled().textFieldStyle(.roundedBorder).onSubmit {load()};Button("打开") {load()}}.padding()
            WebContainer(web:web)
            if !error.isEmpty {Text(error).font(.caption).foregroundStyle(.red).padding()}
            Button {web.evaluateJavaScript("document.body ? document.body.innerText : ''") {value,err in if let text=value as? String,!text.isEmpty {model.pageText=String(text.prefix(100000));dismiss()} else {error=err?.localizedDescription ?? "页面没有可读取的文字"}}} label: {Label("读取页面给 Mika",systemImage:"doc.text.magnifyingglass").frame(maxWidth:.infinity).padding()}.buttonStyle(.borderedProminent).padding()
        }.navigationTitle("浏览器").navigationBarTitleDisplayMode(.inline).onAppear {if web.url==nil {load()}}
    }
    private func load() {guard let url=URL(string:address),["http","https"].contains(url.scheme ?? "") else {error="请输入完整的 http:// 或 https:// 网址";return};error="";web.load(URLRequest(url:url))}
}
struct WebContainer: UIViewRepresentable {let web:WKWebView;func makeUIView(context:Context)->WKWebView {web};func updateUIView(_ view:WKWebView,context:Context) {}}
