//! Device-side bootstrap using the MIT-licensed idevice library.
//! The pairing record stays on the user's phone. No cloud or Mac runtime is used.
use idevice::{
    IdeviceError, IdeviceService,
    pairing_file::PairingFile,
    provider::RsdProvider,
    provider::TcpProvider,
    remote_pairing::{
        RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
    },
    rsd::RsdHandshake,
    services::{
        dvt::xctest::{TestConfig, XCUITestService, listener::XCUITestListener},
        installation_proxy::InstallationProxyClient,
    },
};
use std::{
    ffi::{CStr, CString, c_char},
    net::IpAddr,
    sync::{Arc, Mutex, OnceLock},
    thread,
    time::Duration,
};
use tokio::sync::oneshot;

struct LauncherState {
    status: String,
    detail: String,
    stop: Option<oneshot::Sender<()>>,
    generation: u64,
}
static STATE: OnceLock<Mutex<LauncherState>> = OnceLock::new();
fn state() -> &'static Mutex<LauncherState> {
    STATE.get_or_init(|| {
        Mutex::new(LauncherState {
            status: "stopped".into(),
            detail: "".into(),
            stop: None,
            generation: 0,
        })
    })
}
fn update(generation: u64, status: &str, detail: &str) {
    if let Ok(mut s) = state().lock() {
        if s.generation == generation {
            s.status = status.into();
            s.detail = detail.into();
        }
    }
}
struct Listener {
    generation: u64,
}
impl XCUITestListener for Listener {
    async fn test_case_did_start(
        &mut self,
        _class: &str,
        _method: &str,
    ) -> Result<(), IdeviceError> {
        update(self.generation, "running", "本机执行器已启动");
        Ok(())
    }
    async fn test_runner_ready_with_capabilities(&mut self) -> Result<(), IdeviceError> {
        update(self.generation, "starting", "正在建立本机自动化会话");
        Ok(())
    }
}
unsafe fn copy_string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

/// Copies input strings before returning. The caller retains ownership of the C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mika_local_start(
    pair_path: *const c_char,
    host: *const c_char,
    runner: *const c_char,
    token: *const c_char,
) -> i32 {
    let (Some(pair), Some(host), Some(runner), Some(token)) = (
        unsafe { copy_string(pair_path) },
        unsafe { copy_string(host) },
        unsafe { copy_string(runner) },
        unsafe { copy_string(token) },
    ) else {
        return -1;
    };
    if token.len() < 32 {
        return -1;
    }
    let Ok(ip) = host.parse::<IpAddr>() else {
        return -1;
    };
    // LocalDevVPN's device endpoint; never forward a pairing record to an arbitrary server.
    if !matches!(ip,IpAddr::V4(v) if v.octets()[0]==10 || v.octets()[0]==127 || (v.octets()[0]==192&&v.octets()[1]==168))
    {
        return -1;
    }
    let (mut_tx, rx) = oneshot::channel();
    let generation;
    {
        let Ok(mut s) = state().lock() else {
            return -1;
        };
        if s.stop.is_some() {
            return 1;
        }
        s.generation += 1;
        generation = s.generation;
        s.status = "starting".into();
        s.detail = "正在连接手机自身的开发服务".into();
        s.stop = Some(mut_tx);
    }
    thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build();
        let result = match runtime {
            Err(_) => Err("运行环境初始化失败".to_owned()),
            Ok(runtime) => runtime.block_on(async move {
                let operation = async {
                    let bytes = std::fs::read(&pair)
                        .map_err(|_| "配对文件不可用，请重新导入".to_owned())?;
                    let bundle: plist::Dictionary =
                        plist::from_bytes(&bytes).map_err(|_| "配对文件格式无效".to_owned())?;
                    if bundle.contains_key("MIKA_RemotePairing") {
                        return run_remote(bundle, ip, &runner, token, generation).await;
                    }
                    let pairing = PairingFile::read_from_file(pair)
                        .map_err(|_| "配对文件不可用，请重新导入".to_owned())?;
                    let provider = Arc::new(TcpProvider {
                        addr: ip,
                        scope_id: None,
                        pairing_file: pairing,
                        label: "Mika Local Control".into(),
                    });
                    let mut proxy = tokio::time::timeout(
                        Duration::from_secs(15),
                        InstallationProxyClient::connect(provider.as_ref()),
                    )
                    .await
                    .map_err(|_| "本机连接超时，请开启 LocalDevVPN 并解锁手机".to_owned())?
                    .map_err(|e| {
                        format!(
                            "旧式开发服务连接失败（代码 {}），请重新导出新版配对记录",
                            e.code()
                        )
                    })?;
                    let mut cfg = TestConfig::from_installation_proxy(&mut proxy, &runner, None)
                        .await
                        .map_err(|_| "本机执行器未安装或签名已过期".to_owned())?;
                    cfg.tests_to_run = Some(vec!["MikaLocalControlTests/testServeMika".into()]);
                    let mut env = plist::Dictionary::new();
                    env.insert("MIKA_LOCAL_TOKEN".into(), plist::Value::String(token));
                    cfg.runner_env = Some(env);
                    let service = XCUITestService::new(provider);
                    let mut listener = Listener { generation };
                    service
                        .run(cfg, &mut listener, None)
                        .await
                        .map_err(|_| "自动化会话已中断，请解锁设备并重新启动".to_owned())
                };
                tokio::select! { result=operation=>result,_=rx=>Ok(()) }
            }),
        };
        if let Ok(mut s) = state().lock() {
            if s.generation == generation {
                s.stop = None;
                match result {
                    Ok(()) => {
                        s.status = "stopped".into();
                        s.detail = "本机控制已停止".into();
                    }
                    Err(detail) => {
                        s.status = "failed".into();
                        s.detail = detail;
                    }
                }
            }
        }
    });
    0
}
#[unsafe(no_mangle)]
pub extern "C" fn mika_local_stop() {
    if let Ok(mut s) = state().lock() {
        if let Some(stop) = s.stop.take() {
            let _ = stop.send(());
        }
        s.generation += 1;
        s.status = "stopped".into();
        s.detail = "本机控制已停止".into();
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn mika_local_status() -> *mut c_char {
    let value = match state().lock() {
        Ok(s) => serde_json::json!({"status":s.status,"detail":s.detail}),
        Err(_) => serde_json::json!({"status":"failed","detail":"本机控制状态读取失败"}),
    };
    CString::new(value.to_string()).unwrap().into_raw()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mika_local_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            drop(CString::from_raw(value));
        }
    }
}

fn safe_error(stage: &str, error: IdeviceError) -> String {
    // The library's code 1 means every socket I/O error, not POSIX EPERM.
    // Keep the OS number/kind without displaying arbitrary peer/error text.
    if let IdeviceError::Socket(ref io) = error {
        let hint = if stage == "连接新版配对端口" && io.kind() == std::io::ErrorKind::ConnectionRefused {
            "。请确认手机已连接 Wi-Fi，且 LocalDevVPN 已连接，再点重连"
        } else { "" };
        return format!("{stage}失败（网络 {:?}，系统代码 {}）{hint}", io.kind(), io.raw_os_error().unwrap_or(-1));
    }
    format!("{stage}失败（代码 {}）", error.code())
}

#[cfg(test)]
mod diagnostics_tests {
    use super::*;
    #[test]
    fn socket_diagnostics_distinguish_failures_without_echoing_private_text() {
        let refused = safe_error("连接", std::io::Error::from(std::io::ErrorKind::ConnectionRefused).into());
        let denied = safe_error("连接", std::io::Error::from(std::io::ErrorKind::PermissionDenied).into());
        assert_ne!(refused, denied);
        let private = safe_error("连接", std::io::Error::other("private-server-response").into());
        assert!(!private.contains("private-server-response"));
    }
}
async fn run_remote(
    bundle: plist::Dictionary,
    ip: IpAddr,
    runner: &str,
    token: String,
    generation: u64,
) -> Result<(), String> {
    let remote = bundle.get("MIKA_RemotePairing").ok_or("缺少新版配对记录")?;
    let mut remote_bytes = Vec::new();
    plist::to_writer_xml(&mut remote_bytes, remote).map_err(|_| "新版配对记录格式无效")?;
    let mut pairing =
        RpPairingFile::from_bytes(&remote_bytes).map_err(|e| safe_error("读取新版配对记录", e))?;
    let info = bundle
        .get("MIKA_RunnerInfo")
        .and_then(|v| v.as_dictionary())
        .ok_or("缺少执行器安装信息，请重新运行安装脚本")?;
    let field = |key: &str| {
        info.get(key)
            .and_then(|v| v.as_string())
            .map(str::to_owned)
            .ok_or_else(|| "执行器安装信息不完整".to_owned())
    };
    let mut cfg = TestConfig {
        runner_bundle_id: runner.into(),
        runner_app_path: field("Path")?,
        runner_app_container: field("Container")?,
        runner_bundle_executable: field("CFBundleExecutable")?,
        target_bundle_id: None,
        target_app_path: None,
        target_app_env: None,
        target_app_args: None,
        tests_to_run: Some(vec!["MikaLocalControlTests/testServeMika".into()]),
        tests_to_skip: None,
        runner_env: None,
        runner_args: None,
    };
    let version = bundle
        .get("MIKA_iOSMajorVersion")
        .and_then(|v| v.as_unsigned_integer())
        .ok_or("缺少系统版本信息")? as u8;
    update(generation, "starting", "正在连接新版本机配对通道");
    let stream = tokio::time::timeout(
        Duration::from_secs(8),
        tokio::net::TcpStream::connect((ip, 49152)),
    )
    .await
    .map_err(|_| "新版配对端口连接超时，请检查本地隧道")?
    .map_err(|e| safe_error("连接新版配对端口", e.into()))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), "Mika Local Control");
    tokio::time::timeout(Duration::from_secs(15), async {
        client.attempt_pair_verify().await?;
        client.validate_pairing(&mut pairing).await
    })
    .await
    .map_err(|_| "新版配对验证超时")?
    .map_err(|e| safe_error("新版配对验证", e))?;
    let port = client
        .create_tcp_listener()
        .await
        .map_err(|e| safe_error("创建本机开发通道", e))?;
    let stream = tokio::net::TcpStream::connect((ip, port))
        .await
        .map_err(|e| safe_error("连接开发通道", e.into()))?;
    let tunnel = connect_tls_psk_tunnel_native(stream, client.encryption_key())
        .await
        .map_err(|e| safe_error("开发通道握手", e))?;
    let ours = tunnel
        .info
        .client_address
        .parse::<IpAddr>()
        .map_err(|_| "开发通道本地地址无效")?;
    let theirs = tunnel
        .info
        .server_address
        .parse::<IpAddr>()
        .map_err(|_| "开发通道设备地址无效")?;
    let rsd_port = tunnel.info.server_rsd_port;
    let mut adapter =
        idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), ours, theirs);
    adapter.set_mss(1400);
    let mut handle = adapter.to_async_handle();
    let stream = handle
        .connect_to_service_port(rsd_port)
        .await
        .map_err(|e| safe_error("开发服务连接", e))?;
    let handshake = RsdHandshake::new(stream)
        .await
        .map_err(|e| safe_error("开发服务发现", e))?;
    update(generation, "starting", "正在启动手机自身的自动化执行器");
    let mut env = plist::Dictionary::new();
    env.insert("MIKA_LOCAL_TOKEN".into(), plist::Value::String(token));
    cfg.runner_env = Some(env);
    let mut listener = Listener { generation };
    XCUITestService::run_with_rsd(cfg, version, handle, handshake, &mut listener, None)
        .await
        .map_err(|e| safe_error("手机自动化会话", e))
}
