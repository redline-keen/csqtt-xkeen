// SPDX-FileCopyrightText: 2026 amurcanov
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

use anyhow::{Context, Result, bail};
use std::{fs::OpenOptions, os::fd::AsRawFd};

#[cfg(target_os = "linux")]
const TUNSETIFF: libc::c_ulong = 0x4004_54ca;
#[cfg(target_os = "linux")]
const SIOCGIFFLAGS: libc::c_ulong = 0x8913;
#[cfg(target_os = "linux")]
const SIOCSIFFLAGS: libc::c_ulong = 0x8914;
#[cfg(target_os = "linux")]
const SIOCSIFADDR: libc::c_ulong = 0x8916;
#[cfg(target_os = "linux")]
const SIOCSIFNETMASK: libc::c_ulong = 0x891c;
#[cfg(target_os = "linux")]
const SIOCSIFMTU: libc::c_ulong = 0x8922;

#[cfg(target_os = "linux")]
const IFF_TUN: u16 = 0x0001;
#[cfg(target_os = "linux")]
const IFF_NO_PI: u16 = 0x1000;
#[cfg(target_os = "linux")]
const IFF_UP: u16 = 0x0001;
#[cfg(target_os = "linux")]
const IFF_RUNNING: u16 = 0x0040;
#[cfg(target_os = "linux")]
const IFNAMSIZ: usize = 16;

#[cfg(target_os = "linux")]
#[repr(C)]
struct IfReq {
    data: [u8; 40],
}

#[cfg(target_os = "linux")]
impl IfReq {
    fn new(name: &str) -> Result<Self> {
        if name.is_empty() || name.len() >= IFNAMSIZ {
            bail!("некорректное имя TUN интерфейса: {name}");
        }
        let mut data = [0u8; 40];
        data[..name.len()].copy_from_slice(name.as_bytes());
        Ok(Self { data })
    }

    fn flags(&mut self, value: u16) {
        self.data[16..18].copy_from_slice(&value.to_ne_bytes());
    }

    fn flags_value(&self) -> u16 {
        u16::from_ne_bytes(self.data[16..18].try_into().unwrap())
    }

    fn mtu(&mut self, value: i32) {
        self.data[16..20].copy_from_slice(&value.to_ne_bytes());
    }

    fn sockaddr_in(&mut self, address: [u8; 4]) {
        // struct sockaddr_in at ifr.ifr_addr (offset 16):
        // sin_family, sin_port, sin_addr, sin_zero[8].
        self.data[16..18].copy_from_slice(&(libc::AF_INET as u16).to_ne_bytes());
        self.data[18..20].copy_from_slice(&0u16.to_ne_bytes());
        self.data[20..24].copy_from_slice(&address);
        self.data[24..32].fill(0);
    }
}

#[cfg(target_os = "linux")]
fn ioctl(fd: libc::c_int, request: libc::c_ulong, ifr: &mut IfReq, operation: &str) -> Result<()> {
    let rc = unsafe { libc::ioctl(fd, request as libc::c_int, ifr as *mut IfReq) };
    if rc < 0 {
        return Err(std::io::Error::last_os_error()).context(operation.to_owned());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn control_socket() -> Result<libc::c_int> {
    let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error()).context("socket(AF_INET, SOCK_DGRAM)");
    }
    Ok(fd)
}

#[cfg(target_os = "linux")]
fn close_fd(fd: libc::c_int) {
    unsafe {
        libc::close(fd);
    }
}

#[cfg(target_os = "linux")]
fn set_nonblocking(fd: libc::c_int) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error()).context("F_GETFL");
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error()).context("F_SETFL O_NONBLOCK");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn set_up(name: &str) -> Result<()> {
    let fd = control_socket()?;
    let result = (|| {
        let mut ifr = IfReq::new(name)?;
        ioctl(fd, SIOCGIFFLAGS, &mut ifr, "SIOCGIFFLAGS")?;
        ifr.flags(ifr.flags_value() | IFF_UP | IFF_RUNNING);
        ioctl(fd, SIOCSIFFLAGS, &mut ifr, "SIOCSIFFLAGS")
    })();
    close_fd(fd);
    result
}

#[cfg(target_os = "linux")]
fn set_mtu(name: &str, mtu: u32) -> Result<()> {
    if !(576..=65535).contains(&mtu) {
        bail!("некорректный TUN MTU: {mtu}");
    }
    let fd = control_socket()?;
    let result = (|| {
        let mut ifr = IfReq::new(name)?;
        ifr.mtu(mtu as i32);
        ioctl(fd, SIOCSIFMTU, &mut ifr, "SIOCSIFMTU")
    })();
    close_fd(fd);
    result
}

#[cfg(target_os = "linux")]
fn set_ipv4(name: &str, octets: [u8; 4]) -> Result<()> {
    let fd = control_socket()?;
    let result = (|| {
        let mut ifr = IfReq::new(name)?;
        ifr.sockaddr_in(octets);
        ioctl(fd, SIOCSIFADDR, &mut ifr, "SIOCSIFADDR")
    })();
    close_fd(fd);
    result
}

#[cfg(target_os = "linux")]
fn set_netmask_32(name: &str) -> Result<()> {
    set_ipv4_with_ioctl(name, SIOCSIFNETMASK, [255, 255, 255, 255], "SIOCSIFNETMASK")
}

#[cfg(target_os = "linux")]
fn set_ipv4_with_ioctl(
    name: &str,
    request: libc::c_ulong,
    octets: [u8; 4],
    operation: &str,
) -> Result<()> {
    let fd = control_socket()?;
    let result = (|| {
        let mut ifr = IfReq::new(name)?;
        ifr.sockaddr_in(octets);
        ioctl(fd, request, &mut ifr, operation)
    })();
    close_fd(fd);
    result
}

#[cfg(target_os = "linux")]
pub fn create(name: &str, mtu: u32) -> Result<std::fs::File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/net/tun")
        .context("не удалось открыть /dev/net/tun")?;

    let fd = file.as_raw_fd();
    let mut ifr = IfReq::new(name)?;
    ifr.flags(IFF_TUN | IFF_NO_PI);
    ioctl(fd, TUNSETIFF, &mut ifr, "TUNSETIFF")?;
    set_nonblocking(fd)?;

    let actual_name = std::str::from_utf8(&ifr.data[..IFNAMSIZ])
        .unwrap_or(name)
        .trim_end_matches('\0')
        .to_owned();

    set_mtu(&actual_name, mtu)?;
    set_up(&actual_name)?;

    crate::log_error!(
        "[TUN] Интерфейс создан: {actual_name}, MTU={mtu}"
    );

    Ok(file)
}

#[cfg(target_os = "linux")]
pub fn configure(name: &str, ip: &str) -> Result<()> {
    let octets: [u8; 4] = ip
        .parse::<std::net::Ipv4Addr>()
        .with_context(|| format!("некорректный TUN IPv4 адрес: {ip}"))?
        .octets();

    set_ipv4(name, octets)?;
    set_netmask_32(name)?;
    set_up(name)?;

    crate::log_error!("[TUN] Конфигурация: {name} = {ip}/32");
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn create(_name: &str, _mtu: u32) -> Result<std::fs::File> {
    bail!("встроенный TUN поддерживается только на Linux");
}

#[cfg(not(target_os = "linux"))]
pub fn configure(_name: &str, _ip: &str) -> Result<()> {
    bail!("на этой платформе настройка TUN недоступна");
}


