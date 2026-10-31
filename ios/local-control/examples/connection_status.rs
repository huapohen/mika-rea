//! USB diagnostics. A separate explicit flag enables trusted wireless debugging.
//! Never dumps a pairing record or device dictionary.
use idevice::{IdeviceService, provider::IdeviceProvider, services::lockdown::LockdownClient, usbmuxd::{UsbmuxdAddr, UsbmuxdConnection}};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("USB status unavailable (code {}); credentials suppressed.", error.code());
        std::process::exit(1);
    }
}

async fn run() -> Result<(), idevice::IdeviceError> {
    let udid = std::env::args().nth(1).expect("Usage: connection_status DEVICE_UDID");
    let mut mux = UsbmuxdConnection::default().await?;
    let record = mux.get_pair_record(&udid).await?;
    let device = mux.get_devices().await?.into_iter()
        .find(|d| d.udid == udid && d.connection_type == idevice::usbmuxd::Connection::Usb)
        .ok_or(idevice::IdeviceError::DeviceNotFound)?;
    let provider = device.to_provider(UsbmuxdAddr::default(), "Mika read-only USB status");
    let mut client = LockdownClient::connect(&provider).await?;
    client.start_session(&record).await?;
    let change = match std::env::args().nth(2).as_deref() {
        Some("--enable-wifi-debugging") => Some(true),
        Some("--disable-wifi-debugging") => Some(false),
        None => None,
        _ => panic!("Unknown option"),
    };
    if let Some(enabled) = change {
        client.set_value("EnableWifiDebugging", enabled.into(), Some("com.apple.mobile.wireless_lockdown")).await?;
    }
    for key in ["EnableWifiDebugging", "EnableWifiConnections"] {
        let value = client.get_value(Some(key), Some("com.apple.mobile.wireless_lockdown")).await;
        match value.ok().and_then(|v| v.as_boolean()) {
            Some(enabled) => println!("{key}: {enabled}"),
            None => println!("{key}: unavailable"),
        }
    }
    client.shutdown().await?;
    match tokio::time::timeout(std::time::Duration::from_secs(5), provider.connect(49152)).await {
        Ok(Ok(_)) => println!("RemotePairing listener via USB: reachable"),
        Ok(Err(error)) => println!("RemotePairing listener via USB: unavailable (code {})", error.code()),
        Err(_) => println!("RemotePairing listener via USB: timed out"),
    }
    Ok(())
}
