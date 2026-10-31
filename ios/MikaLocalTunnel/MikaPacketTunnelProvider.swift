// Local reflection mechanism based on jkcoxson/LocalDevVPN / SideStore Team.
// Original author: Stossy11. See integrations/localdevvpn/LICENSE.
// Mika uses one NetworkExtension for local developer packets and optional Mihomo routing.
import NetworkExtension

#if MIKA_PROXY_CORE
@_silgen_name("mika_proxy_start") private func proxyStart(_ yaml:UnsafePointer<CChar>,_ directory:UnsafePointer<CChar>)->Int32
@_silgen_name("mika_proxy_stop") private func proxyStop()
@_silgen_name("mika_proxy_input") private func proxyInput(_ data:UnsafePointer<UInt8>,_ length:Int32)->Int32
@_silgen_name("mika_proxy_read") private func proxyRead(_ data:UnsafeMutablePointer<UInt8>,_ capacity:Int32)->Int32
#endif

final class MikaPacketTunnelProvider:NEPacketTunnelProvider {
    private let state=NSLock()
    private var active=false
    private var proxy=false
    private var running:Bool {state.withLock {active}}
    override func startTunnel(options:[String:NSObject]?,completionHandler:@escaping(Error?)->Void) {
        let configuration=(protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let yaml=configuration?["proxyYaml"] as? String
        proxy=yaml?.isEmpty==false
        state.withLock {active=true}
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            if let yaml,!yaml.isEmpty {
                #if MIKA_PROXY_CORE
                let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("MikaProxy")
                let result=yaml.withCString {config in directory.path.withCString {path in proxyStart(config,path)}}
                guard result==0 else {state.withLock {active=false};completionHandler(NSError(domain:"MikaTunnel",code:Int(result),userInfo:[NSLocalizedDescriptionKey:"代理配置加载失败，请检查 Clash YAML 配置。"]));return}
                #else
                state.withLock {active=false}
                completionHandler(NSError(domain:"MikaTunnel",code:1,userInfo:[NSLocalizedDescriptionKey:"此构建未包含代理内核。"]));return
                #endif
            }
            configure(completionHandler)
        }
    }
    private func configure(_ completion:@escaping(Error?)->Void) {
        let settings=NEPacketTunnelNetworkSettings(tunnelRemoteAddress:"10.7.0.1")
        let addresses=proxy ? ["10.7.1.1","198.18.0.1"] : ["10.7.1.1"]
        let masks=proxy ? ["255.255.255.255","255.255.255.252"] : ["255.255.255.255"]
        let ipv4=NEIPv4Settings(addresses:addresses,subnetMasks:masks)
        let local=NEIPv4Route(destinationAddress:"10.7.0.1",subnetMask:"255.255.255.255")
        ipv4.includedRoutes=proxy ? [local,.default()] : [local]
        ipv4.excludedRoutes=proxy ? [] : [.default()]
        settings.ipv4Settings=ipv4
        settings.mtu=1500
        if proxy {
            let ipv6=NEIPv6Settings(addresses:["fdfe:dcba:9876::1"],networkPrefixLengths:[126])
            ipv6.includedRoutes=[.default()];settings.ipv6Settings=ipv6
            let dns=NEDNSSettings(servers:["198.18.0.2"]);dns.matchDomains=[""];settings.dnsSettings=dns
        }
        setTunnelNetworkSettings(settings) { [weak self] error in
            if error==nil,let self {self.readPackets();if self.proxy {self.readProxyOutput()}}
            else {self?.shutdown()}
            completion(error)
        }
    }
    override func stopTunnel(with reason:NEProviderStopReason,completionHandler:@escaping()->Void) {shutdown();completionHandler()}
    private func shutdown() {
        state.withLock {active=false}
        #if MIKA_PROXY_CORE
        if proxy {proxyStop()}
        #endif
    }
    private func readPackets() {
        guard running else {return}
        packetFlow.readPackets { [weak self] packets,protocols in
            guard let self,self.running else {return}
            if self.proxy {
                #if MIKA_PROXY_CORE
                for packet in packets {packet.withUnsafeBytes {buffer in if let ptr=buffer.baseAddress?.assumingMemoryBound(to:UInt8.self) {_ = proxyInput(ptr,Int32(buffer.count))}}}
                #endif
            } else {
                var output:[Data]=[];var families:[NSNumber]=[]
                for (index,packet) in packets.enumerated() {
                    guard protocols[index].int32Value==AF_INET,packet.count>=20,packet[0]>>4==4,
                          Array(packet[16..<20])==[10,7,0,1] else {continue}
                    var reflected=packet
                    for offset in 0..<4 {reflected[12+offset]=packet[16+offset];reflected[16+offset]=packet[12+offset]}
                    output.append(reflected);families.append(protocols[index])
                }
                if !output.isEmpty {self.packetFlow.writePackets(output,withProtocols:families)}
            }
            self.readPackets()
        }
    }
    private func readProxyOutput() {
        #if MIKA_PROXY_CORE
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var bytes=[UInt8](repeating:0,count:65535)
            while let self,self.running {
                let count=bytes.withUnsafeMutableBufferPointer {proxyRead($0.baseAddress!,Int32($0.count))}
                if count>0 {
                    let packet=Data(bytes.prefix(Int(count)))
                    let family=packet[0]>>4==6 ? AF_INET6 : AF_INET
                    self.packetFlow.writePackets([packet],withProtocols:[NSNumber(value:family)])
                } else if count<0 {
                    if self.running {self.cancelTunnelWithError(NSError(domain:"MikaTunnel",code:2,userInfo:[NSLocalizedDescriptionKey:"代理内核已停止。请重新连接。 "]))}
                    return
                }
            }
        }
        #endif
    }
}
