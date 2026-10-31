# Mika REA 手机中继

该服务只转交 Mika MCP 请求；不接收或存储模型 API Key。安卓连接助手和 iPhone 受控端主动轮询中继，因此无需对手机开放公网端口。控制端与设备端使用不同令牌，按设备 ID 隔离。

部署地址：`https://qinziduihua.com/mika-rea`。健康检查：`GET /health`。受保护接口：`POST /v1/{device}/rpc`（控制端令牌）、`next` 和 `result`（设备端令牌）、`status`（控制端令牌）。每个请求使用 `Authorization: Bearer ...`。

## 部署

- 服务为 Python 标准库程序，不需下载依赖。建议 Python 3.9+。
- 创建本机配对：`python3 relay/server.py --config .local/relay.json --create-device myphone`。此文件包含令牌，权限为 600，不应提交或公开。
- iPhone 受控端创建配对时增加 `--platform ios`；使用 `relay/export_pairing.py` 导出分开的 `client.json`、`agent.json`，导入说明见 [iOS 说明](../ios/README.md#iphone-接收远程协助)。已有设备 ID 不会被覆盖。
- 上传 `relay/server.py`、`deploy/install-relay.sh` 和配对配置（重命名为 `relay.json`）到已授权服务器的同一个私有目录，执行安装脚本。
- 当前安装脚本适用于已有 Caddy 域名 `qinziduihua.com` 的 Ubuntu 服务器。它备份并增加独立的子路径路由、创建独立服务用户、将 Python 服务绑定到回环地址，并使用 systemd 管理。其他域名或环境应先修改脚本。

安卓端运行 `android-bridge`，填写中继地址、设备 ID、设备端令牌和本机 Mika MCP 地址/令牌，然后点「保存并开启连接」。通知栏提供停止入口。iPhone 在「菜单 → 连接设备」选安卓及中继，填写同一中继地址、设备 ID、控制端令牌。公网必须使用 HTTPS。

## 验证

`python3 -m unittest discover -s relay -p 'test_*.py' -v` 验证 HTTP 请求往返、鉴权角色隔离、跨设备结果隔离、超时清理、工具白名单和请求体大小上限。

设备新长轮询会原子替换旧轮询，旧连接不能抢走新连接的命令。2026-10-31 新增测试覆盖 App 重连时的这一竞态；配置导出角色隔离及原配对保留也有测试，合计 6 项通过。此机制不自动重放已派发或结果未知的命令，任务恢复仍应查询手机已存记录。

2026-10-31：公网服务健康检查正常；安卓设备成功出站连接；iPhone 15 Pro 的 `testRelayAndroid` 真机测试通过，完成了 iPhone → 腾讯云 HTTPS 中继 → 安卓 Mika → iPhone 的模型任务往返。`testRelayPhoneControl` 同日通过，验证了打开安卓系统设置并返回版本的操作任务。

## 使用限制

- iOS 受控能力由手机自己的开发执行器提供，不由中继绕过系统权限。需机主开启远程协助、本机执行器、解锁并保持 Mika 前台。已验收模拟器控制端到一台真实 iPhone；两台实体 iPhone 与跨省实测尚未完成。
- 当前请求队列和设备在线状态在内存中，服务重启会中断未完成的 HTTP 请求。Mika 的手机端任务是否仍在执行，应通过 `mika_list_tasks` 检查，不应盲目重复提交有副作用的任务。
- 中继服务可看到转交的请求和结果；日志不记录令牌和任务内容。仅与已明确同意的设备配对。
- 安卓端的 Mika MCP 和手机助手需要保持可用。若使用 USB 模式令牌，手机重启后需重新启用；日常独立使用建议在安卓 Mika 完成无线调试配对并使用 Wi-Fi 模式的持久令牌。
