# Mika iPhone 伴侣（实验版）

原版 Mika 是 Android 应用。本目录是独立的 SwiftUI iOS 客户端，不是 Kotlin/JVM 核心的完整移植。仓库其余目录保留原项目源码。

## 已实现

- iPhone 模式：使用 OpenAI 兼容的 HTTPS Chat Completions 接口聊天，密钥存入 iOS Keychain。内置浏览器可由用户选择读取网页正文，作为后续模型请求的上下文；可以清除已读取的正文。
- 安卓模式：连接 Android Mika 的 Streamable HTTP MCP，提交任务、等待结果、回答问题、继续查看和停止任务。同一会话中的后续任务复用对话编号。对方手机必须运行 Mika 并开启「电脑连接（MCP）→ Wi-Fi 和私有网络」。付款和需要用户接管的操作仍在安卓设备上处理。

在 iPhone 的 Mika 设置里分别配置模型地址、模型名称、API Key，以及 Android Mika 显示的 MCP 地址和令牌。MCP 的 HTTP 传输未加密，只用于可信私有网络；令牌不要公开。

## 尚未实现和平台限制

- 不支持控制另一台 iPhone，也不能在本机后台读取或操作任意第三方 iOS App。iOS 不提供与 Android 无障碍和虚拟屏幕等价的通用接口。
- 未移植 Mika Android 的完整代理核心、自动网页操作、文件沙箱、定时任务、记忆、ChatGPT 登录、后台任务和其他 Android 功能。
- 对话保存在设备本机，支持侧边菜单选择历史对话；当前任务编号也会保存。已读取网页和文件只保存在本次运行内存中。长任务受 iOS 前后台调度约束。
- 当前只对电脑到安卓 MCP 和安卓实际手机操作做过端到端验证，iPhone 到安卓的连接尚需在真机配置后验证。

## 构建

执行 `xcodegen generate --spec ios/project.yml`，在 Xcode 选择可用的开发团队签名后运行。团队 ID 是本机配置，其他开发者需更换。

## iPhone 界面更新（2026-10-31）

参考 Android `ChatScreen.kt`、`ChatDrawer.kt`、`SettingsScreen.kt` 和 `theme/Colors.kt`，重写为 SwiftUI。包含问候语和任务示例卡、侧边菜单、历史对话、底部输入与文本附件、分组设置、模型连接测试、直连/中继配置与连接检查、内置浏览器。

验证：`DeviceControlTests.testNavigationAndInput` 在 iPhone 15 Pro 模拟器和已连接的 iPhone 15 Pro 真机均通过，覆盖打开菜单、设置→模型→返回、设备连接页→返回、文本输入及发送按钮状态。截图见 `evidence/home.png`。

远程中继服务代码在 `relay/`，安卓连接助手在 `android-bridge/`。中继已部署至 `https://qinziduihua.com/mika-rea`，`testRelayAndroid` 在 iPhone 15 Pro 真机通过，验证了模型任务经公网中继到达安卓并返回结果。`testRelayPhoneControl` 也在 iPhone 15 Pro 真机通过，完成了打开安卓系统设置并返回版本的任务。

模型配置已支持从设备本地一次性导入文件存入钥匙串，导入后删除临时文件。`testConfiguredProvider` 在 iPhone 15 Pro 真机测试通过，确认 DeepSeek 模型列表请求成功。凭据不进入仓库。
