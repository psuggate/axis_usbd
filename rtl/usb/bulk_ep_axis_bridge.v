`timescale 1ns / 100ps
//
// Based on project 'https://github.com/ObKo/USBCore'
// License: MIT
//  Copyright (c) 2021 Dmitry Matyunin
//
module bulk_ep_axis_bridge #(
    parameter FPGA_VENDOR = "gowin",
    parameter FPGA_FAMILY = "gw2a",
    parameter VENDOR_ID = 16'hFACE,
    parameter PRODUCT_ID = 16'h0BDE,
    parameter integer MANUFACTURER_LEN = 19,
    parameter [151:0] MANUFACTURER = "University of Otago",
    parameter integer PRODUCT_LEN = 15,
    parameter [119:0] PRODUCT = "AXIS USB Bridge",
    parameter integer HIGH_SPEED = 1,
    parameter PACKET_MODE = 1,
    parameter [31:0] CONFIG_CHAN = 0,
    parameter [63:0] SERIAL = "BULK0000"
) (
    input wire sys_clk,
    input wire reset_n,

    /* Status flags */
    output wire fifo_in_full_o,
    output wire fifo_out_full_o,
    output wire fifo_has_data_o,
    output wire usb_sof_o,

    /* ULPI */
    input wire [7:0] ulpi_data_in,
    output wire [7:0] ulpi_data_out,
    input wire ulpi_dir,
    input wire ulpi_nxt,
    output wire ulpi_stp,
    output wire ulpi_reset,
    input wire ulpi_clk,

    /* AXIS */
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire [7:0] s_axis_tdata,
    input wire s_axis_tlast,

    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire [7:0] m_axis_tdata,
    output wire m_axis_tlast
);

  localparam CONFIG_DESC_LEN = 9;
  localparam INTERFACE_DESC_LEN = 9;
  localparam EP1_IN_DESC_LEN = 7;
  localparam EP1_OUT_DESC_LEN = 7;

  localparam CONFIG_DESC = {
    8'h32,  // bMaxPower = 100 mA
    8'hC0,  // bmAttributes = Self-powered
    8'h00,  // iConfiguration
    8'h01,  // bConfigurationValue
    8'h01,  // bNumInterfaces = 1
    16'h0020,  // wTotalLength = 32
    8'h02,  // bDescriptionType = Configuration Descriptor
    8'h09  // bLength = 9
  };

  localparam INTERFACE_DESC = {
    8'h00,  // iInterface
    8'h00,  // bInterfaceProtocol
    8'h00,  // bInterfaceSubClass
    8'h00,  // bInterfaceClass
    8'h02,  // bNumEndpoints = 2
    8'h00,  // bAlternateSetting
    8'h00,  // bInterfaceNumber = 0
    8'h04,  // bDescriptorType = Interface Descriptor
    8'h09  // bLength = 9
  };

  localparam EP1_IN_DESC = {
    8'h00,  // bInterval
    16'h0200,  // wMaxPacketSize = 512 bytes
    8'h02,  // bmAttributes = Bulk
    8'h81,  // bEndpointAddress = IN1
    8'h05,  // bDescriptorType = Endpoint Descriptor
    8'h07  // bLength = 7
  };

  localparam EP1_OUT_DESC = {
    8'h00,  // bInterval
    16'h0200,  // wMaxPacketSize = 512 bytes
    8'h02,  // bmAttributes = Bulk
    8'h01,  // bEndpointAddress = OUT1
    8'h05,  // bDescriptorType = Endpoint Descriptor
    8'h07  // bLength = 7
  };

  wire usb_clk;
  wire usb_reset;

  wire usb_idle;
  wire usb_suspend;
  wire usb_configured;
  wire usb_crc_error;
  wire usb_sof;

  wire [3:0] ctl_xfer_endpoint;
  wire [7:0] ctl_xfer_type;
  wire [7:0] ctl_xfer_request;
  wire [15:0] ctl_xfer_value;
  wire [15:0] ctl_xfer_index;
  wire [15:0] ctl_xfer_length;
  wire ctl_xfer_accept;
  wire ctl_xfer;
  wire ctl_xfer_done;

  wire [7:0] ctl_xfer_data_out;
  wire ctl_xfer_data_out_valid;

  wire [7:0] ctl_xfer_data_in;
  wire ctl_xfer_data_in_valid;
  wire ctl_xfer_data_in_last;
  wire ctl_xfer_data_in_ready;

  wire [3:0] blk_xfer_endpoint;

  wire tlp_blk_in_xfer;
  wire tlp_blk_out_xfer;
  wire tlp_blk_xfer_in_has_data;
  wire [7:0] tlp_blk_xfer_in_data;
  wire tlp_blk_xfer_in_data_valid;
  wire tlp_blk_xfer_in_data_ready;
  wire tlp_blk_xfer_in_data_last;
  wire tlp_blk_xfer_out_ready_read;
  wire [7:0] tlp_blk_xfer_out_data;
  wire tlp_blk_xfer_out_data_valid;

  wire ep_blk_in_xfer;
  wire ep_blk_xfer_in_has_data;
  wire [7:0] ep_blk_xfer_in_data;
  wire ep_blk_xfer_in_data_valid;
  wire ep_blk_xfer_in_data_ready;
  wire ep_blk_xfer_in_data_last;
  wire ep_blk_out_xfer;
  wire ep_blk_xfer_out_ready_read;
  wire [7:0] ep_blk_xfer_out_data;
  wire ep_blk_xfer_out_data_ready;
  wire ep_blk_xfer_out_data_valid;
  wire ep_blk_xfer_out_data_last;

  assign fifo_has_data_o = ep_blk_xfer_in_has_data;
  assign usb_sof_o = usb_sof;

  usb_tlp #(
      .VENDOR_ID(VENDOR_ID),
      .PRODUCT_ID(PRODUCT_ID),
      .MANUFACTURER_LEN(MANUFACTURER_LEN),
      .MANUFACTURER(MANUFACTURER),
      .PRODUCT_LEN(PRODUCT_LEN),
      .PRODUCT(PRODUCT),
      .SERIAL_LEN(8),
      .SERIAL(SERIAL),
      .CONFIG_DESC_LEN(CONFIG_DESC_LEN + INTERFACE_DESC_LEN + EP1_IN_DESC_LEN + EP1_OUT_DESC_LEN),
      .CONFIG_DESC({EP1_OUT_DESC, EP1_IN_DESC, INTERFACE_DESC, CONFIG_DESC}),
      .HIGH_SPEED(HIGH_SPEED)
  ) usb_tlp_inst (
.arst_ni(1'b1),

      .ulpi_data_in(ulpi_data_in),
      .ulpi_data_out(ulpi_data_out),
      .ulpi_dir(ulpi_dir),
      .ulpi_nxt(ulpi_nxt),
      .ulpi_stp(ulpi_stp),
      .ulpi_reset(ulpi_reset),
      .ulpi_clk60(ulpi_clk),

      .usb_clock(usb_clk),
      .usb_reset(usb_reset),
      .usb_idle(usb_idle),
      .usb_suspend(usb_suspend),
      .usb_configured(usb_configured),
      .usb_crc_error(usb_crc_error),
      .usb_sof(usb_sof),

      .ctl_xfer_endpoint(ctl_xfer_endpoint),
      .ctl_xfer_type(ctl_xfer_type),
      .ctl_xfer_request(ctl_xfer_request),
      .ctl_xfer_value(ctl_xfer_value),
      .ctl_xfer_index(ctl_xfer_index),
      .ctl_xfer_length(ctl_xfer_length),
      .ctl_xfer_accept_i(ctl_xfer_accept),
      .ctl_xfer_request_o(ctl_xfer),

      .ctl_xfer_done(ctl_xfer_done),
      .ctl_xfer_data_out(ctl_xfer_data_out),
      .ctl_xfer_data_out_valid(ctl_xfer_data_out_valid),

      .ctl_tvalid_i(ctl_xfer_data_in_valid),
      .ctl_tready_o(ctl_xfer_data_in_ready),
      .ctl_tlast_i (ctl_xfer_data_in_last),
      .ctl_tdata_i (ctl_xfer_data_in),

      .blk_xfer_endpoint(blk_xfer_endpoint),
      .blk_in_xfer(tlp_blk_in_xfer),
      .blk_out_xfer(tlp_blk_out_xfer),

      .bid_has_data_i(tlp_blk_xfer_in_has_data),
      .bid_tvalid_i(tlp_blk_xfer_in_data_valid),
      .bid_tready_o(tlp_blk_xfer_in_data_ready),
      .bid_tlast_i(tlp_blk_xfer_in_data_last),
      .bid_tdata_i(tlp_blk_xfer_in_data),

      .blk_xfer_out_ready_read(tlp_blk_xfer_out_ready_read),
      .blk_xfer_out_data(tlp_blk_xfer_out_data),
      .blk_xfer_out_data_valid(tlp_blk_xfer_out_data_valid)
  );

  bulk_ep_control #(
      .HIGH_SPEED (HIGH_SPEED),
      .PACKET_MODE(PACKET_MODE),
      .CONFIG_CHAN(CONFIG_CHAN)
  ) bulk_ep_control_inst (
      .clock(usb_clk),
      .reset(usb_reset),

      // Control PIPE for the EP
      // todo: this PIPE is optional !?
      .ctl_xfer_endpoint(ctl_xfer_endpoint),
      .ctl_xfer_type(ctl_xfer_type),
      .ctl_xfer_request(ctl_xfer_request),
      .ctl_xfer_value(ctl_xfer_value),
      .ctl_xfer_index(ctl_xfer_index),
      .ctl_xfer_length(ctl_xfer_length),
      .ctl_xfer_accept(ctl_xfer_accept),
      .ctl_xfer(ctl_xfer),
      .ctl_xfer_done(ctl_xfer_done),
      .ctl_xfer_data_out(ctl_xfer_data_out),
      .ctl_xfer_data_out_valid(ctl_xfer_data_out_valid),
      .ctl_xfer_data_in(ctl_xfer_data_in),
      .ctl_xfer_data_in_valid(ctl_xfer_data_in_valid),
      .ctl_xfer_data_in_last(ctl_xfer_data_in_last),
      .ctl_xfer_data_in_ready(ctl_xfer_data_in_ready),

      // Stream: EP IN -> TLP
      // todo: can this EP IN PIPE bypass this module !?
      .tlp_blk_in_xfer(tlp_blk_in_xfer),
      .tlp_blk_xfer_in_has_data(tlp_blk_xfer_in_has_data),
      .tlp_blk_xfer_in_data(tlp_blk_xfer_in_data),
      .tlp_blk_xfer_in_data_valid(tlp_blk_xfer_in_data_valid),
      .tlp_blk_xfer_in_data_ready(tlp_blk_xfer_in_data_ready),
      .tlp_blk_xfer_in_data_last(tlp_blk_xfer_in_data_last),

      .ep_blk_in_xfer(ep_blk_in_xfer),
      .ep_blk_xfer_in_has_data(ep_blk_xfer_in_has_data),
      .ep_blk_xfer_in_data(ep_blk_xfer_in_data),
      .ep_blk_xfer_in_data_valid(ep_blk_xfer_in_data_valid),
      .ep_blk_xfer_in_data_ready(ep_blk_xfer_in_data_ready),
      .ep_blk_xfer_in_data_last(ep_blk_xfer_in_data_last),

      // Stream: TLP -> EP OUT
      // todo: can this EP OUT PIPE bypass this module !?
      .tlp_blk_out_xfer(tlp_blk_out_xfer),
      .tlp_blk_xfer_out_ready_read(tlp_blk_xfer_out_ready_read),
      .tlp_blk_xfer_out_data(tlp_blk_xfer_out_data),
      .tlp_blk_xfer_out_data_valid(tlp_blk_xfer_out_data_valid),

      .ep_blk_out_xfer(ep_blk_out_xfer),
      .ep_blk_xfer_out_ready_read(ep_blk_xfer_out_ready_read),
      .ep_blk_xfer_out_data(ep_blk_xfer_out_data),
      .ep_blk_xfer_out_data_ready(ep_blk_xfer_out_data_ready),
      .ep_blk_xfer_out_data_valid(ep_blk_xfer_out_data_valid),
      .ep_blk_xfer_out_data_last(ep_blk_xfer_out_data_last)
  );

  bulk_ep_in #(
      .FPGA_VENDOR(FPGA_VENDOR),
      .FPGA_FAMILY(FPGA_FAMILY)
  ) bulk_ep_in_inst (
      .reset_n(reset_n),

      .status_full_o(fifo_in_full_o),

      .axis_aclk    (sys_clk),
      .axis_tvalid_i(s_axis_tvalid),
      .axis_tready_o(s_axis_tready),
      .axis_tlast_i (s_axis_tlast),
      .axis_tdata_i (s_axis_tdata),

      .bulk_ep_in_clock(usb_clk),
      .bulk_ep_in_xfer_i(ep_blk_in_xfer),
      .bulk_ep_in_has_data_o(ep_blk_xfer_in_has_data),
      .bulk_ep_in_tvalid_o(ep_blk_xfer_in_data_valid),
      .bulk_ep_in_tready_i(ep_blk_xfer_in_data_ready),
      .bulk_ep_in_tlast_o(ep_blk_xfer_in_data_last),
      .bulk_ep_in_tdata_o(ep_blk_xfer_in_data)
  );

  bulk_ep_out #(
      .FPGA_VENDOR(FPGA_VENDOR),
      .FPGA_FAMILY(FPGA_FAMILY)
  ) bulk_ep_out_inst (
      .reset_n(reset_n),

      .status_full_o(fifo_out_full_o),

      .bulk_ep_out_clock(usb_clk),
      .bulk_ep_out_xfer_i(ep_blk_out_xfer),
      .bulk_ep_out_ready_read_o(ep_blk_xfer_out_ready_read),
      .bulk_ep_out_tvalid_i(ep_blk_xfer_out_data_valid),
      .bulk_ep_out_tready_o(ep_blk_xfer_out_data_ready),
      .bulk_ep_out_tlast_i(ep_blk_xfer_out_data_last),
      .bulk_ep_out_tdata_i(ep_blk_xfer_out_data),

      .axis_aclk    (sys_clk),
      .axis_tvalid_o(m_axis_tvalid),
      .axis_tready_i(m_axis_tready),
      .axis_tlast_o (m_axis_tlast),
      .axis_tdata_o (m_axis_tdata)
  );


endmodule  // bulk_ep_axis_bridge
