# Clash Mi 与本地开发隧道合并

依据用户要求，用 REA 分析 [KaringX/clashmi](https://github.com/KaringX/clashmi)，固定参照提交 `9bd053f9ab7a48437fc3985fd0d6fb5bd1cab5bb`。REA 索引记录 425 个文件、解析失败 0，原始证据保存在被 Git 忽略的 `.local/evidence/clashmi-reference.json`。

Clash Mi 的公开 Swift 提供者依赖其 `Libclash` 桥接框架；本项目没有复用来历不明的二进制。Mika 独立实现 C/Swift 桥接，使用 Clash Mi 所基于的公开 Mihomo 内核，固定 Go 源码为 `MetaCubeX/mihomo` 的 `Meta` 分支提交 `3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`。

## 实现

- `ios/proxy-core/`：Mihomo 配置解析、受限本机接口、Mips TCP/IP 栈、C ABI、数据包队列及测试。
- `patches/mihomo-packet-device.patch`：允许注入 NetworkExtension 的数据包设备，避免使用私有 KVC 提取 utun 文件描述符。
- `ios/MikaLocalTunnel/`：一个系统隧道同时承载代理与开发连接。
- `ios/MikaIOS/MikaTunnelManager.swift`：保护保存 YAML 配置、系统 VPN 配置和启停。

发送到 `10.7.0.1` 的本机开发数据包先进入回环分支；其他 IP 数据包进入 Mihomo。Swift 端使用公开 `packetFlow.readPackets/writePackets` 接口。此实现不启动第二个系统 VPN。

设置 → 本机控制 → 同一隧道中的代理，可导入现有 Clash YAML。配置仅存设备；不自动读取 Clash Mi 的应用沙箱或订阅凭据。此阶段实现内核与配置导入，尚未复刻 Clash Mi 的全部节点管理、订阅管理和仪表板界面。

## 构建与验证

先按本机网络条件选择可用代理或 Go 镜像，再执行：

```sh
scripts/build-ios-local-control.sh
scripts/build-ios-proxy-core.sh
xcodegen generate --spec ios/project.all-in-one.yml
```

Go 依赖由 `go.sum` 校验，Rust 依赖由 `Cargo.lock` 校验。原始固定提交归档后仅应用仓库中的补丁。当前原生输出支持 arm64 iPhone 和 Apple Silicon 模拟器。

```sh
go -C ios/proxy-core test -count=1 ./...
xcodebuild -project ios/MikaIOS.xcodeproj -scheme MikaIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

已通过本机反射隔离、畸形包拒绝、普通 UDP 经真实 Mihomo 栈转发、配置禁用外部控制器和额外监听器的测试，以及合并扩展的模拟器编译。没有付费开发团队，合并隧道尚未签名安装到真机，不能把编译通过当作代理与本机控制同时运行的真机验收。

原 Clash Mi 的 GPL-3.0 许可证在本目录，Mihomo GPL-3.0 许可证位于 `licenses/mihomo-GPL-3.0.txt`。代理桥接代码标注 GPL-3.0-or-later；LocalDevVPN 的来源、声明和许可证单独保留。对外分发时需同时保留并遵守各来源许可证及对应源码要求。
