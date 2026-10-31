//! Read-only screenshot for local diagnostics; save to a private ignored path.
use idevice::{IdeviceService, RsdService, core_device_proxy::CoreDeviceProxy, dvt::{remote_server::RemoteServerClient, screenshot::ScreenshotClient}, rsd::RsdHandshake, usbmuxd::{UsbmuxdAddr, UsbmuxdConnection}};
use std::{io::Write, os::unix::fs::OpenOptionsExt};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(args.len(), 3, "Usage: usb_screenshot DEVICE_UDID PRIVATE_OUTPUT_PATH");
    let result = tokio::time::timeout(std::time::Duration::from_secs(30), capture(&args[1])).await;
    match result {
        Ok(Ok(bytes)) => {
            let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&args[2]).expect("Cannot create private screenshot");
            file.write_all(&bytes).expect("Cannot save screenshot");
            println!("Screenshot saved privately.");
        },
        Ok(Err(error)) => { eprintln!("Screenshot unavailable (code {}).", error.code()); std::process::exit(1); },
        Err(_) => { eprintln!("Screenshot timed out."); std::process::exit(1); },
    }
}

async fn capture(udid: &str) -> Result<Vec<u8>, idevice::IdeviceError> {
    let mut mux = UsbmuxdConnection::default().await?;
    let device = mux.get_devices().await?.into_iter()
        .find(|d| d.udid == udid && d.connection_type == idevice::usbmuxd::Connection::Usb)
        .ok_or(idevice::IdeviceError::DeviceNotFound)?;
    let provider = device.to_provider(UsbmuxdAddr::default(), "Mika read-only screenshot");
    let proxy = CoreDeviceProxy::connect(&provider).await?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
    let stream = adapter.connect(rsd_port).await?;
    let mut handshake = RsdHandshake::new(stream).await?;
    let mut client = RemoteServerClient::connect_rsd(&mut adapter, &mut handshake).await?;
    client.read_message(0).await?;
    ScreenshotClient::new(&mut client).await?.take_screenshot().await
}
