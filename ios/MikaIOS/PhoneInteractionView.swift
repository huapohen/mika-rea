import SwiftUI

struct PhoneInteractionView:View {
    let interaction:PhoneInteraction
    let owner:Bool
    var showsInput=true
    let respond:(String) async throws -> Void
    @State private var answer=""
    @State private var error=""
    @State private var sending=false
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            ScrollView {Text(interaction.prompt).font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("interactionPrompt")}
                .frame(height:min(130,max(44,CGFloat((interaction.prompt.count/26)+1)*22)))
            switch interaction.kind {
            case .question:
                if !interaction.options.isEmpty {
                    ScrollView(.horizontal,showsIndicators:false) {HStack {ForEach(Array(interaction.options.enumerated()),id:\.offset) {_,option in Button(option) {submit(option)}.buttonStyle(.bordered)}}}
                }
                if showsInput {
                    HStack {TextField("回答这个问题…",text:$answer,axis:.vertical).lineLimit(1...3).textFieldStyle(.roundedBorder).accessibilityIdentifier("interactionAnswerInput");Button("回答") {submit(answer)}.disabled(answer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("interactionSubmit")}
                }
            case .confirmation:
                HStack {Button("同意继续") {submit("approve")}.buttonStyle(.borderedProminent);Button("不同意",role:.destructive) {submit("decline")}.buttonStyle(.bordered)}
            case .handoff:
                if owner {
                    if let bundle=interaction.bundleID {
                        Button("打开目标 App，交给我操作") {Task {do {_ = try await OnDeviceControl.shared.execute(["action":"launch","bundle_id":bundle],returnToMika:false)} catch {self.error=error.localizedDescription}}}
                    }
                    Text("处理后回到 Mika 再点继续。不要在聊天里填写密码或验证码。").font(.caption).foregroundStyle(.secondary)
                    HStack {Button("我已处理，继续核实") {submit("complete")}.buttonStyle(.borderedProminent);Button("跳过") {submit("skip")}}
                } else {Text("请由目标手机本人完成操作，并在那台手机的 Mika 中交还控制。控制端不能替本人确认。").font(.footnote).foregroundStyle(.secondary)}
            }
            if !error.isEmpty {Text(error).font(.footnote).foregroundStyle(.red)}
        }.disabled(sending).onChange(of:interaction.id) {_ in answer="";error=""}
    }
    private func submit(_ text:String) {
        guard !sending else {return};sending=true
        Task {do {try await respond(text);answer="";error=""} catch {self.error=error.localizedDescription};sending=false}
    }
}
