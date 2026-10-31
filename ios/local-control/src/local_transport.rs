//! Route diagnostics contain interface metadata and socket outcomes only.
use std::{net::{Ipv4Addr,SocketAddr},os::fd::AsRawFd,time::Duration};
use tokio::net::TcpSocket;

#[derive(Clone)]
struct TunnelInterface {name:String,index:u32,ip:Ipv4Addr}

fn tunnel_interfaces(peer:Ipv4Addr)->Vec<TunnelInterface> {
    let mut result=Vec::new();
    #[cfg(any(target_os="ios",target_os="macos"))]
    unsafe {
        let mut head: *mut libc::ifaddrs=std::ptr::null_mut();
        if libc::getifaddrs(&mut head)!=0 {return result}
        let mut cursor=head;
        while !cursor.is_null() {
            let item=&*cursor;
            if !item.ifa_addr.is_null() && (*item.ifa_addr).sa_family as i32==libc::AF_INET && !item.ifa_name.is_null() {
                let name=std::ffi::CStr::from_ptr(item.ifa_name).to_string_lossy();
                let addr=&*(item.ifa_addr as *const libc::sockaddr_in);
                let ip=Ipv4Addr::from(addr.sin_addr.s_addr.to_ne_bytes());
                if name.starts_with("utun") && ip.octets()[..2]==peer.octets()[..2] {
                    result.push(TunnelInterface{name:name.into_owned(),index:libc::if_nametoindex(item.ifa_name),ip});
                }
            }
            cursor=item.ifa_next;
        }
        libc::freeifaddrs(head);
    }
    result
}

async fn connect(peer:Ipv4Addr,port:u16,interface:Option<&TunnelInterface>,bind_address:bool,bind_interface:bool)->Result<(),std::io::Error> {
    let socket=TcpSocket::new_v4()?;
    if let Some(interface)=interface {
        if bind_address {socket.bind(SocketAddr::from((interface.ip,0)))?;}
        #[cfg(any(target_os="ios",target_os="macos"))]
        if bind_interface {
            let index:libc::c_uint=interface.index;
            let value=unsafe {libc::setsockopt(socket.as_raw_fd(),libc::IPPROTO_IP,libc::IP_BOUND_IF,&index as *const _ as *const libc::c_void,std::mem::size_of_val(&index) as libc::socklen_t)};
            if value!=0 {return Err(std::io::Error::last_os_error())}
        }
    }
    let _stream=socket.connect(SocketAddr::from((peer,port))).await?;
    Ok(())
}

pub fn probe(host:&str)->String {
    let Ok(peer)=host.parse::<Ipv4Addr>() else {return "{\"invalid_address\":true}".into()};
    if !peer.is_private() && !peer.is_loopback() {return "{\"invalid_address\":true}".into()}
    let interfaces=tunnel_interfaces(peer);
    let Ok(runtime)=tokio::runtime::Builder::new_current_thread().enable_all().build() else {return "{\"runtime_failed\":true}".into()};
    let checks=runtime.block_on(async {
        let mut checks=Vec::new();
        for port in [49152,62078] {
            for mode in ["default","bind_address","bind_interface","bind_both"] {
                let interface=if mode=="default" {None} else {interfaces.first()};
                if mode!="default" && interface.is_none() {checks.push(serde_json::json!({"port":port,"mode":mode,"no_tunnel_interface":true}));continue}
                let result=tokio::time::timeout(Duration::from_secs(3),connect(peer,port,interface,mode=="bind_address" || mode=="bind_both",mode=="bind_interface" || mode=="bind_both")).await;
                checks.push(match result {
                    Ok(Ok(()))=>serde_json::json!({"port":port,"mode":mode,"connected":true}),
                    Ok(Err(error))=>serde_json::json!({"port":port,"mode":mode,"connected":false,"os_error":error.raw_os_error(),"kind":format!("{:?}",error.kind())}),
                    Err(_)=>serde_json::json!({"port":port,"mode":mode,"connected":false,"timeout":true}),
                });
            }
        }
        checks
    });
    serde_json::json!({"peer":peer.to_string(),"interfaces":interfaces.iter().map(|v|serde_json::json!({"name":v.name,"index":v.index,"address":v.ip.to_string()})).collect::<Vec<_>>(),"checks":checks}).to_string()
}
