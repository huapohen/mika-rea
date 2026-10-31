import Foundation
import NetworkExtension
import Combine

/// Owns only Mika's optional embedded packet-tunnel configuration.
@MainActor final class MikaTunnelManager:ObservableObject {
    static let shared=MikaTunnelManager()
    private var manager:NETunnelProviderManager?
    @Published var proxyEnabled=UserDefaults.standard.bool(forKey:"mikaIntegratedProxy") {didSet {UserDefaults.standard.set(proxyEnabled,forKey:"mikaIntegratedProxy")}}
    @Published private(set) var hasProxyConfig=false
    private var proxyFile:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("IntegratedProxy/config.yaml")}
    init() {hasProxyConfig=FileManager.default.fileExists(atPath:proxyFile.path)}
    func importProxy(_ data:Data) throws {
        guard data.count>0,data.count<=2_000_000,String(data:data,encoding:.utf8) != nil else {throw Model.Issue.message("请选择 2 MB 以内的 UTF-8 Clash YAML 配置。")}
        try FileManager.default.createDirectory(at:proxyFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:proxyFile,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        hasProxyConfig=true
    }
    var embedded:Bool {
        guard let plugins=Bundle.main.builtInPlugInsURL else {return false}
        return FileManager.default.fileExists(atPath:plugins.appendingPathComponent("MikaLocalTunnel.appex").path)
    }
    func enable() async throws {
        guard embedded else {throw Model.Issue.message("此签名版本未包含本地隧道扩展。")}
        let managers:[NETunnelProviderManager]=try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences {managers,error in
                if let error {continuation.resume(throwing:error)} else {continuation.resume(returning:managers ?? [])}
            }
        }
        let identifier=(Bundle.main.bundleIdentifier ?? "com.huapohen.mikaremote")+".local-tunnel"
        let selected=managers.first {($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier==identifier} ?? NETunnelProviderManager()
        let configuration=NETunnelProviderProtocol()
        configuration.providerBundleIdentifier=identifier
        configuration.serverAddress="10.7.0.1"
        if proxyEnabled {
            guard let yaml=try? String(contentsOf:proxyFile,encoding:.utf8),!yaml.isEmpty else {throw Model.Issue.message("请先导入 Clash YAML 配置。")}
            configuration.providerConfiguration=["proxyYaml":yaml]
        }
        selected.protocolConfiguration=configuration
        selected.localizedDescription="Mika 本机控制隧道"
        selected.isEnabled=true
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            selected.saveToPreferences {error in if let error {continuation.resume(throwing:error)} else {continuation.resume()}}
        }
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            selected.loadFromPreferences {error in if let error {continuation.resume(throwing:error)} else {continuation.resume()}}
        }
        manager=selected
        if selected.connection.status != .connected {try selected.connection.startVPNTunnel()}
        for _ in 0..<100 {
            if selected.connection.status == .connected {return}
            try await Task.sleep(nanoseconds:200_000_000)
        }
        throw Model.Issue.message("Mika 本地隧道尚未连接，请检查系统 VPN 授权。")
    }
    func stop() {manager?.connection.stopVPNTunnel()}
}
