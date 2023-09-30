use rusb::{
    ConfigDescriptor, Context, Device, DeviceDescriptor, DeviceHandle, Direction, TransferType,
    UsbContext,
};

pub const VENDOR_ID: u16 = 0xF4CE;
pub const PRODUCT_ID: u16 = 0x0003;

#[derive(Debug, Clone, PartialEq)]
pub struct Endpoint {
    pub config: u8,
    pub interface: u8,
    pub setting: u8,
    pub address: u8,
    pub has_driver: bool,
}

pub fn find_endpoint<T: UsbContext>(
    device: &mut Device<T>,
    descriptor: &DeviceDescriptor,
    handle: &DeviceHandle<T>,
    transfer_type: TransferType,
    direction: Direction,
) -> Option<Endpoint> {
    let numcfg = descriptor.num_configurations();
    let config: ConfigDescriptor = (0..numcfg).find_map(|n| device.config_descriptor(n).ok())?;
    // println!("Found '{}' configuration descriptors", numcfg);

    for interface in config.interfaces() {
        for ix in interface.descriptors() {
            for ep in ix.endpoint_descriptors() {
                if ep.transfer_type() == transfer_type && ep.direction() == direction {
                    let ix_num: u8 = ix.interface_number();
                    let has_driver: bool = handle.kernel_driver_active(ix_num).unwrap_or(false);

                    return Some(Endpoint {
                        config: config.number(),
                        interface: ix_num,
                        setting: ix.setting_number(),
                        address: ep.address(),
                        has_driver,
                    });
                }
            }
        }
    }

    None
}

pub fn configure_endpoint<T: UsbContext>(
    handle: &mut DeviceHandle<T>,
    endpoint: &Endpoint,
) -> rusb::Result<()> {
    if endpoint.has_driver {
        eprintln!("USB device has a kernel driver loaded, attempting to detach ...");
        handle.detach_kernel_driver(endpoint.interface).ok();
    }
    // println!("{:#?}", endpoint);

    handle.set_active_configuration(endpoint.config)?;
    handle.claim_interface(endpoint.interface)?;
    handle.set_alternate_setting(endpoint.interface, endpoint.setting)?;

    Ok(())
}

pub fn find_axis_usb(context: &Context) -> Result<Device<Context>, rusb::Error> {
    if let Ok(devices) = context.devices() {
        return devices
            .iter()
            .find_map(|ref device| {
                let descriptor = device.device_descriptor().ok()?;
                let vid: u16 = descriptor.vendor_id();
                let pid: u16 = descriptor.product_id();
                println!("Vendor ID: 0x{:04x}, Product ID: 0x{:04x}", vid, pid);

                if descriptor.vendor_id() == VENDOR_ID && descriptor.product_id() == PRODUCT_ID {
                    Some(device.to_owned())
                } else {
                    None
                }
            })
            .ok_or(rusb::Error::NotFound);
    }
    Err(rusb::Error::NotFound)
}

#[derive(Debug, PartialEq)]
pub struct AxisUSB {
    device_handle: DeviceHandle<Context>,
    interfaces: Vec<u8>,
    bulk_ep_in: Endpoint,
    bulk_ep_out: Endpoint,
    product_label: String,
    serial_number: String,
    context: Context,
}

impl AxisUSB {
    pub fn open(device: &mut Device<Context>, context: Context) -> Result<AxisUSB, rusb::Error> {
        let descriptor = device.device_descriptor()?;
        let mut device_handle = device.open()?;
        println!("AXIS USB opened ...");

        let product_label = device_handle.read_product_string_ascii(&descriptor)?;
        let serial_number = device_handle.read_serial_number_string_ascii(&descriptor)?;

        let mut interfaces: Vec<u8> = Vec::with_capacity(2);
        let ep_in = find_endpoint(
            device,
            &descriptor,
            &device_handle,
            TransferType::Bulk,
            Direction::In,
        )
        .ok_or(rusb::Error::NotFound)?;
        interfaces.push(ep_in.interface);
        println!(" - IN (bulk) endpoint found");

        let ep_out = find_endpoint(
            device,
            &descriptor,
            &device_handle,
            TransferType::Bulk,
            Direction::Out,
        )
        .ok_or(rusb::Error::NotFound)?;
        configure_endpoint(&mut device_handle, &ep_in)?;
        if ep_in.interface != ep_out.interface {
            interfaces.push(ep_out.interface);
            configure_endpoint(&mut device_handle, &ep_out)?;
        }
        println!(" - OUT (bulk) endpoint found");

        Ok(Self {
            device_handle,
            interfaces,
            bulk_ep_in: ep_in,
            bulk_ep_out: ep_out,
            product_label,
            serial_number,
            context,
        })
    }

    pub fn product(&self) -> String {
        self.product_label.clone()
    }

    pub fn serial_number(&self) -> String {
        self.serial_number.clone()
    }
}

impl Drop for AxisUSB {
    fn drop(&mut self) {
        if self.bulk_ep_in.has_driver {
            eprintln!("Re-attaching kernel driver !!");
            self.device_handle
                .attach_kernel_driver(self.bulk_ep_in.interface)
                .unwrap();
        }

        if self.bulk_ep_out.has_driver {
            eprintln!("Re-attaching kernel driver !!");
            self.device_handle
                .attach_kernel_driver(self.bulk_ep_out.interface)
                .unwrap();
        }
    }
}
