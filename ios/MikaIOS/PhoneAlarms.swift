import Foundation
import SwiftUI
import AlarmKit
import UIKit

struct PhoneAlarmPlan:Codable,Equatable {
    var date:Date
    var hour:Int
    var minute:Int
    var weekdays:[Int]=[] // Monday 1 ... Sunday 7.
    var label="Mika 闹钟"
}
struct PhoneAlarmRecord:Codable,Identifiable {
    var id:UUID
    var requestID:String
    var plan:PhoneAlarmPlan
    var state:String
}

enum QuickAlarmIntent {
    static func parse(_ text:String,now:Date=Date(),calendar:Calendar = .current)->PhoneAlarmPlan? {
        guard text.contains("闹钟"),text.range(of:"设置|设定|设个|设一|设|定个|定一|订|创建|加个",options:.regularExpression) != nil,
              text.range(of:"不要|别设|取消|删除|关闭|如何|怎么|为什么",options:.regularExpression)==nil else {return nil}
        // Unsupported dates or compound requests must not silently become today's alarm.
        guard text.range(of:"[0-9一二三四五六七八九十]+[年月日号]|下周|下星期|下个月|分别|两个|三个|以及|然后",options:.regularExpression)==nil else {return nil}
        func number(_ value:String)->Int? {
            if let n=Int(value) {return n}
            let digits:[Character:Int]=["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
            if value=="十" {return 10}
            if let split=value.firstIndex(of:"十") {
                let a=String(value[..<split]),b=String(value[value.index(after:split)...])
                guard (a.isEmpty || (a.count==1 && digits[a.first!] != nil)),(b.isEmpty || (b.count==1 && digits[b.first!] != nil)) else {return nil}
                return (a.isEmpty ? 1 : digits[a.first!]!)*10+(b.isEmpty ? 0 : digits[b.first!]!)
            }
            return value.count==1 ? digits[value.first!] : nil
        }
        func groups(_ pattern:String)->[String]? {
            guard let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else {return nil}
            return (1..<match.numberOfRanges).map {Range(match.range(at:$0),in:text).map {String(text[$0])} ?? ""}
        }
        if let relative=groups("([0-9一二两三四五六七八九十]+)\\s*(分钟|小时)后"),let n=number(relative[0]),n>0,n<=1440 {
            guard text.range(of:"每天|每周|工作日|周末|[:：点]",options:.regularExpression)==nil else {return nil}
            let seconds=n*(relative[1]=="小时" ? 3600 : 60)
            guard seconds<=86400 else {return nil}
            let date=now.addingTimeInterval(TimeInterval(seconds)),parts=calendar.dateComponents([.hour,.minute],from:date)
            return PhoneAlarmPlan(date:date,hour:parts.hour!,minute:parts.minute!,label:text.contains("测试") ? "Mika 临时测试闹钟" : "Mika 闹钟")
        }
        guard let time=groups("([0-9]{1,3}|[一二两三四五六七八九十零〇]{1,3})\\s*(?:[:：点时])\\s*(一刻|三刻|半|[0-9]{1,3}|[一二两三四五六七八九十零〇]{1,3})?"),var hour=number(time[0]) else {return nil}
        let times=try? NSRegularExpression(pattern:"[0-9一二两三四五六七八九十零〇]+\\s*[:：点时]")
        guard times?.numberOfMatches(in:text,range:NSRange(text.startIndex...,in:text))==1 else {return nil}
        let minute=time[1].isEmpty ? 0 : time[1]=="半" ? 30 : time[1]=="一刻" ? 15 : time[1]=="三刻" ? 45 : number(time[1]) ?? -1
        guard (0...23).contains(hour),(0...59).contains(minute) else {return nil}
        if text.range(of:"下午|晚上|傍晚",options:.regularExpression) != nil,hour<12 {hour+=12}
        if text.range(of:"凌晨|早上|上午|明早",options:.regularExpression) != nil,hour==12 {hour=0}
        var days:[Int]=[]
        if text.contains("每天") {days=Array(1...7)}
        else if text.contains("工作日") {days=Array(1...5)}
        else if text.contains("周末") && text.contains("每") {days=[6,7]}
        else if text.contains("每周") {
            let names:[Character:Int]=["一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"日":7,"天":7]
            if let expression=groups("每周([一二三四五六日天、，,\\s]+)") {days=Array(Set(expression[0].compactMap {names[$0]})).sorted()}
            guard !days.isEmpty else {return nil}
        } else if text.contains("周") || text.contains("星期") {return nil}
        let offset=text.contains("后天") ? 2 : text.contains("明天") || text.contains("明早") ? 1 : 0
        guard let start=calendar.date(byAdding:.day,value:offset,to:calendar.startOfDay(for:now)),var date=calendar.date(bySettingHour:hour,minute:minute,second:0,of:start) else {return nil}
        if date<=now {
            if text.contains("今天") {return nil}
            guard let next=calendar.date(byAdding:.day,value:1,to:date) else {return nil};date=next
        }
        if !days.isEmpty {
            let requested=date
            for _ in 0..<7 {
                let weekday=(calendar.component(.weekday,from:date)+5)%7+1
                if days.contains(weekday) {break}
                guard let next=calendar.date(byAdding:.day,value:1,to:date) else {return nil};date=next
            }
            // Relative repeating alarms start on the next matching occurrence.
            if offset>0,let today=calendar.date(bySettingHour:hour,minute:minute,second:0,of:now),today>now,
               days.contains((calendar.component(.weekday,from:today)+5)%7+1),requested>today {return nil}
        }
        return PhoneAlarmPlan(date:date,hour:hour,minute:minute,weekdays:days)
    }
}

@available(iOS 26.0,*) private struct MikaAlarmMetadata:AlarmMetadata {var title:String}

@MainActor final class PhoneAlarms:ObservableObject {
    static let shared=PhoneAlarms()
    @Published private(set) var records:[PhoneAlarmRecord]=[]
    private let file:URL
    private var readable=true
    init(directory:URL?=nil) {
        file=(directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]).appendingPathComponent("MikaAlarms.json")
        if FileManager.default.fileExists(atPath:file.path) {
            do {records=try JSONDecoder().decode([PhoneAlarmRecord].self,from:Data(contentsOf:file))} catch {readable=false}
        }
    }
    private func persist() throws {
        guard readable else {throw Model.Issue.message("闹钟记录无法读取，原文件保留。")}
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(records).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    @available(iOS 26.0,*) private func schedule(_ plan:PhoneAlarmPlan)->Alarm.Schedule {
        if plan.weekdays.isEmpty {return .fixed(plan.date)}
        let map:[Int:Locale.Weekday]=[1:.monday,2:.tuesday,3:.wednesday,4:.thursday,5:.friday,6:.saturday,7:.sunday]
        return .relative(.init(time:.init(hour:plan.hour,minute:plan.minute),repeats:.weekly(plan.weekdays.compactMap {map[$0]})))
    }
    func create(_ plan:PhoneAlarmPlan,requestID:String,mayRequestAuthorization:Bool=true) async throws ->PhoneAlarmRecord {
        guard #available(iOS 26.0,*) else {throw Model.Issue.message("系统闹钟接口需要 iOS 26 或以上。")}
        try Task.checkCancellation()
        guard readable,plan.date>Date(),(0...23).contains(plan.hour),(0...59).contains(plan.minute),plan.weekdays.allSatisfy({(1...7).contains($0)}) else {throw Model.Issue.message("闹钟时间无效或记录不可用，没有创建。")}
        let manager=AlarmManager.shared
        guard mayRequestAuthorization || manager.authorizationState != .notDetermined else {throw Model.Issue.message("请先在 Mika 的设置 → Mika 闹钟中允许系统闹钟权限，之后可从 Siri 或快捷指令创建。")}
        let authorization=manager.authorizationState == .notDetermined ? try await manager.requestAuthorization() : manager.authorizationState
        guard authorization == .authorized else {throw Model.Issue.message("系统尚未允许 Mika 创建闹钟，请在系统授权中允许后重试。")}
        let expected=schedule(plan)
        guard plan.date>Date() else {throw Model.Issue.message("授权期间时间已经过去，请选择未来的响铃时间。")}
        if !plan.weekdays.isEmpty {
            let calendar=Calendar.current
            guard var next=calendar.nextDate(after:Date(),matching:DateComponents(hour:plan.hour,minute:plan.minute,second:0),matchingPolicy:.nextTime) else {throw Model.Issue.message("重复闹钟时间不可用。")}
            for _ in 0..<7 {
                if plan.weekdays.contains((calendar.component(.weekday,from:next)+5)%7+1) {break}
                next=calendar.date(byAdding:.day,value:1,to:next)!
            }
            guard abs(next.timeIntervalSince(plan.date))<60 else {throw Model.Issue.message("重复闹钟会从下一个匹配的时间开始；所选日期不匹配，没有创建。")}
        }
        if let record=records.first(where:{$0.requestID==requestID}) {
            guard record.plan==plan else {throw Model.Issue.message("同一次请求的闹钟内容不一致，没有重复创建。")}
            guard try manager.alarms.contains(where:{$0.id==record.id && $0.schedule==expected}) else {throw Model.Issue.message("上次创建结果未获系统确认，请核对闹钟列表；不会自动重试。")}
            return record
        }
        let id=UUID()
        try Task.checkCancellation()
        records.append(.init(id:id,requestID:requestID,plan:plan,state:"requesting"));try persist()
        let title=LocalizedStringResource(stringLiteral:plan.label)
        let alert:AlarmPresentation.Alert
        if #available(iOS 26.1,*) {alert = .init(title:title)}
        else {alert = .init(title:title,stopButton:.init(text:"停止",textColor:.white,systemImageName:"stop.circle"))}
        let attributes=AlarmAttributes(presentation:AlarmPresentation(alert:alert),metadata:MikaAlarmMetadata(title:plan.label),tintColor:Color.blue)
        do {
            _ = try await manager.schedule(id:id,configuration:.alarm(schedule:expected,attributes:attributes))
            guard try manager.alarms.contains(where:{$0.id==id && $0.schedule==expected}) else {throw Model.Issue.message("系统未读回这个闹钟。")}
            let index=records.firstIndex {$0.id==id}!
            records[index].state="scheduled";try persist();return records[index]
        } catch {
            if let index=records.firstIndex(where:{$0.id==id}) {records[index].state="unconfirmed";try? persist()}
            throw Model.Issue.message("闹钟未获系统确认，不会重复创建。请在 Mika 闹钟列表核对。")
        }
    }
    func cancel(_ id:UUID) throws {
        guard #available(iOS 26.0,*),let index=records.firstIndex(where:{$0.id==id}) else {throw Model.Issue.message("没有找到这个 Mika 闹钟。")}
        if try AlarmManager.shared.alarms.contains(where:{$0.id==id}) {try AlarmManager.shared.cancel(id:id)}
        guard try !AlarmManager.shared.alarms.contains(where:{$0.id==id}) else {throw Model.Issue.message("系统尚未确认删除，请勿重复操作。")}
        records[index].state="cancelled";try persist()
    }
    #if DEBUG
    func acceptanceProbe(lockedCreation:Bool=false) async {
        guard #available(iOS 26.0,*) else {return}
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent(lockedCreation ? "NativeAlarmIntentAcceptance.json" : "NativeAlarmAcceptance.json")
        var report:[String:Any]=["native_api":true,"temporary_alarm":true,"success":false]
        func save() {
            report["timestamp"]=ISO8601DateFormatter().string(from:Date())
            if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {try? data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
        }
        report["phase"]="requesting_authorization";save()
        let authorization=AlarmManager.shared.authorizationState == .notDetermined ? try? await AlarmManager.shared.requestAuthorization() : AlarmManager.shared.authorizationState
        guard authorization == .authorized else {report["phase"]="authorization_unavailable";save();return}
        var created:PhoneAlarmRecord?
        do {
            if lockedCreation {
                report["phase"]="waiting_for_lock";save()
                try await Task.sleep(nanoseconds:12_000_000_000)
            }
            let date=Date().addingTimeInterval(60),parts=Calendar.current.dateComponents([.hour,.minute],from:date)
            let plan=PhoneAlarmPlan(date:date,hour:parts.hour!,minute:parts.minute!,label:"Mika 临时响铃测试")
            let record:PhoneAlarmRecord
            if lockedCreation {
                report["app_in_background"]=UIApplication.shared.applicationState == .background
                report["protected_data_available"]=UIApplication.shared.isProtectedDataAvailable
                report["invocation"]="direct_app_intent_perform_not_siri"
                let previous=Set(records.map(\.id))
                var intent=CreateMikaAlarmIntent();intent.date=date
                _ = try await intent.perform()
                guard let result=records.first(where:{!previous.contains($0.id) && $0.plan.date==date}) else {throw Model.Issue.message("没有读回测试闹钟记录。")}
                record=result
            } else {record=try await create(plan,requestID:"acceptance-"+UUID().uuidString)}
            created=record
            report["created_and_read_back"]=true;report["alarm_id"]=record.id.uuidString;report["phase"]="waiting_for_alarm";report["scheduled_at"]=ISO8601DateFormatter().string(from:date);save()
            let end=date.addingTimeInterval(25)
            while Date()<end {
                if let alarm=try AlarmManager.shared.alarms.first(where:{$0.id==record.id}),alarm.state == .alerting {report["alerting_observed"]=true;break}
                try await Task.sleep(nanoseconds:500_000_000)
            }
            try cancel(record.id);created=nil
            report["cleanup_verified"]=true
            report["success"]=report["alerting_observed"] as? Bool == true
            report["phase"]="finished";save()
        } catch {
            report["failed"]=true;report["phase"]="failed"
            if let created {do {try cancel(created.id);report["cleanup_verified"]=true} catch {report["cleanup_verified"]=false}}
            save()
        }
    }
    #endif
    func summary(_ record:PhoneAlarmRecord)->String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"zh_CN");formatter.dateFormat="M月d日 HH:mm"
        let repeatText=record.plan.weekdays.isEmpty ? "一次" : record.plan.weekdays==Array(1...7) ? "每天" : record.plan.weekdays==Array(1...5) ? "工作日" : "每周 "+record.plan.weekdays.map(String.init).joined(separator:"、")
        return "已创建并从系统读回 Mika 闹钟：\(formatter.string(from:record.plan.date))，\(repeatText)。到点可在锁屏响铃；这不是普通消息提醒。"
    }
}

struct PhoneAlarmSettings:View {
    @ObservedObject private var alarms=PhoneAlarms.shared
    @State private var date=Date().addingTimeInterval(3600)
    @State private var recurrence="once"
    @State private var busy=false
    @State private var status=""
    var body:some View {
        Form {
            Section {
                Text("由 iOS 系统调度，可在锁屏响铃；不需要电脑、Wi-Fi、本机执行器或模型调用。Mika 创建的闹钟在这里管理。").font(.footnote).foregroundStyle(.secondary)
                DatePicker("响铃时间",selection:$date,in:Date()...,displayedComponents:[.date,.hourAndMinute])
                Picker("重复",selection:$recurrence) {Text("一次").tag("once");Text("每天").tag("daily");Text("工作日").tag("weekdays")}
                Button(busy ? "正在创建…" : "创建闹钟") {Task {
                    busy=true;defer {busy=false}
                    let parts=Calendar.current.dateComponents([.hour,.minute],from:date)
                    let plan=PhoneAlarmPlan(date:date,hour:parts.hour!,minute:parts.minute!,weekdays:recurrence=="daily" ? Array(1...7) : recurrence=="weekdays" ? Array(1...5) : [])
                    do {let record=try await alarms.create(plan,requestID:UUID().uuidString);status=alarms.summary(record)} catch {status=error.localizedDescription}
                }}.disabled(busy).accessibilityIdentifier("createNativeAlarm")
                if !status.isEmpty {Text(status).font(.footnote)}
            }
            Section("Mika 闹钟") {
                ForEach(alarms.records.filter {!["cancelled"].contains($0.state)}.reversed()) {record in
                    VStack(alignment:.leading,spacing:6) {
                        Text(record.plan.date.formatted(date:.abbreviated,time:.shortened))
                        Text(record.state=="scheduled" ? "已获系统确认" : "待核对").font(.caption).foregroundStyle(.secondary)
                        Button("删除",role:.destructive) {do {try alarms.cancel(record.id)} catch {status=error.localizedDescription}}
                    }
                }
            }
        }.navigationTitle("Mika 闹钟").navigationBarTitleDisplayMode(.inline)
    }
}
