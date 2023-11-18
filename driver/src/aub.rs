use std::time::Duration;

pub const GULP_VENDOR_ID: u16 = 0xFACE;

pub const GULP_INFO_SIZE: usize = 64;
pub const GULP_TIMEOUT: Duration = Duration::from_millis(10);
pub const PACKET_SIZE_HS: usize = 512;
pub const PACKET_SIZE_FS: usize = 64;

#[derive(Debug, Copy, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum RequestType {
    IN = rusb::RequestType::Vendor | rusb::fields::Direction::In,
    OUT = rusb::RequestType::Vendor | rusb::fields::Direction::Out,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum BulkEndpoint {
    IN = rusb::fields::Direction::In | 1,
    OUT = rusb::fields::Direction::Out | 1,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum REG {
    TSR = 0,
    TLR = 1,
    RSR = 2,
}

pub enum TSR_BIT {
    RDY = 1,
    LST = 2,
}

pub enum RSR_BIT {
    RDY = 1,
    LST = 2,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum DataWidth {
    None = 0,
    Byte = 1,
    Half = 2,
    Word = 3,
}

pub struct GulpConfig {
    pub channels: [u16; 2],
    pub usb_mode: u16,
}
