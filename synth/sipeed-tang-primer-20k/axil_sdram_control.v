`timescale 1ns / 100ps
/**
 * Copyright (C) 2023, Patrick Suggate.
 *
 * Command scheduler for a GoWin DDR3 SDRAM controller. The AXI4-Lite interface
 * is for setting the read- & write- starting addresses. And the AXI4-Stream
 * interface is for streaming reads and writes, using the configured addresses.
 * Complete frames indicated via 's_tlast'/'m_tlast', and DDR3 SDRAM commands
 * are generated as required.
 * 
 * Note: the read and write FIFO's must be large enough to store an entire frame
 * of data.
 * 
 */
module axil_sdram_control (  /*AUTOARG*/);

  parameter DATA_WIDTH = 32;
  localparam DATA_STRBS = DATA_WIDTH / 8;
  localparam MSB = DATA_WIDTH - 1;
  localparam SSB = DATA_STRBS - 1;

  parameter ADDR_WIDTH = 24;
  localparam ASB = ADDR_WIDTH - 1;

  parameter AXIS_WIDTH = 8;
  localparam XSB = AXIS_WIDTH - 1;


  input axi_clock;
  input axi_reset;

  // -- AXI4-Lite Controller Write & Read Channel -- //

  input aw_valid;
  output aw_ready;
  input [2:0] aw_prot;
  input [ASB:0] aw_addr;

  input wr_valid;
  output wr_ready;
  input [SSB:0] wr_strb;
  input [MSB:0] wr_data;

  output wb_valid;
  input wb_ready;
  output wb_resp;

  input ar_valid;
  output ar_ready;
  input [2:0] ar_prot;
  input [ASB:0] ar_addr;

  output rd_valid;
  input rd_ready;
  output rd_resp;
  output [MSB:0] rd_data;

  // -- AXI4-Stream Data Write & Read Channels -- //

  input s_tvalid;
  output s_tready;
  input s_tlast;
  input [XSB:0] s_tdata;

  output m_tvalid;
  input m_tready;
  output m_tlast;
  output [XSB:0] m_tdata;

  // -- To DDR3 Controller -- //

  input ddr_clock;
  input ddr_rst_n;

  output dc_valid;
  input dc_ready;
  output [2:0] dc_command;
  output [5:0] dc_blength;

  output dw_valid;
  input dw_ready;
  output dw_last;
  output [15:0] dw_stb_n;
  output [127:0] dw_data;

  input dr_valid;
  input dr_last;
  input [127:0] dr_data;


  // AXI4-Lite commands are fairly limited ...
  assign dc_blength = 6'h00;


  // -- FIFOs store incoming read & write requests -- //

  // Store:
  //
  //  - command (read or write)
  //  - address
  //  - burst length
  //  - write data
  //  - read & write responses


  localparam COMMAND_WIDTH = 1 + 6 + ADDR_WIDTH;
  localparam CSB = COMMAND_WIDTH - 1;

  wire cmd_mode;
  wire [5:0] cmd_size;
  wire [ASB:0] cmd_addr;

  wire [CSB:0] cmd_data = {cmd_mode, cmd_size, cmd_addr};

  axis_afifo #(
      .WIDTH(COMMAND_WIDTH),
      .ABITS(4)
  ) command_afifo_inst (
      .s_aresetn(reset_n),

      .s_aclk    (axi_clock),
      .s_tvalid_i(m_tvalid),
      .s_tready_o(m_tready),
      .s_tlast_i (m_tlast),
      .s_tdata_i (m_tdata),

      .m_aclk    (ddr_clock),
      .m_tvalid_o(s_tvalid),
      .m_tready_i(s_tready),
      .m_tlast_o (s_tlast),
      .m_tdata_o (s_tdata)
  );

  axis_async_fifo #(
      .WIDTH(DATA_WIDTH),
      .ABITS(9)
  ) write_data_afifo_inst (
      .s_aresetn(reset_n),

      .s_aclk    (axi_clock),
      .s_tvalid_i(m_tvalid),
      .s_tready_o(m_tready),
      .s_tlast_i (m_tlast),
      .s_tdata_i (m_tdata),

      .m_aclk    (ddr_clock),
      .m_tvalid_o(s_tvalid),
      .m_tready_i(s_tready),
      .m_tlast_o (s_tlast),
      .m_tdata_o (s_tdata)
  );


  // -- DDR3 SDRAM command scheduler -- //

  always @(posedge ddr_clock) begin
  end


endmodule  // axil_sdram_control
