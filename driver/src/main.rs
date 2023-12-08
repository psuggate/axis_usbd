use clap::Parser;
use driver::axis_usb::*;
use log::{debug, error, info, LevelFilter};
use rusb::Context;
use simple_logger::SimpleLogger;
use std::time::Duration;

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

    #[arg(short, long, default_value = "50")]
    delay: usize,

    #[arg(short, long, default_value = "20")]
    size: usize,

    #[arg(short, long, default_value = "32")]
    chunks: usize,

    #[arg(short, long, default_value = "false")]
    packet_mode: bool,

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

fn tart_write(args: &Args, tart: &mut AxisUSB) -> Result<Vec<u8>, rusb::Error> {
    // let wrcmd: [u8; 5] = [0x03, 0xb0, 0x00, 0x00, 0x10];
    // let num = tart.write(&wrcmd)?;
    // info!("WRITTEN (bytes = {}): {:?}", num, &wrcmd);

    let wrdat: [u8; 24] = [
        0xff, 0x5a, 0xc3, 0x2d, 0x03, 0xb0, 0x00, 0x10, 0x03, 0xb0, 0x00, 0x10, 0xff, 0x5a, 0xc3,
        0x2d, 0xff, 0x80, 0x08, 0x3c, 0xa5, 0xc3, 0x5a, 0x99,
    ];
    // let wrdat: Vec<u8> = wrdat[0..12].to_owned();
    // let wrdat: Vec<u8> = wrdat[0..16].to_owned().repeat(2);
    // let wrdat: Vec<u8> = wrdat[0..20].to_owned().repeat(32);
    let wrdat: Vec<u8> = wrdat[0..args.size].to_owned().repeat(args.chunks);
    // let wrdat: Vec<u8> = wrdat[0..20].to_owned().repeat(16);
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

    /*
    let num = tart.write(&wrdat)?;
    info!("WRITTEN (bytes = {}): {:?}", num, &wrdat);
    let num = tart.write(&wrdat)?;
    info!("WRITTEN (bytes = {}): {:?}", num, &wrdat);
    let num = tart.write(&wrdat)?;
    info!("WRITTEN (bytes = {}): {:?}", num, &wrdat);
     */

    // let rdcmd: [u8; 5] = [0x03, 0x30, 0x00, 0x00, 0x10];
    // let num = tart.write(&rdcmd)?;
    // info!("WRITTEN (bytes = {}): {:?}", num, &rdcmd);

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
        // let bytes: Vec<u8> = axis_usb.try_read(None)?;
        // info!("RECEIVED (bytes = {}): {:?}", bytes.len(), &bytes);

        // let rdcmd: [u8; 5] = [0x03, 0x30, 0x00, 0x00, 0x10];
        // let num = axis_usb.write(&rdcmd)?;
        // info!("WRITTEN (bytes = {}): {:?}", num, &rdcmd);

        let bytes: Vec<u8> = axis_usb.try_read(None).unwrap_or(Vec::new());
        info!("RECEIVED (bytes = {}): {:?}", bytes.len(), &bytes);
    }

    spin_sleep::native_sleep(Duration::from_millis(args.delay as u64));

    let _ = tart_write(&args, &mut axis_usb)?;

    spin_sleep::native_sleep(Duration::from_millis(args.delay as u64));

    let _bytes: Vec<u8> = tart_read(&args, &mut axis_usb)?;

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
