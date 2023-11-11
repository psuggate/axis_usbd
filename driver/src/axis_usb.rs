use rusb::{
    ConfigDescriptor, Context, Device, DeviceDescriptor, DeviceHandle, Direction,
    InterfaceDescriptor, TransferType, UsbContext,
};

pub const VENDOR_ID: u16 = 0xF4CE;
pub const PRODUCT_ID: u16 = 0x0003;

#[derive(Debug, PartialEq)]
pub struct AxisUSB {
    handle: DeviceHandle<Context>,
    interfaces: Vec<u8>,
    endpoint: Endpoint,
    label: String,
    serial: String,
    context: Context,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Endpoint {
    pub config: u8,
    pub interface: u8,
    pub setting: u8,
    pub address: u8,
    pub has_driver: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Interface {
    pub configuration: u8,
    pub number: u8,
    pub alternate_setting: u8,
    pub has_driver: bool,
}

pub fn configure_interface<T: UsbContext>(
    handle: &mut DeviceHandle<T>,
    interface: &Interface,
) -> rusb::Result<()> {
    if interface.has_driver {
        eprintln!("USB device has a kernel driver loaded, attempting to detach ...");
        handle.detach_kernel_driver(interface.number).ok();
    }
    // println!("{:#?}", endpoint);

    handle.set_active_configuration(interface.configuration)?;
    handle.claim_interface(interface.number)?;
    handle.set_alternate_setting(interface.number, interface.alternate_setting)?;

    Ok(())
}

impl Endpoint {
    pub fn new(cfg: u8, ix: &InterfaceDescriptor) -> Self {
        Self {
            config: cfg,
            interface: ix.interface_number(),
            setting: ix.setting_number(),
            address: 0u8,
            has_driver: false,
        }
    }
}

pub fn find_interfaces<T: UsbContext>(
    device: &mut Device<T>,
    descriptor: &DeviceDescriptor,
) -> Vec<u8> {
    let numcfg = descriptor.num_configurations();
    let config: ConfigDescriptor = (0..numcfg)
        .find_map(|n| device.config_descriptor(n).ok())
        .unwrap();

    let mut interfaces = Vec::new();
    for ix in config.interfaces().flat_map(|i| i.descriptors()) {
        interfaces.push(ix.interface_number());
    }

    interfaces
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

    for ix in config.interfaces().flat_map(|i| i.descriptors()) {
        let ix_num: u8 = ix.interface_number();

        for ep in ix.endpoint_descriptors() {
            if ep.transfer_type() == transfer_type && ep.direction() == direction {
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

impl AxisUSB {
    pub fn open(device: &mut Device<Context>, context: Context) -> Result<AxisUSB, rusb::Error> {
        let descriptor = device.device_descriptor()?;
        let mut handle = device.open()?;
        println!("AXIS USB opened ...");

        let label = handle.read_product_string_ascii(&descriptor)?;
        let serial = handle.read_serial_number_string_ascii(&descriptor)?;

        let mut interfaces: Vec<u8> = Vec::with_capacity(2);
        let ep_in = find_endpoint(
            device,
            &descriptor,
            &handle,
            TransferType::Bulk,
            Direction::In,
        )
        .ok_or(rusb::Error::NotFound)?;
        interfaces.push(ep_in.interface);
        println!(" - IN (bulk) endpoint found");

        let ep_out = find_endpoint(
            device,
            &descriptor,
            &handle,
            TransferType::Bulk,
            Direction::Out,
        )
        .ok_or(rusb::Error::NotFound)?;

        configure_endpoint(&mut handle, &ep_in)?;
        if ep_in.interface != ep_out.interface {
            interfaces.push(ep_out.interface);
            configure_endpoint(&mut handle, &ep_out)?;
        }
        println!(" - OUT (bulk) endpoint found");

        Ok(Self {
            handle,
            interfaces,
            endpoint: ep_in,
            label,
            serial,
            context,
        })
    }

    pub fn product(&self) -> String {
        self.label.clone()
    }

    pub fn serial_number(&self) -> String {
        self.serial.clone()
    }
}

impl Drop for AxisUSB {
    fn drop(&mut self) {
        if self.endpoint.has_driver {
            eprintln!("Re-attaching kernel driver !!");
            self.handle
                .attach_kernel_driver(self.endpoint.interface)
                .unwrap();
        }
    }
}
