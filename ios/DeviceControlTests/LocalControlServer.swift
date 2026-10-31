import XCTest
import Network

/// Device-side UI driver. It listens only on loopback and requires a per-session token.
/// This is a test runner, not a privileged dylib injected into third-party apps.
final class LocalControlServer {
    private let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label:"mika.local.http")
    private var bundle: String?
    private(set) var stopped = false
    private let returnBundle = "com.huapohen.mikaremote"
    init(token: String) { self.token=token }

    func start() throws {
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:8123)
        let listener=try NWListener(using:parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue:queue)
        self.listener=listener
    }
    func stop() {stopped=true;listener?.cancel()}
    private func accept(_ connection:NWConnection) {
        connection.start(queue:queue)
        receive(connection,buffer:Data())
    }
    private func receive(_ connection:NWConnection,buffer:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,complete,error in
            guard let self else {connection.cancel();return}
            var bytes=buffer
            if let data {bytes.append(data)}
            guard bytes.count<=1_048_576 else {self.reply(connection,code:413,object:["error":"请求过大"]);return}
            guard let separator=bytes.range(of:Data("\r\n\r\n".utf8)) else {
                if complete || error != nil {connection.cancel()} else {self.receive(connection,buffer:bytes)}
                return
            }
            guard let header=String(data:bytes[..<separator.lowerBound],encoding:.utf8) else {connection.cancel();return}
            let lines=header.components(separatedBy:"\r\n")
            let requestLine=lines[0].split(separator:" ")
            guard requestLine.count==3 else {connection.cancel();return}
            var headers:[String:String]=[:]
            for line in lines.dropFirst() {
                guard let colon=line.firstIndex(of:":") else {continue}
                headers[String(line[..<colon]).lowercased()]=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            }
            guard self.authorized(headers["authorization"] ?? "") else {self.reply(connection,code:401,object:["error":"未授权"]);return}
            guard headers["transfer-encoding"] == nil,
                  let length=Int(headers["content-length"] ?? "0"),length>=0,length<=1_048_576 else {self.reply(connection,code:400,object:["error":"请求格式错误"]);return}
            let body=bytes[separator.upperBound...]
            if body.count<length {
                if complete || error != nil {connection.cancel()} else {self.receive(connection,buffer:bytes)}
                return
            }
            let path=String(requestLine[1])
            if requestLine[0]=="GET",path=="/status" {self.reply(connection,code:200,object:["ready":true,"service":"mika-local-control"]);return}
            guard requestLine[0]=="POST",path=="/control",
                  let object=try? JSONSerialization.jsonObject(with:body.prefix(length)) as? [String:Any] else {
                self.reply(connection,code:400,object:["error":"请求格式错误"]);return
            }
            DispatchQueue.main.async {
                do {
                    let result=try self.execute(object)
                    if object["return_to_mika"] as? Bool == true { XCUIApplication(bundleIdentifier:self.returnBundle).activate() }
                    self.reply(connection,code:200,object:result)
                }
                catch {self.reply(connection,code:400,object:["error":error.localizedDescription,"applied":false])}
            }
        }
    }
    private func authorized(_ header:String)->Bool {
        let expected=Array(("Bearer "+token).utf8),actual=Array(header.utf8)
        guard actual.count==expected.count else {return false}
        return zip(expected,actual).reduce(UInt8(0)) {$0 | ($1.0 ^ $1.1)}==0
    }
    private func reply(_ connection:NWConnection,code:Int,object:[String:Any]) {
        guard let body=try? JSONSerialization.data(withJSONObject:object) else {connection.cancel();return}
        var data=Data("HTTP/1.1 \(code) Result\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        data.append(body)
        connection.send(content:data,completion:.contentProcessed {_ in connection.cancel()})
    }
    private func target(_ args:[String:Any]) throws -> XCUIApplication {
        if let identifier=args["bundle_id"] as? String,!identifier.isEmpty {bundle=identifier}
        guard let bundle else {throw DriverError("请先指定要操作的 App")}
        let app=XCUIApplication(bundleIdentifier:bundle)
        app.activate()
        guard app.wait(for:.runningForeground,timeout:8) else {throw DriverError("无法将目标 App 切到前台")}
        return app
    }
    private func execute(_ args:[String:Any]) throws -> [String:Any] {
        switch args["action"] as? String {
        case "launch":
            let app=try target(args)
            return ["applied":true,"bundle_id":bundle!,"state":app.state.rawValue]
        case "source":
            let app=try target(args)
            let snapshot=try app.snapshot()
            var nodes:[[String:Any]]=[]
            func visit(_ item:XCUIElementSnapshot,depth:Int) {
                guard nodes.count<400,depth<30 else {return}
                if !item.label.isEmpty || !item.identifier.isEmpty {
                    var node:[String:Any]=["label":String(item.label.prefix(500)),"identifier":item.identifier,"type":item.elementType.rawValue,
                        "x":item.frame.midX,"y":item.frame.midY,"width":item.frame.width,"height":item.frame.height,"enabled":item.isEnabled]
                    if item.elementType == .searchField {node["search_field"]=true}
                    if item.elementType != .secureTextField,let value=item.value as? String {node["value"]=String(value.prefix(2000))}
                    nodes.append(node)
                }
                for child in item.children {visit(child,depth:depth+1)}
            }
            visit(snapshot,depth:0)
            return ["bundle_id":bundle!,"elements":nodes,"truncated":nodes.count>=400]
        case "tap":
            let app=try target(args)
            if let label=args["label"] as? String,!label.isEmpty {
                let predicate=NSPredicate(format:"label == %@ OR identifier == %@",label,label)
                let buttons=app.buttons.matching(predicate)
                let matches=buttons.count==1 ? buttons : app.descendants(matching:.any).matching(predicate)
                guard matches.count==1 else {throw DriverError("标签未找到或不唯一，请按读屏结果选择坐标")}
                let element=matches.element(boundBy:0)
                guard element.isHittable else {throw DriverError("目标当前不可点击")}
                element.tap()
            } else if let x=args["x"] as? Double,let y=args["y"] as? Double,app.frame.contains(CGPoint(x:x,y:y)) {
                app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x-app.frame.minX,dy:y-app.frame.minY)).tap()
            } else {throw DriverError("需要唯一标签或有效的屏幕坐标")}
            return ["applied":true]
        case "type":
            let app=try target(args)
            guard let text=args["text"] as? String,text.count<=10000 else {throw DriverError("输入内容过长或缺失")}
            if let label=args["label"] as? String,!label.isEmpty {
                let matches=app.descendants(matching:.any).matching(NSPredicate(format:"(label == %@ OR identifier == %@) AND (elementType == %d OR elementType == %d)",label,label,XCUIElement.ElementType.textField.rawValue,XCUIElement.ElementType.textView.rawValue))
                guard matches.count==1,matches.firstMatch.isHittable else {throw DriverError("找不到可输入的文本框")}
                matches.firstMatch.tap()
                matches.firstMatch.typeText(text)
            } else {
                guard app.keyboards.firstMatch.exists else {throw DriverError("请先点选文本框")}
                app.typeText(text)
            }
            return ["applied":true]
        case "swipe":
            let app=try target(args)
            switch args["direction"] as? String {
            case "up":app.swipeUp()
            case "down":app.swipeDown()
            case "left":app.swipeLeft()
            case "right":app.swipeRight()
            default:throw DriverError("滑动方向无效")
            }
            return ["applied":true]
        case "home":XCUIDevice.shared.press(.home);return ["applied":true]
        case "return":XCUIApplication(bundleIdentifier:returnBundle).activate();return ["applied":true]
        case "stop":stop();return ["applied":true]
        default:throw DriverError("未知操作")
        }
    }
    struct DriverError:LocalizedError {let message:String;init(_ message:String){self.message=message};var errorDescription:String?{message}}
}

#if !MIKA_LOCAL_RUNNER
extension DeviceControlTests {
    func testServeMika() throws {
        guard let token=ProcessInfo.processInfo.environment["MIKA_LOCAL_TOKEN"],token.count>=32 else {throw XCTSkip("本机服务仅由显式授权的手机启动器启动")}
        continueAfterFailure=false
        let server=LocalControlServer(token:token)
        try server.start()
        defer {server.stop()}
        XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote").activate()
        while !server.stopped {RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
    }
}

extension DeviceControlTests {
    /// Tests the HTTP driver on the physical phone. This does not prove the
    /// separate on-device bootstrap; the latter has its own acceptance check.
    @MainActor func testLocalControlDriver() async throws {
        let token=UUID().uuidString+UUID().uuidString
        let server=LocalControlServer(token:token)
        try server.start()
        defer {server.stop()}
        let session=URLSession(configuration:.ephemeral)
        func request(_ action:[String:Any]?,authorized:Bool=true) async throws -> (Int,[String:Any]) {
            var req=URLRequest(url:URL(string:"http://127.0.0.1:8123"+(action == nil ? "/status" : "/control"))!)
            if authorized {req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
            if let action {req.httpMethod="POST";req.httpBody=try JSONSerialization.data(withJSONObject:action);req.setValue("application/json",forHTTPHeaderField:"Content-Type")}
            let (data,response)=try await session.data(for:req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0,try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:])
        }
        var ready=false
        for _ in 0..<20 {
            if let response=try? await request(nil),response.0==200 {ready=true;break}
            try await Task.sleep(nanoseconds:100_000_000)
        }
        XCTAssertTrue(ready)
        let unauthorized=try await request(nil,authorized:false)
        XCTAssertEqual(401,unauthorized.0)
        let launch=try await request(["action":"launch","bundle_id":"com.apple.Preferences","return_to_mika":true])
        XCTAssertEqual(200,launch.0)
        XCTAssertEqual(true,launch.1["applied"] as? Bool)
        let source=try await request(["action":"source","bundle_id":"com.apple.Preferences","return_to_mika":true])
        XCTAssertEqual(200,source.0)
        XCTAssertGreaterThan((source.1["elements"] as? [[String:Any]])?.count ?? 0,0)
        XCUIApplication(bundleIdentifier:"com.huapohen.mikaremote").launch()
        let tap=try await request(["action":"tap","bundle_id":"com.huapohen.mikaremote","label":"菜单"])
        XCTAssertEqual(200,tap.0)
        let menu=try await request(["action":"source","bundle_id":"com.huapohen.mikaremote"])
        let labels=(menu.1["elements"] as? [[String:Any]] ?? []).compactMap {$0["label"] as? String}
        XCTAssertTrue(labels.contains("连接设备"))
    }
}

#endif
