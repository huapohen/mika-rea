import WidgetKit
import SwiftUI
import ActivityKit

@main struct MikaLiveWidget:Widget {
    var body:some WidgetConfiguration {
        ActivityConfiguration(for:MikaActivityAttributes.self) {context in
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:12) {
                    Image("MikaLogo").resizable().scaledToFit().frame(width:40,height:40)
                    VStack(alignment:.leading,spacing:4) {
                        Text(context.isStale ? "打开 Mika 更新状态" : context.state.headline).font(.headline)
                        Text(context.attributes.target+" · "+context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength:0)
                }
                HStack {
                    Link(destination:URL(string:"mikarea://task")!) {Label("打开 Mika",systemImage:"arrow.up.forward.app")}
                    Spacer()
                    stopButton(context)
                }.font(.subheadline).buttonStyle(.bordered)
            }.padding(16)
                .activityBackgroundTint(Color(uiColor:.secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(URL(string:"mikarea://task")!)
        } dynamicIsland:{context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {Image("MikaLogo").resizable().scaledToFit().frame(width:32,height:32).padding(.leading,4)}
                DynamicIslandExpandedRegion(.trailing) {Text(context.attributes.target).font(.caption).foregroundStyle(.secondary)}
                DynamicIslandExpandedRegion(.center) {Text(context.isStale ? "请回到 Mika 查看" : context.state.headline).font(.headline).lineLimit(1)}
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.detail).font(.caption).lineLimit(1)
                        Spacer()
                        stopButton(context)
                    }.padding(.horizontal,4)
                }
            } compactLeading:{
                Image("MikaLogo").resizable().scaledToFit().frame(width:22,height:22).accessibilityLabel("Mika 任务胶囊")
            } compactTrailing:{
                Image(systemName:context.state.phase=="needsUser" ? "person.crop.circle.badge.exclamationmark" : "ellipsis")
                    .foregroundStyle(context.state.phase=="needsUser" ? .orange : .cyan)
            } minimal:{
                Image("MikaLogo").resizable().scaledToFit().accessibilityLabel("Mika 任务胶囊")
            }.widgetURL(URL(string:"mikarea://task")!).keylineTint(.cyan)
        }
    }
    @ViewBuilder private func stopButton(_ context:ActivityViewContext<MikaActivityAttributes>)->some View {
        if context.state.canStop {
            if #available(iOS 17.0,*) {
                Button(intent:StopMikaTaskIntent(operationID:context.attributes.operationID)) {
                    Label(context.state.phase=="preview" ? "结束预览" : (context.state.phase=="ready" ? "停止控制" : "停止"),systemImage:"stop.fill")
                }.accessibilityIdentifier("mikaLiveStop")
            } else {Link("查看任务",destination:URL(string:"mikarea://task")!)}
        }
    }
}
