# LocalDevVPN 本地隧道集成

Mika 的本地回环隧道基于 [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN)，原作者 Stossy11 / SideStore Team。使用公开源码进行分析，没有反编译 App Store 安装包。

参照提交：`af3fd697803ada4ac2b8d518358f5ab0a534844c`。原许可证全文在 [LICENSE](LICENSE)，原提供者文件在 `Reference/`，实际适配实现位于 `ios/MikaLocalTunnel/MikaPacketTunnelProvider.swift`。

REA 的 `import-reference-source` 已建立源码参照，authority 为 `historical-reference`，解析失败数为 0。机器路径及完整索引保存在本机被忽略的 `.local/evidence/localdevvpn-reference.json`。

本地接口为 `10.7.1.1/32`，开发服务映射地址为 `10.7.0.1/32`。本地模式仅接管映射地址；合并代理模式还接管普通 IPv4/IPv6 流量。本机开发数据包直接反射回系统，不发送至代理节点或公网中继。

含隧道扩展的构建使用 `ios/project.all-in-one.yml`，必须由支持 Network Extensions 的开发团队签名。2026-10-31 的实际签名尝试被 Apple 拒绝：当前 Personal Team 不支持此能力。已安装的 App Store LocalDevVPN 可用于免费签名版本的本机控制，但与 Clash Mi 的设备级 packet tunnel 不能作为两个独立隧道同时工作。

合并版本采用同一个扩展处理两种流量。代码集成不会为免费签名账号增加 Apple 权限。详情见 `integrations/clashmi/README.md`。
