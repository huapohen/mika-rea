//! One-time cable provisioning; cryptographic material is never printed.
use idevice::{
    IdeviceService,
    remote_pairing::{RemotePairingLockdownService, RpPairingFile},
    services::{installation_proxy::InstallationProxyClient, lockdown::LockdownClient},
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};
use std::{io::Write, os::unix::fs::OpenOptionsExt};
fn main() {
    if let Err(code) = run() {
        eprintln!("Device provisioning failed (code {code}); credentials suppressed.");
        std::process::exit(1)
    }
}
fn run() -> Result<(), i32> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: mika-pair-export DEVICE_UDID PRIVATE_OUTPUT_PATH");
        return Err(-1);
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| -2)?;
    runtime.block_on(async {
        let mut mux = UsbmuxdConnection::default().await.map_err(|e| e.code())?;
        let record = mux.get_pair_record(&args[1]).await.map_err(|e| e.code())?;
        let device = mux.get_devices().await.map_err(|e| e.code())?.into_iter()
            .find(|d| d.udid == args[1] && d.connection_type == idevice::usbmuxd::Connection::Usb)
            .ok_or(-7)?;
        let provider = device.to_provider(UsbmuxdAddr::default(), "Mika USB Provisioning");
        let mut lockdown = LockdownClient::connect(&provider)
            .await
            .map_err(|e| e.code())?;
        lockdown
            .start_session(&record)
            .await
            .map_err(|e| e.code())?;
        let version = lockdown
            .get_value(Some("ProductVersion"), None)
            .await
            .map_err(|e| e.code())?;
        let version = version
            .as_string()
            .and_then(|s| s.split('.').next())
            .and_then(|s| s.parse::<u64>().ok())
            .ok_or(-3)?;
        lockdown.shutdown().await.map_err(|e| e.code())?;
        let mut proxy = InstallationProxyClient::connect(&provider)
            .await
            .map_err(|e| e.code())?;
        let apps = proxy
            .get_apps(
                None,
                Some(vec![
                    "com.huapohen.mikaremote.local-runner.xctrunner".into(),
                ]),
            )
            .await
            .map_err(|e| e.code())?;
        let runner = apps
            .get("com.huapohen.mikaremote.local-runner.xctrunner")
            .cloned()
            .ok_or(-4)?;
        let service = RemotePairingLockdownService::connect(&provider)
            .await
            .map_err(|e| e.code())?;
        let mut client = service
            .into_client("Mika Local Control")
            .map_err(|e| e.code())?;
        let mut remote = RpPairingFile::generate("Mika Local Control");
        // The upstream trusted-USB pairing flow uses the protocol setup value 000000.
        // The OS trust relationship has already been established by the device owner.
        client
            .connect(&mut remote, async || "000000".to_owned())
            .await
            .map_err(|e| e.code())?;
        let bytes = record.serialize().map_err(|e| e.code())?;
        let mut bundle: plist::Dictionary = plist::from_bytes(&bytes).map_err(|_| -5)?;
        bundle.insert(
            "MIKA_RemotePairing".into(),
            plist::from_bytes(&remote.to_bytes()).map_err(|_| -5)?,
        );
        bundle.insert("MIKA_RunnerInfo".into(), runner);
        bundle.insert(
            "MIKA_iOSMajorVersion".into(),
            plist::Value::Integer(version.into()),
        );
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &bundle).map_err(|_| -5)?;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&args[2])
            .map_err(|_| -6)?;
        file.write_all(&bytes).map_err(|_| -6)?;
        println!("Trusted USB provisioning exported; credentials suppressed.");
        Ok(())
    })
}
