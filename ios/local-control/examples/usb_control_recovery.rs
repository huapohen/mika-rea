//! Maintenance only: start the installed phone driver over trusted USB.
//! Never use this bridge as evidence of standalone on-phone control.
use idevice::{IdeviceError, IdeviceService, provider::IdeviceProvider, services::{installation_proxy::InstallationProxyClient, dvt::xctest::{TestConfig,XCUITestService,listener::XCUITestListener}}, usbmuxd::{UsbmuxdAddr,UsbmuxdConnection}};
use std::{io::Write,os::unix::fs::OpenOptionsExt,sync::Arc};

struct Listener;
impl XCUITestListener for Listener {
    async fn test_case_did_start(&mut self,_class:&str,_method:&str)->Result<(),IdeviceError> {
        println!("USB maintenance driver started; this is not standalone acceptance."); Ok(())
    }
}
#[tokio::main(flavor="current_thread")]
async fn main() {
    if let Err(error)=run().await {
        eprintln!("USB maintenance failed (code {}); private details suppressed.",error.code());
        std::process::exit(1);
    }
}
async fn run()->Result<(),IdeviceError> {
    let args:Vec<String>=std::env::args().collect();
    assert_eq!(args.len(),4,"Usage: usb_control_recovery DEVICE_UDID PRIVATE_TOKEN_PATH NEW_PRIVATE_ENDPOINT_PATH");
    let token=std::fs::read_to_string(&args[2])?.trim().to_owned();
    assert!(token.len()>=32,"Maintenance token too short");
    let mut mux=UsbmuxdConnection::default().await?;
    let device=mux.get_devices().await?.into_iter()
        .find(|d| d.udid==args[1] && d.connection_type==idevice::usbmuxd::Connection::Usb)
        .ok_or(IdeviceError::DeviceNotFound)?;
    let provider:Arc<dyn IdeviceProvider>=Arc::new(device.to_provider(UsbmuxdAddr::default(),"Mika USB maintenance"));
    let mut proxy=InstallationProxyClient::connect(provider.as_ref()).await?;
    let mut cfg=TestConfig::from_installation_proxy(&mut proxy,"com.huapohen.mikaremote.local-runner.xctrunner",None).await?;
    cfg.tests_to_run=Some(vec!["MikaLocalControlTests/testServeMika".into()]);
    let mut env=plist::Dictionary::new();env.insert("MIKA_LOCAL_TOKEN".into(),token.into());cfg.runner_env=Some(env);
    let listener=tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST,0)).await?;
    let endpoint=format!("http://127.0.0.1:{}",listener.local_addr()?.port());
    let mut output=std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&args[3])?;
    output.write_all(endpoint.as_bytes())?;
    let forwarding=provider.clone();
    let bridge=async move {
        loop {
            let (mut local,_)=listener.accept().await?;
            let remote=forwarding.clone();
            tokio::spawn(async move {
                if let Ok(phone)=remote.connect(8123).await {
                    if let Some(mut socket)=phone.get_socket() {
                        let _=tokio::io::copy_bidirectional(&mut local,&mut socket).await;
                    }
                }
            });
        }
        #[allow(unreachable_code)] Ok::<(),IdeviceError>(())
    };
    let service=XCUITestService::new(provider);
    let mut events=Listener;
    tokio::select! {
        result=bridge=>result,
        result=service.run(cfg,&mut events,Some(std::time::Duration::from_secs(300)))=>result,
    }
}
