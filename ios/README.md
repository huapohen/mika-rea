# Mika iPhone 客户端

这是基于 Mika 界面和远程接口开发的 SwiftUI 客户端，保留 Android 上游源码。它包含原生聊天、网页/文本阅读、历史对话、模型配置、安卓远程任务和 iPhone 本机控制。

## 已验收

- iPhone 15 Pro 真机及模拟器：侧边菜单、设置与返回、模型页、连接页、输入及发送按钮。
- iPhone 15 Pro 真机：Keychain 中的 DeepSeek 配置可访问实际模型。
- iPhone → `qinziduihua.com/mika-rea` → 安卓：任务往返及实际打开安卓系统设置、返回 Android 16。
- iPhone 15 Pro / iOS 26.6.2：由手机自身启动 XCTest 执行器，打开系统设置、读屏、滑动画面、点击搜索框、输入并读回验证。五项检查通过，测试输入已清空。该测试没有 Mac XCTest 会话或控制网关参与动作执行。

本机控制实现与前提见 [local-control/README.md](local-control/README.md)。配对记录保存在手机，模型密钥和控制会话令牌保存在 Keychain，临时导入后删除引导文件。

## 两种隧道构建

免费签名的标准构建使用 App Store LocalDevVPN 的本地回环；开启它会与另一个设备级 packet tunnel（如 Clash Mi）发生切换，不能据此宣称两者独立共存。

一体化构建将本地回环与 Mihomo 代理放入同一个 NetworkExtension。已实现 Clash YAML 导入、代理开关、单隧道分流，内核包转发测试、arm64 模拟器和 iPhone 架构的无签名构建已通过。合并扩展还没有真机签名验收：当前三个 Apple 账号均为 Personal Team，Apple 实际拒绝其 Network Extensions 能力。需要具备该权限的开发团队。

```sh
# 标准构建
scripts/build-ios-local-control.sh
MIKA_IOS_UDID=<真机 UDID> scripts/install-ios-local-control.sh

# 含代理及隧道扩展：需有效开发团队，付费团队 ID 由本人提供
MIKA_IOS_VARIANT=all-in-one MIKA_TEAM_ID=<团队 ID> \
  MIKA_IOS_UDID=<真机 UDID> scripts/install-ios-local-control.sh
```

构建使用 Xcode、XcodeGen、Rust aarch64-apple-ios；合并代理另需 Go。依赖来源和许可证见 `integrations/localdevvpn/`、`integrations/clashmi/` 及 `licenses/`。当前原生库构建脚本面向 arm64 iPhone 和 Apple Silicon 模拟器。

## 仍需完成

本项目尚不是 Android Mika 全功能的逐项移植。远程控制另一台 iPhone、手机重启后的恢复、重签更新流程、Clash Mi 全部订阅/节点管理界面，以及 iOS 的文件沙箱、定时任务、记忆等尚需实现或验收。

iPhone 本机控制需要设备解锁、开发者模式、有效执行器签名、本地开发连接和开发支持。会话按前台操作与短暂切换设计，不承诺在锁屏或长期后台状态控制其他 App。付费或免费签名权限都不会绕过系统解锁和 App 本人验证。

真实 DeepSeek 模型端到端验收已通过：手机侧连续调用 10 次工具进入“设置 → 通用 → 关于本机”，读回 iOS 26.6.2 后返回 Mika。脱敏证据位于 `ios/evidence/local-agent-acceptance.json`（以仓库根目录为起点）。

## 远程任务恢复

任务的设备地址、任务编号、所属会话和对话编号会保护保存在手机；任务令牌单独存入 Keychain。重开 App 后可点“查看”接回原设备任务，即使连接页后来切换过目标，也不会把旧任务送到新设备。提交超时不会自动重发；连接页可以查看并接回最近任务。停止请求会继续核实远端状态，解除本机关联则明确保留远端任务可能继续运行的事实。

`MikaUnitTests` 的两项集成测试验证了重启恢复、令牌与设备固定、避免重复提交。新版本还在真机读回了安卓最近四项任务，且 iPhone 本机模型任务复测通过。

第三方 App 真机验收也已通过：Mika 的真实模型工具打开 Clash Mi，点按“关于”，读回安装版本 1.0.31.1703 后切回 Mika。未切换 VPN 或修改配置。脱敏工具记录在 `ios/evidence/third-party-control-acceptance.json`。

## iOS 悬浮胶囊

新增 Android Mika 风格的应用内悬浮胶囊：可拖动并吸附左右边缘，点按展开输入卡片、发送任务、回答追问、查看进度与停止。设置 → 悬浮胶囊可选择关闭、任务期间或总是显示。收起后仅胶囊本身接收触摸，底下页面可正常操作。

离开 Mika 后用 WidgetKit / ActivityKit 显示灵动岛与锁屏实时活动，长按可查看和停止，点按返回 Mika。选择“总是显示”且本机执行器已就绪时，会保留控制会话入口。系统胶囊只显示通用状态，不包含任务正文、API Key 或读屏内容。

这是 iOS 原生适配：不会在桌面或任意其他 App 上绘制安卓式自由悬浮球，也不会通过画中画伪造视频来维持后台。实时活动不提供额外后台运行权限，显示和过期行为由系统管理。无灵动岛的机型可使用锁屏实时活动。

已使用现有免费开发团队在 iPhone 15 Pro 真机签名、安装并验证：输入卡片、拖动、显示开关、底层触摸透传、回桌面长按灵动岛、系统按钮回调及结束确认。另有四项测试覆盖本机请求取消、旧按钮不能停止新任务、远程任务恢复及提交超时不重发。证据见 `ios/evidence/capsule-acceptance.json`，截图见 `ios/evidence/capsule-app.png`。
