# iOS 控制链路调查

参考：
- REA https://github.com/morluto/rea
- 本地 REA `docs/apple-application-analysis.md`：Apple 应用清单和结构分析；不是设备控制驱动。
- Appium XCUITest https://appium.github.io/appium-xcuitest-driver/latest/getting-started/device-setup/ ：真机驱动、配对、开发者模式、签名等准备条件。

应区分两条路径：普通 iPhone 应用在自身沙箱内运行；Mac 可以通过已配对设备上的 XCUITest runner 执行 UI 测试。后者可以作为 iPhone 客户端远程发起设备操作的执行端，但要求 Mac 在线和设备测试会话可用。

仓库新增 `DeviceControlTests.testLaunchSettings`，用于验证在实际设备启动系统设置并等待导航栏。该测试是驱动能力探测，不是已完成的远程控制服务。运行脚本：`MIKA_IOS_UDID=<device-id> scripts/test-ios-device-control.sh`。

后续集成需要：带鉴权的 Mac 网关、设备会话管理、界面读取与操作驱动、客户端设备选择、任务队列和模型工具调度。测试探测通过也不代表支付、锁屏、安全界面和无人值守均可控制。
