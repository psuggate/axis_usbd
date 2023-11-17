use clap::Parser;
use driver::axis_usb::*;
use log::{error, info, LevelFilter};
use rusb::Context;
use simple_logger::SimpleLogger;

#[derive(Parser, Debug, Clone)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// Verbosity
    #[arg(short, long, value_name = "LEVEL")]
    log_level: Option<String>,

    #[arg(short, long, default_value = "false")]
    read_first: bool,

    #[arg(short, long, default_value = "20")]
    size: usize,

    #[arg(short, long, default_value = "32")]
    chunks: usize,

    /// Verbosity of generated output?
    #[arg(short, long, action = clap::ArgAction::Count)]
    verbose: u8,
}

fn axis_usb(args: Args) -> Result<(), rusb::Error> {
    if args.verbose > 0 {
        info!("{:?}", &args);
    }
    let context = Context::new()?;
    let mut device = find_axis_usb(&context)?;

    let mut axis_usb = AxisUSB::open(&mut device, context)?;

    info!(
        "Product: {}, S/N: {}",
        axis_usb.product(),
        axis_usb.serial_number()
    );

    if args.read_first {
        // let bytes: Vec<u8> = axis_usb.try_read(None)?;
        // info!("RECEIVED (bytes = {}): {:?}", bytes.len(), &bytes);

        // let rdcmd: [u8; 5] = [0x03, 0x30, 0x00, 0x00, 0x10];
        // let num = axis_usb.write(&rdcmd)?;
        // info!("WRITTEN (bytes = {}): {:?}", num, &rdcmd);

        let bytes: Vec<u8> = axis_usb.try_read(None).unwrap_or(Vec::new());
        info!("RECEIVED (bytes = {}): {:?}", bytes.len(), &bytes);
    }

    // let wrcmd: [u8; 5] = [0x03, 0xb0, 0x00, 0x00, 0x10];
    // let num = axis_usb.write(&wrcmd)?;
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
    let num = axis_usb.write(&wrdat)?;
    info!("WRITTEN (bytes = {}): {:?}", num, &wrdat);
    /*
        let num = axis_usb.write(&wrdat)?;
        info!("WRITTEN (bytes = {}): {:?}", num, &wrdat);
        let num = axis_usb.write(&wrdat)?;
        info!("WRITTEN (bytes = {}): {:?}", num, &wrdat);
        let num = axis_usb.write(&wrdat)?;
        info!("WRITTEN (bytes = {}): {:?}", num, &wrdat);
    */

    // let rdcmd: [u8; 5] = [0x03, 0x30, 0x00, 0x00, 0x10];
    // let num = axis_usb.write(&rdcmd)?;
    // info!("WRITTEN (bytes = {}): {:?}", num, &rdcmd);

    let bytes: Vec<u8> = axis_usb.try_read(None)?;
    info!("RECEIVED (bytes = {}): {:?}", bytes.len(), &bytes);

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
