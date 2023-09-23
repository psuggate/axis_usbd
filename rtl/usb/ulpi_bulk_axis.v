`timescale 1ns / 100ps
`define SERIAL_NUMBER "BULK0000"
/**
 * Top-level USB ULPI Bulk transfer endpoint (IN and/or OUT) core.
 * 
 * Note: Data from/to this core is via AXI4 Stream interconnects.
 */
module ulpi_bulk_axis (  /*AUTOARG*/);

  parameter FPGA_VENDOR = "xilinx";  // todo: keep this, and add "gowin"?
  parameter FPGA_FAMILY = "7series";

  // USB configuration
  parameter integer HIGH_SPEED = 1;  /* 0 - Full-Speed; 1 - High-Speed */
  parameter [63:0] SERIAL_NUMBER = `SERIAL_NUMBER;
  parameter CHANNEL_IN_ENABLE = 1;  /* 0 - Disable; 1 - Enable */
  parameter CHANNEL_OUT_ENABLE = 1;  /* 0 - Disable; 1 - Enable */

  // todo: does this still do anything ??
  parameter PACKET_MODE = 0;  /* 0 - Stream Mode; 1 - Packet Mode */

  /* UTMI Low Pin Interface Ports */
  input wire ulpi_clk;
  output wire ulpi_reset;

  input wire ulpi_dir;
  input wire ulpi_nxt;
  output wire ulpi_stp;
  output wire ulpi_data_t;
  input wire [7:0] ulpi_data_i;
  output wire [7:0] ulpi_data_o;

  /* AXI4-Stream Interface */
  input wire aclk;
  input wire aresetn;

  input wire s_axis_tvalid;
  output wire s_axis_tready;
  input wire s_axis_tlast;
  input wire [7:0] s_axis_tdata;

  output wire m_axis_tvalid;
  input wire m_axis_tready;
  output wire [7:0] m_axis_tdata;
  output wire m_axis_tlast;


  function [15:0] config_channel;
    input integer enable;
    input integer width;
    input integer endian;
    input integer fifo_enable;
    input integer fifo_packet;
    input integer fifo_depth;
    reg [4:0] log_value;
    begin

      config_channel = 16'h0000;

      case (enable)
        0: config_channel[0] = 1'b0;
        1: config_channel[0] = 1'b1;
        default: config_channel[0] = 1'b0;
      endcase

      case (width)
        8: config_channel[2:1] = 2'b01;
        16: config_channel[2:1] = 2'b10;
        32: config_channel[2:1] = 2'b11;
        default: config_channel[2:1] = 2'b00;
      endcase

      case (endian)
        0: config_channel[3] = 1'b0;
        1: config_channel[3] = 1'b1;
        default: config_channel[3] = 1'b0;
      endcase

      case (fifo_enable)
        0: config_channel[4] = 1'b0;
        1: config_channel[4] = 1'b1;
        default: config_channel[4] = 1'b0;
      endcase

      case (fifo_packet)
        0: config_channel[5] = 1'b0;
        1: config_channel[5] = 1'b1;
        default: config_channel[5] = 1'b0;
      endcase

      log_value = $clog2(fifo_depth);
      config_channel[10:6] = log_value;

    end
  endfunction

  localparam [15:0] CONFIG_CHAN_IN = config_channel(CHANNEL_IN_ENABLE, 8, 0, 0, 0, 0);
  localparam [15:0] CONFIG_CHAN_OUT = config_channel(CHANNEL_OUT_ENABLE, 8, 0, 0, 0, 0);


  // todo: this is what 'axis_usbd' uses, but check the ULPI specs/timing diagrams
  assign ulpi_data_t = ulpi_dir;

  bulk_ep_axis_bridge #(
      .FPGA_VENDOR(FPGA_VENDOR),
      .FPGA_FAMILY(FPGA_FAMILY),
      .HIGH_SPEED(HIGH_SPEED),
      .PACKET_MODE(PACKET_MODE),
      .CONFIG_CHAN({CONFIG_CHAN_OUT, CONFIG_CHAN_IN}),
      .SERIAL(SERIAL_NUMBER)
  ) bulk_ep_axis_bridge_inst (
      .sys_clk(aclk),
      .reset_n(aresetn),

      .ulpi_clk(ulpi_clk),
      .ulpi_reset(ulpi_reset),
      .ulpi_dir(ulpi_dir),
      .ulpi_nxt(ulpi_nxt),
      .ulpi_stp(ulpi_stp),
      .ulpi_data_in(ulpi_data_i),
      .ulpi_data_out(ulpi_data_o),

      .s_axis_tvalid(m_axis_tvalid),
      .s_axis_tready(m_axis_tready),
      .s_axis_tdata (m_axis_tdata),
      .s_axis_tlast (m_axis_tlast),

      .m_axis_tvalid(s_axis_tvalid),
      .m_axis_tready(s_axis_tready),
      .m_axis_tdata (s_axis_tdata),
      .m_axis_tlast (s_axis_tlast)
  );

endmodule  // ulpi_bulk_axis
