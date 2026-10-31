import XCTest
@testable import MikaIOS

final class AlarmAndProviderTests:XCTestCase {
    private var calendar:Calendar {
        var value=Calendar(identifier:.gregorian);value.timeZone=TimeZone(secondsFromGMT:8*3600)!;return value
    }
    private var now:Date {calendar.date(from:DateComponents(year:2026,month:10,day:31,hour:20,minute:0))!}
    func testSuggestedAlarmKeepsTomorrowAndMinute() throws {
        let plan=try XCTUnwrap(QuickAlarmIntent.parse("帮我订明天早上 9:40 的闹钟",now:now,calendar:calendar))
        XCTAssertEqual(calendar.dateComponents([.month,.day,.hour,.minute],from:plan.date),DateComponents(month:11,day:1,hour:9,minute:40))
    }
    func testChineseTimesAndNextOccurrence() throws {
        for (text,hour,minute) in [("设明早七点一刻闹钟",7,15),("设明天晚上九点半闹钟",21,30),("设凌晨十二点三刻闹钟",0,45)] {
            let plan=try XCTUnwrap(QuickAlarmIntent.parse(text,now:now,calendar:calendar))
            XCTAssertEqual(plan.hour,hour);XCTAssertEqual(plan.minute,minute);XCTAssertGreaterThan(plan.date,now)
        }
    }
    func testRelativeAlarmAndRepeatingWeekdays() throws {
        let relative=try XCTUnwrap(QuickAlarmIntent.parse("设两分钟后的测试闹钟",now:now,calendar:calendar))
        XCTAssertEqual(relative.date.timeIntervalSince(now),120)
        XCTAssertEqual(QuickAlarmIntent.parse("设两小时后闹钟",now:now,calendar:calendar)?.date.timeIntervalSince(now),7200)
        let weekdays=try XCTUnwrap(QuickAlarmIntent.parse("设工作日早上7点闹钟",now:now,calendar:calendar))
        XCTAssertEqual(weekdays.weekdays,[1,2,3,4,5]);XCTAssertEqual(calendar.component(.day,from:weekdays.date),2)
        let weekly=try XCTUnwrap(QuickAlarmIntent.parse("设置每周一、三、五8:30闹钟",now:now,calendar:calendar))
        XCTAssertEqual(weekly.weekdays,[1,3,5]);XCTAssertEqual(weekly.minute,30)
    }
    func testUnsafeOrUnsupportedPhrasesDoNotScheduleWrongAlarm() {
        for text in ["不要设置7点闹钟","怎么设置7点闹钟","取消7点闹钟","设25:00闹钟","设7:70闹钟","设今天7点闹钟","设11月5日7点闹钟","设下周一7点闹钟","设7点和8点闹钟","设48小时后闹钟","设每天两分钟后闹钟"] {
            XCTAssertNil(QuickAlarmIntent.parse(text,now:now,calendar:calendar),text)
        }
    }
    func testOfficialProviderDisablesThinkingAndConflictingEffort() throws {
        let value=ProviderGenerationPolicy.apply(["model":"deepseek-flash","reasoning_effort":"max"],base:"https://api.deepseek.com/v1",thinking:false,effort:"low")
        XCTAssertEqual((value["thinking"] as? [String:String])?["type"],"disabled")
        XCTAssertNil(value["reasoning_effort"])
        let other=ProviderGenerationPolicy.apply(["model":"another"],base:"https://example.com/v1",thinking:false,effort:"low")
        XCTAssertNil(other["thinking"])
    }
    @MainActor func testModelSerializesSelectedProviderPolicy() throws {
        let model=Model();let previous=(model.base,model.model,model.thinkingEnabled,model.reasoningEffort)
        defer {(model.base,model.model,model.thinkingEnabled,model.reasoningEffort)=previous}
        model.base="https://api.deepseek.com/v1";model.thinkingEnabled=false;model.reasoningEffort="low"
        let data=try model.providerBody(["model":"deepseek-flash","messages":[["role":"user","content":"test"]]])
        let value=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual((value["thinking"] as? [String:String])?["type"],"disabled");XCTAssertNil(value["reasoning_effort"])
    }
}
