import Foundation

enum ProviderGenerationPolicy {
    static func apply(_ input:[String:Any],base:String,thinking:Bool,effort:String)->[String:Any] {
        var result=input
        guard URL(string:base)?.host?.lowercased()=="api.deepseek.com" else {return result}
        result["thinking"]=["type":thinking ? "enabled" : "disabled"]
        if thinking {result["reasoning_effort"]=["low","high","max"].contains(effort) ? effort : "low"}
        else {result.removeValue(forKey:"reasoning_effort")}
        return result
    }
}

extension Model {
    func providerBody(_ input:[String:Any]) throws ->Data {
        try JSONSerialization.data(withJSONObject:ProviderGenerationPolicy.apply(input,base:base,thinking:thinkingEnabled,effort:reasoningEffort))
    }
    #if DEBUG
    func runFastProviderProbeIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--mika-fast-provider-probe"),!apiKey.isEmpty else {return}
        base="https://api.deepseek.com/v1";model="deepseek-flash";thinkingEnabled=false;reasoningEffort="low"
        var report:[String:Any]=["model":model,"thinking":"disabled","effort_when_enabled":"low"]
        let started=Date()
        do {
            var request=URLRequest(url:URL(string:base+"/chat/completions")!);request.httpMethod="POST";request.timeoutInterval=45
            request.setValue("Bearer "+apiKey,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody=try providerBody(["model":model,"messages":[["role":"user","content":"仅回复 MIKA_FAST_OK，不要调用工具。"]],"max_tokens":128])
            let (data,response)=try await providerSession.data(for:request)
            let value=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            let message=(value?["choices"] as? [[String:Any]])?.first?["message"] as? [String:Any]
            let usage=value?["usage"] as? [String:Any]
            let details=usage?["completion_tokens_details"] as? [String:Any]
            report["http_status"]=(response as? HTTPURLResponse)?.statusCode ?? 0
            report["marker_confirmed"]=(message?["content"] as? String)?.contains("MIKA_FAST_OK")==true
            report["reasoning_tokens"]=details?["reasoning_tokens"] ?? usage?["reasoning_tokens"] ?? NSNull()
            report["reasoning_content_empty"]=(message?["reasoning_content"] as? String ?? "").isEmpty
        } catch {report["failed"]=true}
        report["elapsed_seconds"]=Date().timeIntervalSince(started);report["timestamp"]=ISO8601DateFormatter().string(from:Date())
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("FastProviderAcceptance.json")
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) {try? data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
    }
    #endif
}
