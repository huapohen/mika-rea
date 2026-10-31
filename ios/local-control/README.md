# iPhone 本机控制

Mika 在手机自身建立 RemotePairing 开发通道，启动独立 XCTest 执行器。不需要 Mac 在运行时维护 XCTest 会话。实现使用 MIT 许可的 idevice 固定版本，原许可证与小范围修改说明位于 `vendor/idevice/`。

## 真机结果（2026-10-31）

iPhone 15 Pro / iOS 26.6.2 已通过：手机端启动、打开系统设置、读取控件、滑动后读回画面变化、点击搜索框、输入标记并读回验证。测试输入随后被清空。五项验收结果均为 true；本轮使用手机已安装的 LocalDevVPN。

Mac 在测试开始前只负责签名、安装、导出并传入此手机的配对记录及启动 App。未运行 Mac 端 xcodebuild test、WDA 网关或网络转发进程来执行这些验收动作。

这不代表重启后、签名过期后或任意第三方 App 都已验收。当前需开发者模式、已挂载的开发支持、有效签名、设备解锁及本地隧道。免费开发签名有期限。远程控制另一台 iPhone 尚未完成。

## 组成

- Rust：RemotePairing → TLS-PSK CDTunnel → 软件 TCP 栈 → RSD → XCTest 会话。
- `LocalControlRunner`：仅包含一个长期运行的控制测试，与普通 UI 测试隔离。
- `LocalControlServer.swift`：仅监听 `127.0.0.1:8123`，强制每会话令牌，支持启动、读屏、点击、输入、滑动与停止。
- `OnDeviceControl.swift`：本机启停、钥匙串令牌、配对记录保护、有限前后台切换与明确失败。
- `LocalPhoneAgent.swift`：真实模型工具循环，将模型请求送往本机执行器。

配对记录属于设备凭据，只保存本机，不能提交或上传中继。`mika-pair-export` 输出受限权限文件，不打印密钥。初次安装及重签后执行：

```sh
MIKA_IOS_UDID=<已信任的真机 UDID> scripts/install-ios-local-control.sh
```

启动 Mika → 设置 → 本机控制。未集成隧道的免费签名版本需要单独开启 LocalDevVPN。含代理的合并隧道构建见 `integrations/clashmi/README.md`，需要支持 Network Extensions 的开发团队。

验收使用 DEBUG 专用启动参数 `--mika-local-control-probe`，输出不含控件正文或凭据的 `Documents/LocalControlAcceptance.json`。普通用户启动不会自动操作其他 App。

真实 DeepSeek 模型端到端验收已通过：手机侧连续调用 10 次工具进入“设置 → 通用 → 关于本机”，读回 iOS 26.6.2 后返回 Mika。脱敏证据位于 `ios/evidence/local-agent-acceptance.json`（以仓库根目录为起点）。
