# Mika iPhone 客户端

这是基于 Mika 界面和远程接口开发的 SwiftUI 客户端，保留 Android 上游源码。它包含原生聊天、网页/文本阅读、历史对话、模型配置、安卓远程任务和 iPhone 本机控制。

## 已验收

- iPhone 15 Pro 真机及模拟器：侧边菜单、设置与返回、模型页、连接页、输入及发送按钮。
- iPhone 15 Pro 真机：Keychain 中的 DeepSeek 配置可访问实际模型。
- iPhone → `qinziduihua.com/mika-rea` → 安卓：任务往返及实际打开安卓系统设置、返回 Android 16。
- iPhone 15 Pro / iOS 26.6.2：由手机自身启动 XCTest 执行器，打开系统设置、读屏、滑动画面、点击搜索框、输入并读回验证。五项检查通过，测试输入已清空。该测试没有 Mac XCTest 会话或控制网关参与动作执行。

本机控制实现与前提见 [local-control/README.md](local-control/README.md)。配对记录保存在手机，模型密钥和控制会话令牌保存在 Keychain，临时导入后删除引导文件。

### 原生闹钟与响应速度

聊天中“帮我订明天早上 9:40 的闹钟”等明确时间请求直接走 AlarmKit，不调用模型、不依赖 XCTest、VPN、电脑或 Wi-Fi。支持一次、每天、工作日、每周指定日和分钟/小时后的常用中文时间。不能可靠解析的日期、复合请求及删除请求不会被快速路径擅自解释为今天的闹钟。原生闹钟在「设置 → Mika 闹钟」管理，与苹果「时钟」App 的闹钟列表分开。

创建前请求系统闹钟权限，创建后按唯一 ID 与预期时间从系统读回才报告成功；不确定结果不会自动重复提交。记录损坏时保留原文件并拒绝覆盖。取消只针对 Mika 自己记录的 ID，并核实系统已不再列出。

2026-10-31 真机：iPhone 15 Pro / iOS 26.6.2，Wi-Fi 关闭、5G 可用，创建一分钟后的临时闹钟后锁屏。测试前后 CoreDevice 均报告需要解锁；系统闹钟状态进入 `alerting` 后取消并读回确认清理。该轮没有 Mac XCTest 驱动，USB 仍接在电脑上用于部署和读取测试结果，未实测物理拔线，也没有录音证明声学输出。[验收记录](evidence/native-alarm-acceptance.json) 明确记录范围。

新增「创建 Mika 闹钟」App Intent 与 Siri 快捷入口，参数为响铃日期时间，`openAppWhenRun=false`，`authenticationPolicy=alwaysAllowed`；首次权限必须先在 App 授予。这是受限的原生动作，不赋予锁屏读屏、点按其他 App 的能力。Siri 真机调用和锁屏创建仍待验证，不能用上述锁屏响铃测试代替。[Apple 身份验证策略](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy)。

官方 DeepSeek 默认 `deepseek-flash`、关闭思考；开启时强度默认 `low`，关闭时不发送冲突的 `reasoning_effort`。只向官方 DeepSeek 域名应用此策略，其他供应商参数不变。手机上用现有 Keychain 凭据验证 HTTP 200、标记回答正确、思考内容为空，简单请求约 0.71 秒；该结果不是整个手机任务耗时，也不将服务端缺省的思考 token 字段记为零。[模型验收](evidence/fast-provider-acceptance.json)。

纯 5G 的任意 App 控制仍未通过：[传输探测](evidence/cellular-control-probe.json) 中 LocalDevVPN 已连接，默认、绑定本地地址、绑定隧道接口和同时绑定四种方式访问 49152 / 62078 全部被拒绝。扩大本地回环路由也未成功。原生闹钟可绕开这条依赖，但不代表其他 App 控制已恢复。

### 本机控制断连恢复

Mika 会保存本人开启或停止本机控制的选择。重开和回到前台时，已开启的控制会尝试恢复；未连接时顶部显示灰色状态和「重连」，不再把手机操作请求悄悄降级到普通聊天。明确停止后不会自动开启。

2026-10-31 的回退由真机 UI 测试临时替换本项目的执行器、测试失败后未恢复引起；现场同时发现 Wi-Fi 已从控制中心断开，LocalDevVPN 虽显示已连接，本地 RemotePairing 端口仍返回 ConnectionRefused（系统代码 61）。装回执行器并连接已保存的 Wi-Fi 后，关闭 Mac 临时维护会话，手机自身启动恢复。真实模型再次进入系统设置读回 iOS 26.6.2，进入 Clash Mi 关于页读回 1.0.31.1703，并分别返回 Mika。仅 5G 的本机控制尚未验收通过，不能把 VPN 的连接状态当成执行器可用。

物理设备 UI 测试脚本现在先验证私有恢复包及签名有效期，结束时自动恢复并等待手机报告 ready；失败会返回非零状态。USB 维护工具只选择实际 USB 设备，不用同 UDID 的网络发现记录。维护会话不作为手机独立运行的验收证据。

### 连续操作与页面切换

「设置 → 本机控制 → 执行模式」提供三种选择，下一项任务生效；本机和接收远程协助的任务都使用机主配置。

- 后台运行（默认）：iOS 26 上申请用户发起的持续后台任务，只请求 CPU/网络，立即运行或失败，不将手机操作排队到未来某个时间。系统不给持续执行时间时使用短时预算，时间不足就在原 App 暂停，胶囊提示本人点回 Mika 后继续，不靠反复切页续时。系统取消则停止后续操作。
- 连续操作：停留在目标 App 连续处理，短时后台预算不足时返回 Mika 续接。
- 兼容模式：每一步返回 Mika。

「完成后返回 Mika」独立配置，默认关闭。用户本次任务明确要求返回、需要本人回答时仍会返回。启动、点按、输入和滑动后直接读取最新控件，减少模型往返。暂停恢复会核实本机连接并作废旧画面；重新读屏前不派发点按、输入或滑动。同一模型答复包含多个操作时，后续写入需根据新画面重新决定，不能一次沿用多个旧坐标。后台时间由系统决定，不能承诺任意时长或锁屏执行；过期后不会重试尚未核实的写入。官方接口说明见 [Apple 持续后台任务](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados)。

验证分开记录：上一版连续操作已在真机完成 Clash Mi 的 12 次执行器调用，以及设置中的 7 次调用，均无每步返回和预算触发返回，最后按测试任务要求回到 Mika。新增后台模式已有单元测试、模拟器设置切换与重开持久化测试、免费团队签名构建通过。模拟器中的系统调度器注册通过，提交返回 unavailable，未获得持续运行时间；暂停、恢复、过期、取消路径通过注入的运行环境验证。设置测试暂时关闭独立胶囊窗口以隔离 AX 命中点问题；胶囊真机已有独立验收。系统实际授权、超过短时预算后的读屏点按和系统取消仍需真机验收；包含后台配置、低延迟模型策略和原生闹钟的候选包现已安装。

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

本项目尚不是 Android Mika 全功能的逐项移植。两台实体 iPhone 的联调、手机重启后的本机执行器恢复、重签更新流程、Clash Mi 全部订阅/节点管理界面，以及 iOS 的文件沙箱、定时任务、记忆等尚需实现或验收。

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

## iPhone 接收远程协助

新增 iOS 受控端：另一台客户端经公网中继提交任务，由受控 iPhone 自己的模型和本机执行器操作 App。接收端需要先完成本机控制配置和模型设置，然后在「设置 → 接收远程协助」导入 `agent.json`，主动开启连接。接收默认关闭，重开 App 不会自动开启；页面、主页提示条和胶囊显示状态，均可停止后续操作。不要把受控端令牌分享给控制端。

控制端在「连接设备 / 手机操作」导入 `client.json`，选择「远程 iPhone」和 HTTPS 中继。控制端无需取得受控手机的模型 API Key。生成配置文件：

```sh
python3 relay/server.py --config .local/relay.json --create-device myiphone --platform ios
python3 relay/export_pairing.py --config .local/relay.json --device myiphone \
  --relay https://qinziduihua.com/mika-rea --output .local/pairing/myiphone
```

新设备配对还需合并到服务器私有配置并重启中继。导出的两个文件分别交给对应设备，文件包含连接凭据，不要提交 Git、公开链接或发到聊天中。

受控端一次执行一项任务，任务记录和会话保存在本机。带 `request_id` 的重复提交返回原任务；同编号不同内容被拒绝。进程中断后的任务标记失败，不自动重放，控制端可查看已有任务并接回结果。会话继续可提交同一 `conversation` 的后续任务。结构化追问、确认和本人操作交接见下节。

2026-10-31 联调通过：iOS 模拟器客户端 → `qinziduihua.com/mika-rea` → iPhone 15 Pro 真机执行器，读回 Clash Mi 1.0.31.1703 和 iOS 26.6.2；从控制端胶囊停止另一项任务，真机记录确认已取消。运行期间受控手机的胶囊和灵动岛均显示运行状态。另有三项受控任务测试与四项既有恢复/取消测试通过。证据见 `ios/evidence/remote-ios-acceptance.json`。

这项验收没有覆盖两台实体 iPhone、真实跨省网络、锁屏或长期后台执行。受控手机需保持解锁、Mika 前台及本机隧道可用；切到目标 App 是短暂执行步骤，完成后返回 Mika。实时活动不授予后台执行权限，也不能替代本机隧道。

## 追问、确认与本人操作

本机和远程 iPhone 任务均支持 `ask_user`、`request_confirmation`、`hand_to_user`。缺少信息时暂停当前工具调用，主界面或胶囊显示问题，可点选建议或输入回答；需要确认时提供明确的同意和拒绝按钮。等待期间不派发后续手机操作。系统实时活动仅显示通用“需要处理”状态，不显示问题正文。

每一问有独立 `interaction.id`。远程 `mika_answer` 需要 `task_id`、`interaction_id`、`text`，不能用旧答案推进下一问；同一问的重复回答不再执行一遍，相同编号但内容冲突会被拒绝。选择或确认的结果返回原模型工具调用，继续原任务，保留工具上下文。等待最多 15 分钟，超时、取消、进程重启都不会作为同意或本人已完成处理。模型调用 `end_not_done` 或达到步数上限时，任务会标记未完成。

`hand_to_user` 将任务标为 `waiting_on_phone`，只能由受控手机本人在主界面或胶囊交还控制；控制端无法代替本人确认。机主可点“打开目标 App，交给我操作”，在目标 App 完成后回到 Mika，点“我已处理，继续核实”或“跳过”。交还只代表允许继续核实，不代表登录、付款等已成功，模型须重新读屏检查。控制端会自动查询原设备、原任务的状态并继续更新，不重复提交任务。密码和验证码不要填入任务回答。

2026-10-31：15 项 iOS 单元测试、6 项中继测试通过。公网联调验证了提问选择、同意确认后读取真实 Clash Mi 版本、等待回答期间从胶囊停止且无手机动作，以及只读本人交接后重新读屏并自动回传结果。本人按钮使用手机现有执行器进行 UI 自动化点击，验证的是交接界面和流程，没有执行或验证真实登录、验证码、付款。中继同时修复了重连后旧长轮询取走新命令的问题。证据见 `ios/evidence/interaction-acceptance.json`。
