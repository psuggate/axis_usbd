`timescale 1ns / 100ps
//
// Based on project 'https://github.com/ObKo/USBCore'
// License: MIT
//  Copyright (c) 2021 Dmitry Matyunin
//
module usb_tlp #(
    parameter [15:0] VENDOR_ID = 16'hFACE,
    parameter [15:0] PRODUCT_ID = 16'h0BDE,
    parameter MANUFACTURER_LEN = 0,
    parameter MANUFACTURER = "",
    parameter PRODUCT_LEN = 0,
    parameter PRODUCT = "",
    parameter SERIAL_LEN = 0,
    parameter SERIAL = "",
    parameter CONFIG_DESC_LEN = 18,
    parameter CONFIG_DESC = {
      /* Interface descriptor */
      8'h00,  /* iInterface */
      8'h00,  /* bInterfaceProtocol */
      8'h00,  /* bInterfaceSubClass */
      8'h00,  /* bInterfaceClass */
      8'h00,  /* bNumEndpoints = 0 */
      8'h00,  /* bAlternateSetting */
      8'h00,  /* bInterfaceNumber = 0 */
      8'h04,  /* bDescriptorType = Interface Descriptor */
      8'h09,  /* bLength = 9 */
      /* Configuration Descriptor */
      8'h32,  /* bMaxPower = 100 mA */
      8'hC0,  /* bmAttributes = Self-powered */
      8'h00,  /* iConfiguration */
      8'h01,  /* bConfigurationValue */
      8'h01,  /* bNumInterfaces = 1 */
      16'h0012,  /* wTotalLength = 18 */
      8'h02,  /* bDescriptionType = Configuration Descriptor */
      8'h09  /* bLength = 9 */
    },
    parameter integer HIGH_SPEED = 1
) (

    input wire [7:0] ulpi_data_in,
    output wire [7:0] ulpi_data_out,
    input wire ulpi_dir,
    input wire ulpi_nxt,
    output wire ulpi_stp,
    output wire ulpi_reset,
    input wire ulpi_clk60,

    output wire ulpi_rx_overflow_o,

    output wire usb_clock,
    output wire usb_reset,
    output wire usb_idle,
    output wire usb_suspend,
    output wire usb_configured,
    output wire usb_crc_error,
    output wire usb_sof,  // Pulse when SOF packet received

    // Control transfer signals
    output wire [3:0] ctl_xfer_endpoint,
    output wire [7:0] ctl_xfer_type,
    output wire [7:0] ctl_xfer_request,
    output wire [15:0] ctl_xfer_value,
    output wire [15:0] ctl_xfer_index,
    output wire [15:0] ctl_xfer_length,
    input wire ctl_xfer_accept_i,
    output wire ctl_xfer_request_o,
    input wire ctl_xfer_done,

    output wire [7:0] ctl_xfer_data_out,
    output wire ctl_xfer_data_out_valid,

    input wire [7:0] ctl_tdata_i,
    input wire ctl_tvalid_i,
    input wire ctl_tlast_i,
    output wire ctl_tready_o,

    // Bulk transfer signals
    output wire [3:0] blk_xfer_endpoint,
    output wire blk_in_xfer,
    output wire blk_out_xfer,

    // Has complete packet
    input wire bid_has_data_i,
    input wire bid_tvalid_i,
    output wire bid_tready_o,
    input wire bid_tlast_i,
    input wire [7:0] bid_tdata_i,

    // Can accept full packet
    input wire blk_xfer_out_ready_read,
    output wire [7:0] blk_xfer_out_data,
    output wire blk_xfer_out_data_valid
);

  wire axis_rx_tvalid;
  wire axis_rx_tready;
  wire axis_rx_tlast;
  wire [7:0] axis_rx_tdata;

  wire axis_tx_tvalid;
  wire axis_tx_tready;
  wire axis_tx_tlast;
  wire [7:0] axis_tx_tdata;
  wire usb_vbus_valid;

  wire [1:0] trn_type;
  wire [6:0] trn_address;
  wire [3:0] trn_endpoint;
  wire trn_start;

  wire [1:0] rx_trn_data_type;
  wire rx_trn_end;
  wire [7:0] rx_trn_data;
  wire rx_trn_valid;

  wire [1:0] rx_trn_hsk_type;
  wire rx_trn_hsk_recv;

  wire [1:0] tx_trn_hsk_type;
  wire tx_trn_send_hsk;
  wire tx_trn_hsk_sent;

  wire [1:0] tx_trn_data_type;
  wire tx_trn_data_start;

  wire [7:0] tx_trn_data;
  wire tx_trn_data_valid;
  wire tx_trn_data_ready;
  wire tx_trn_data_last;

  wire [3:0] ctl_xfer_endpoint_int;
  wire [7:0] ctl_xfer_type_int;
  wire [7:0] ctl_xfer_request_int;
  wire [15:0] ctl_xfer_value_int;
  wire [15:0] ctl_xfer_index_int;
  wire [15:0] ctl_xfer_length_int;
  wire ctl_xfer_accept_int;
  wire ctl_xfer_int;
  wire ctl_xfer_done_int;

  wire ctl_xfer_accept_std;
  wire ctl_xfer_std;

  wire ctl_xfer_data_out_valid_int;

  wire [7:0] ctl_xfer_data_in_int;
  wire ctl_xfer_data_in_valid_int;
  wire ctl_xfer_data_in_last_int;
  wire ctl_xfer_data_in_ready_int;

  wire [7:0] ctl_xfer_data_in_std;
  wire ctl_xfer_data_in_valid_std;
  wire ctl_xfer_data_in_last_std;

  wire [7:0] current_configuration;
  wire usb_reset_int;
  wire usb_crc_error_int;
  reg cfg_request_q;
  wire cfg_request, cfg_request_w;
  wire [6:0] device_address;


  assign usb_clock                  = ulpi_clk60;
  assign usb_reset                  = usb_reset_int;

  assign usb_crc_error              = usb_crc_error_int;

  assign ctl_xfer_endpoint          = ctl_xfer_endpoint_int;
  assign ctl_xfer_type              = ctl_xfer_type_int;
  assign ctl_xfer_request           = ctl_xfer_request_int;
  assign ctl_xfer_value             = ctl_xfer_value_int;
  assign ctl_xfer_index             = ctl_xfer_index_int;
  assign ctl_xfer_length            = ctl_xfer_length_int;

  assign ctl_xfer_request_o         = cfg_request ? 1'b0 : ctl_xfer_int;
  assign ctl_xfer_data_out_valid    = cfg_request ? 1'b0 : ctl_xfer_data_out_valid_int;

  // assign ctl_tready_o               = cfg_request ? 1'b0 : ctl_xfer_data_in_ready_int;
  assign ctl_tready_o               = ctl_xfer_data_in_ready_int;

  assign ctl_xfer_accept_int        = cfg_request ? ctl_xfer_accept_std : ctl_xfer_accept_i;
  assign ctl_xfer_done_int          = cfg_request ? 1'b1 : ctl_xfer_done;

  assign ctl_xfer_data_in_valid_int = cfg_request ? ctl_xfer_data_in_valid_std : ctl_tvalid_i;
  assign ctl_xfer_data_in_last_int  = cfg_request ? ctl_xfer_data_in_last_std : ctl_tlast_i;
  assign ctl_xfer_data_in_int       = cfg_request ? ctl_xfer_data_in_std : ctl_tdata_i;


  assign cfg_request                = cfg_request_q;  // | cfg_request_w;

  always @(posedge usb_clock) begin
    cfg_request_q <= cfg_request_w;
  end


  // -- AXI4 stream to/from ULPI stream -- //

  usb_ulpi #(
      .HIGH_SPEED(HIGH_SPEED)
  ) usb_ulpi_inst (
      .rst_n(1'b1),

      .ulpi_data_in(ulpi_data_in),
      .ulpi_data_out(ulpi_data_out),
      .ulpi_dir(ulpi_dir),
      .ulpi_nxt(ulpi_nxt),
      .ulpi_stp(ulpi_stp),
      .ulpi_reset(ulpi_reset),
      .ulpi_clk(usb_clock),

      .axis_rx_tvalid_o(axis_rx_tvalid),
      .axis_rx_tready_i(axis_rx_tready),
      .axis_rx_tlast_o (axis_rx_tlast),
      .axis_rx_tdata_o (axis_rx_tdata),

      .axis_tx_tvalid_i(axis_tx_tvalid),
      .axis_tx_tready_o(axis_tx_tready),
      .axis_tx_tlast_i (axis_tx_tlast),
      .axis_tx_tdata_i (axis_tx_tdata),

      .ulpi_rx_overflow_o(ulpi_rx_overflow_o),

      .usb_vbus_valid_o(usb_vbus_valid),
      .usb_reset_o(usb_reset),
      .usb_idle_o(usb_idle),
      .usb_suspend_o(usb_suspend)
  );


  // -- Encode/decode USB packets, over the AXI4 streams -- //

  encode_packet tx_usb_packet_inst (
      .reset(usb_reset),
      .clock(usb_clock),

      .tx_tvalid_o(axis_tx_tvalid),
      .tx_tready_i(axis_tx_tready),
      .tx_tlast_o (axis_tx_tlast),
      .tx_tdata_o (axis_tx_tdata),

      .hsk_send_i(tx_trn_send_hsk),
      .hsk_done_o(tx_trn_hsk_sent),
      .hsk_type_i(tx_trn_hsk_type),

      .tok_send_i(1'b0),
      .tok_done_o(),
      .tok_type_i(2'bx),
      .tok_data_i(16'bx),

      .trn_start_i (tx_trn_data_start),
      .trn_type_i  (tx_trn_data_type),
      .trn_tvalid_i(tx_trn_data_valid),
      .trn_tready_o(tx_trn_data_ready),
      .trn_tlast_i (tx_trn_data_last),
      .trn_tdata_i (tx_trn_data)
  );

  decode_packet rx_usb_packet_inst (
      .reset(usb_reset),
      .clock(usb_clock),

      .rx_tvalid_i(axis_rx_tvalid),
      .rx_tready_o(axis_rx_tready),
      .rx_tlast_i (axis_rx_tlast),
      .rx_tdata_i (axis_rx_tdata),

      .trn_start_o(trn_start),
      .trn_type_o(trn_type),
      .trn_address_o(trn_address),
      .trn_endpoint_o(trn_endpoint),
      .usb_address_i(device_address),

      .usb_sof_o(usb_sof),
      .crc_err_o(usb_crc_error_int),

      .rx_trn_valid_o(rx_trn_valid),
      .rx_trn_end_o  (rx_trn_end),
      .rx_trn_type_o (rx_trn_data_type),
      .rx_trn_data_o (rx_trn_data),

      .trn_hsk_type_o(rx_trn_hsk_type),
      .trn_hsk_recv_o(rx_trn_hsk_recv)
  );


  // -- Transfer USB packets to/from the control vs bulk endpoints -- //

  usb_xfer #(
      .HIGH_SPEED(HIGH_SPEED)
  ) usb_xfer_inst (
      .rst(usb_reset),
      .clk(usb_clock),

      .trn_type(trn_type),
      .trn_address(trn_address),
      .trn_endpoint(trn_endpoint),
      .trn_start(trn_start),

      .rx_trn_data_type(rx_trn_data_type),
      .rx_trn_end(rx_trn_end),
      .rx_trn_data(rx_trn_data),
      .rx_trn_valid(rx_trn_valid),
      .rx_trn_hsk_type(rx_trn_hsk_type),
      .rx_trn_hsk_recv(rx_trn_hsk_recv),

      .tx_trn_hsk_type(tx_trn_hsk_type),
      .tx_trn_send_hsk(tx_trn_send_hsk),
      .tx_trn_hsk_sent(tx_trn_hsk_sent),

      .tx_trn_data_type(tx_trn_data_type),
      .tx_trn_data_start(tx_trn_data_start),
      .tx_trn_data(tx_trn_data),
      .tx_trn_data_valid(tx_trn_data_valid),
      .tx_trn_data_ready(tx_trn_data_ready),
      .tx_trn_data_last(tx_trn_data_last),

      .crc_error(usb_crc_error_int),

      .ctl_xfer_o(ctl_xfer_int),
      .ctl_xfer_endpoint_o(ctl_xfer_endpoint_int),
      .ctl_xfer_type_o(ctl_xfer_type_int),
      .ctl_xfer_request_o(ctl_xfer_request_int),
      .ctl_xfer_value_o(ctl_xfer_value_int),
      .ctl_xfer_index_o(ctl_xfer_index_int),
      .ctl_xfer_length_o(ctl_xfer_length_int),
      .ctl_xfer_accept_i(ctl_xfer_accept_int),
      .ctl_xfer_done_i(ctl_xfer_done_int),

      .ctl_xfer_data_out(ctl_xfer_data_out),
      .ctl_xfer_data_out_valid(ctl_xfer_data_out_valid_int),

      .ctl_tvalid_i(ctl_xfer_data_in_valid_int),
      .ctl_tready_o(ctl_xfer_data_in_ready_int),
      .ctl_tlast_i (ctl_xfer_data_in_last_int),
      .ctl_tdata_i (ctl_xfer_data_in_int),

      .blk_xfer_endpoint_o(blk_xfer_endpoint),  // 4-bit EP address
      .blk_in_xfer_o(blk_in_xfer),
      .blk_out_xfer_o(blk_out_xfer),

      // From on-chip data source
      .bid_has_data_i(bid_has_data_i),
      .bid_tvalid_i(bid_tvalid_i),
      .bid_tready_o(bid_tready_o),
      .bid_tlast_i(bid_tlast_i),
      .bid_tdata_i(bid_tdata_i),

      .blk_xfer_out_ready_read(blk_xfer_out_ready_read),
      .blk_xfer_out_data(blk_xfer_out_data),
      .blk_xfer_out_data_valid(blk_xfer_out_data_valid)
  );


  // -- USB configuration endpoint -- //

  // fixme: inserting the following skid-register breaks the USB core, therefore
  //   not AXI4-Stream compatible ...

  wire cfgi_tvalid_w, cfgi_tready_w, cfgi_tlast_w;
  wire [7:0] cfgi_tdata_w;

  axis_skid #(
      .WIDTH (8),
      .BYPASS(1)
  ) cfg_skid_in_reg_inst (
      .clock(usb_clock),
      .reset(usb_reset),

      .s_tvalid(cfgi_tvalid_w),
      .s_tready(cfgi_tready_w),
      .s_tlast (cfgi_tlast_w),
      .s_tdata (cfgi_tdata_w),

      .m_tvalid(ctl_xfer_data_in_valid_std),
      .m_tready(ctl_xfer_data_in_ready_int),
      .m_tlast (ctl_xfer_data_in_last_std),
      .m_tdata (ctl_xfer_data_in_std)
  );


  // todo:
  //  - this module is messy -- does it work well enough?
  //  - does wrapping in skid-buffers break it !?
  usb_std_request #(
      .VENDOR_ID(VENDOR_ID),
      .PRODUCT_ID(PRODUCT_ID),
      .MANUFACTURER_LEN(MANUFACTURER_LEN),
      .MANUFACTURER(MANUFACTURER),
      .PRODUCT_LEN(PRODUCT_LEN),
      .PRODUCT(PRODUCT),
      .SERIAL_LEN(SERIAL_LEN),
      .SERIAL(SERIAL),
      .CONFIG_DESC_LEN(CONFIG_DESC_LEN),
      .CONFIG_DESC(CONFIG_DESC),
      .HIGH_SPEED(HIGH_SPEED)
  ) usb_std_request_inst (
      .reset(usb_reset),
      .clock(usb_clock),

      .ctl_xfer_endpoint(ctl_xfer_endpoint_int),
      .ctl_xfer_type(ctl_xfer_type_int),
      .ctl_xfer_request(ctl_xfer_request_int),
      .ctl_xfer_value(ctl_xfer_value_int),
      .ctl_xfer_index(ctl_xfer_index_int),
      .ctl_xfer_length(ctl_xfer_length_int),

      .ctl_xfer_gnt_o(ctl_xfer_accept_std),
      .ctl_xfer_req_i(ctl_xfer_int),

      .ctl_tvalid_o(cfgi_tvalid_w),
      .ctl_tready_i(cfgi_tready_w),
      .ctl_tlast_o (cfgi_tlast_w),
      .ctl_tdata_o (cfgi_tdata_w),

      .device_address(device_address),
      .current_configuration(current_configuration),
      .configured(usb_configured),
      .standart_request(cfg_request_w)
  );


endmodule  // usb_tlp
