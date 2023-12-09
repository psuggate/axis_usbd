use clap::Parser;
use log::{debug, error, info, LevelFilter};
use rusb::Context;
use simple_logger::SimpleLogger;
use std::time::Duration;

use driver::{axis_usb::*, common::*};

#[derive(Parser, Debug, Clone)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Verbosity
    #[arg(short, long, value_name = "LEVEL")]
    log_level: Option<String>,

    #[arg(short, long, default_value = "false")]
    read_first: bool,

    #[arg(short, long, default_value = "false")]
    no_read: bool,

    #[arg(short, long, default_value = "false")]
    writeless: bool,

    #[arg(short, long, default_value = "50")]
    delay: usize,

    #[arg(short, long, default_value = "20")]
    size: usize,

    #[arg(short, long, default_value = "32")]
    chunks: usize,

    #[arg(short, long, default_value = "false")]
    packet_mode: bool,

    #[arg(short, long, default_value = "false")]
    telemetry: bool,

    /// Verbosity of generated output?
    #[arg(short, long, action = clap::ArgAction::Count)]
    verbose: u8,
}

fn tart_read(args: &Args, tart: &mut AxisUSB) -> Result<Vec<u8>, rusb::Error> {
    if args.no_read {
        return Ok(Vec::new());
    }

    let bytes: Vec<u8> = match tart.try_read(None) {
        Ok(xs) => xs,
        Err(e) => {
            error!("TART read failed: {:?}", e);
            Vec::new()
        }
    };

    if args.packet_mode {
        if tart.write_register(0x2, 0u16, None)? == 2 {
            debug!("REG_WRITE RSR = 0");
        }
    }
    if args.packet_mode {
        let rsr = tart.read_register(0x2, None)?;
        debug!("REG_READ RSR = {}", rsr);
    }
    info!("RECEIVED (bytes = {}): {:?}", bytes.len(), &bytes);

    Ok(bytes)
}

fn to_state(seq: usize, lo: u8, hi: u8) -> String {
    let state = match hi >> 4 {
        0x01 => "ST_IDLE",
        0x02 => "ST_CTRL",
        0x04 => "ST_BULK",
        0x08 => "ST_DUMP",
        _ => "- XXX -",
    };
    let xctrl = match hi & 0x0f {
        0x00 => "CTL_DONE      ",
        0x01 => "CTL_SETUP_RX  ",
        0x02 => "CTL_SETUP_ACK ",
        0x03 => "CTL_DATA_TOK  ",
        0x04 => "CTL_DATO_RX   ",
        0x05 => "CTL_DATO_ACK  ",
        0x06 => "CTL_DATI_TX   ",
        0x07 => "CTL_DATI_ACK  ",
        0x08 => "CTL_STATUS_TOK",
        0x09 => "CTL_STATUS_RX ",
        0x0a => "CTL_STATUS_TX ",
        0x0b => "CTL_STATUS_ACK",
        _ => "- UNKNOWN -   ",
    };
    let xbulk = match lo {
        0x01 => "BLK_IDLE    ",
        0x02 => "BLK_DATI_TX ",
        0x04 => "BLK_DATI_ZDP",
        0x08 => "BLK_DATI_ACK",
        0x10 => "BLK_DATO_RX ",
        0x20 => "BLK_DATO_ACK",
        0x40 => "BLK_DATO_ERR",
        0x80 => "BLK_DONE    ",
        _ => "- UNKNOWN - ",
    };

    format!("{:5}  ->  {{ {} : {} : {} }}", seq, state, xctrl, xbulk)
}

fn tart_telemetry(args: &Args, tart: &mut AxisUSB) -> TartResult<Vec<u8>> {
    let mut buf = [0; MAX_BUF_SIZE];
    let len = tart
        .handle
        .read_bulk(tart.telemetry.read_address(), &mut buf, DEFAULT_TIMEOUT)?;
    let res = Vec::from(&buf[0..len]);
    let mut ptr = 0;
    if args.verbose > 0 {
        for i in 0..(len / 2) {
            info!("{}", to_state(i, res[ptr], res[ptr + 1]));
            ptr += 2;
        }
    }
    Ok(res)
}

fn tart_write(args: &Args, tart: &mut AxisUSB) -> Result<Vec<u8>, rusb::Error> {
    let wrdat: [u8; 24] = [
        0xff, 0x5a, 0xc3, 0x2d, 0x03, 0xb0, 0x00, 0x10, 0x03, 0xb0, 0x00, 0x10, 0xff, 0x5a, 0xc3,
        0x2d, 0xff, 0x80, 0x08, 0x3c, 0xa5, 0xc3, 0x5a, 0x99,
    ];
    let wrdat: Vec<u8> = wrdat[0..args.size].to_owned().repeat(args.chunks);

    if args.packet_mode {
        if tart.write_register(0x0, 0u16, None)? == 2 {
            debug!("REG_WRITE TSR");
        }
        if tart.write_register(0x1, wrdat.len() as u16, None)? == 2 {
            debug!("REG_WRITE TLR = {}", wrdat.len());
        }
        let val: u16 = tart.read_register(0x0, None)?;
        debug!("REG_READ TSR = {}", val);
    }

    let num = tart.write(&wrdat)?;
    if args.packet_mode {
        let val: u16 = tart.read_register(0x0, None)?;
        debug!("REG_READ TSR = {}", val);
        let val: u16 = tart.read_register(0x1, None)?;
        debug!("REG_READ TLR = {}", val);
    }

    info!("WRITTEN (bytes = {}): {:?}", num, &wrdat);
    Ok(wrdat)
}

fn axis_usb(args: Args) -> Result<(), rusb::Error> {
    if args.verbose > 0 {
        info!("{:?}", &args);
    }
    let context = Context::new()?;
    let mut device = find_axis_usb(&context)?;

    let mut axis_usb = AxisUSB::open(&mut device, context)?;

    if args.verbose > 1 {
        info!(
            "Product: {}, S/N: {}",
            axis_usb.product(),
            axis_usb.serial_number()
        );
    }

    if args.packet_mode {
        let tsr = axis_usb.read_register(0x0, None)?;
        info!("TSR: 0x{:04x}", tsr);
        let tlr = axis_usb.read_register(0x1, None)?;
        info!("TLR: 0x{:04x}", tlr);
        let rsr = axis_usb.read_register(0x2, None)?;
        info!("RSR: 0x{:04x}", rsr);
    }

    if args.read_first {
        let bytes: Vec<u8> = axis_usb.try_read(None).unwrap_or(Vec::new());
        info!("RECEIVED (bytes = {}): {:?}", bytes.len(), &bytes);
    }

    spin_sleep::native_sleep(Duration::from_millis(args.delay as u64));

    if !args.writeless {
        let _ = tart_write(&args, &mut axis_usb)?;
    }

    spin_sleep::native_sleep(Duration::from_millis(args.delay as u64));

    let _bytes: Vec<u8> = tart_read(&args, &mut axis_usb)?;

    if args.telemetry {
        tart_telemetry(&args, &mut axis_usb)?;
    }

    Ok(())
}

fn main() -> Result<(), rusb::Error> {
    println!("AXIS USB2 bulk-device driver");
    let args: Args = Args::parse();

    let level = if args.verbose > 0 {
        LevelFilter::Debug
    } else {
        LevelFilter::Warn
    };
    SimpleLogger::new().with_level(level).init().unwrap();

    match axis_usb(args) {
        Ok(()) => {}
        Err(rusb::Error::Access) => {
            error!("Insufficient privileges to access USB device");
        }
        Err(e) => {
            error!("Failed with error: {:?}", e);
        }
    }
    Ok(())
}
