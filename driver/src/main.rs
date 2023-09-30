use driver::axis_usb::*;
use rusb::Context;

fn main() -> Result<(), rusb::Error> {
    println!("Hello, world!");

    let context = Context::new()?;
    let mut device = find_axis_usb(&context)?;

    let axis_usb = AxisUSB::open(&mut device, context)?;

    println!(
        "Product: {}, S/N: {}",
        axis_usb.product(),
        axis_usb.serial_number()
    );

    Ok(())
}
