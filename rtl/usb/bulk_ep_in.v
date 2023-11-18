`timescale 1ns / 100ps
//
// Based on project 'https://github.com/ObKo/USBCore'
// License: MIT
//  Copyright (c) 2021 Dmitry Matyunin
//
module bulk_ep_in (
    reset_n,

    status_full_o,

    axis_aclk,
    axis_tvalid_i,
    axis_tready_o,
    axis_tlast_i,
    axis_tdata_i,

    bulk_ep_in_clock,
    bulk_ep_in_xfer_i,
    bulk_ep_in_has_data_o,

    bulk_ep_in_tvalid_o,
    bulk_ep_in_tready_i,
    bulk_ep_in_tlast_o,
    bulk_ep_in_tdata_o
);

  parameter FPGA_VENDOR = "xilinx";
  parameter FPGA_FAMILY = "7series";

  input wire reset_n;

  output wire status_full_o;

  input wire axis_aclk;
  input wire axis_tvalid_i;
  output wire axis_tready_o;
  input wire axis_tlast_i;
  input wire [7:0] axis_tdata_i;

  input wire bulk_ep_in_clock;
  input wire bulk_ep_in_xfer_i;
  output wire bulk_ep_in_has_data_o;

  output wire bulk_ep_in_tvalid_o;
  input wire bulk_ep_in_tready_i;
  output wire bulk_ep_in_tlast_o;
  output wire [7:0] bulk_ep_in_tdata_o;

  localparam [0:0] STATE_IDLE = 0, STATE_XFER = 1;

  reg [0:0] state;

  wire prog_full;
  wire was_last_usb;
  wire prog_full_usb;
  reg status_full;
  reg was_last;
  reg bulk_xfer_in_has_data_out;

`define __small_potatoes
`ifdef __small_potatoes

  assign prog_full = ~axis_tready_o;

`else

  wire [11:0] level_w;
  wire prog_full_w = level_w > 64;
  reg prog_full_q;

  assign prog_full = prog_full_q;

  always @(posedge axis_aclk) begin
    prog_full_q <= prog_full_w;
  end

`endif

  assign status_full_o = status_full;
  assign bulk_ep_in_has_data_o = bulk_xfer_in_has_data_out;

  always @(posedge axis_aclk) begin
    if (!reset_n) begin
      status_full <= 1'b0;
    end else begin
      status_full <= ~axis_tready_o;
    end
  end

  always @(posedge bulk_ep_in_clock) begin
    if (reset_n == 1'b0) begin
      state <= STATE_IDLE;
      bulk_xfer_in_has_data_out <= 1'b0;
    end else begin
      case (state)
        STATE_IDLE: begin
          if ((was_last_usb == 1'b1) || (prog_full_usb == 1'b1)) begin
            bulk_xfer_in_has_data_out <= 1'b1;
          end
          if (bulk_ep_in_xfer_i == 1'b1) begin
            state <= STATE_XFER;
          end
        end
        STATE_XFER: begin
          if (bulk_ep_in_xfer_i == 1'b0) begin
            bulk_xfer_in_has_data_out <= 1'b0;
            state <= STATE_IDLE;
          end
        end
      endcase
    end
  end

  always @(posedge axis_aclk) begin
    if (reset_n == 1'b0) begin
      was_last <= 1'b0;
    end else begin
      if ((axis_tvalid_i == 1'b1) && (axis_tready_o == 1'b1) && (axis_tlast_i == 1'b1)) begin
        was_last <= 1'b1;
      end else if ((axis_tvalid_i == 1'b1) && (axis_tready_o == 1'b1) && (axis_tlast_i == 1'b0)) begin
        was_last <= 1'b0;
      end
    end
  end

// `define __no_potatoes
`ifdef __no_potatoes

  axis_async_fifo #(
`ifdef __small_potatoes
      .DEPTH(16),
      .RAM_PIPELINE(0),
`else
      .DEPTH(2048),
      .RAM_PIPELINE(1),
`endif
      .DATA_WIDTH(8),
      .KEEP_ENABLE(0),
      .KEEP_WIDTH(1),
      .LAST_ENABLE(1),
      .ID_ENABLE(0),
      .ID_WIDTH(1),
      .DEST_ENABLE(0),
      .DEST_WIDTH(1),
      .USER_ENABLE(1),
      .USER_WIDTH(1),
      .OUTPUT_FIFO_ENABLE(0),
      .FRAME_FIFO(0),
      .USER_BAD_FRAME_VALUE(0),
      .USER_BAD_FRAME_MASK(0),
      .DROP_BAD_FRAME(0),
      .DROP_WHEN_FULL(0)
  ) UUT (
      // AXI input
      .s_clk(axis_aclk),
      .s_rst(~reset_n),
      .s_axis_tdata(axis_tdata_i),
      .s_axis_tkeep(0),
      .s_axis_tvalid(axis_tvalid_i),
      .s_axis_tready(axis_tready_o),
      .s_axis_tlast(axis_tlast_i),
      .s_axis_tid(0),
      .s_axis_tdest(0),
      .s_axis_tuser(0),

      // AXI output
      .m_clk(bulk_ep_in_clock),
      .m_rst(~reset_n),
      .m_axis_tvalid(bulk_ep_in_tvalid_o),
      .m_axis_tready(bulk_ep_in_tready_i),
      .m_axis_tlast(bulk_ep_in_tlast_o),
      .m_axis_tdata(bulk_ep_in_tdata_o),
      .m_axis_tkeep(),
      .m_axis_tid(),
      .m_axis_tdest(),
      .m_axis_tuser(),

      .s_pause_req(0),
      .m_pause_req(0),

      // Status
      .s_status_overflow(),
      .s_status_depth(level_w),
      .s_status_bad_frame(),
      .s_status_good_frame(),
      .m_status_overflow(),
      .m_status_bad_frame(),
      .m_status_good_frame()
  );

`else
`ifdef __small_potatoes

  axis_afifo #(
      .WIDTH(8),
      .ABITS(4)
  ) axis_afifo_inst (
      .s_aresetn(reset_n),

      .s_aclk(axis_aclk),
      .s_tvalid_i(axis_tvalid_i),
      .s_tready_o(axis_tready_o),
      .s_tlast_i(axis_tlast_i),
      .s_tdata_i(axis_tdata_i),

      .m_aclk(bulk_ep_in_clock),
      .m_tvalid_o(bulk_ep_in_tvalid_o),
      .m_tready_i(bulk_ep_in_tready_i),
      .m_tlast_o(bulk_ep_in_tlast_o),
      .m_tdata_o(bulk_ep_in_tdata_o)
  );

`else

  wire bulk_tvalid, bulk_tready, bulk_tlast;
  wire [7:0] bulk_tdata;

  axis_afifo #(
      .WIDTH(8),
      .ABITS(4)
  ) axis_afifo_inst (
      .s_aresetn(reset_n),

      .s_aclk(axis_aclk),
      .s_tvalid_i(axis_tvalid_i),
      .s_tready_o(axis_tready_o),
      .s_tlast_i(axis_tlast_i),
      .s_tdata_i(axis_tdata_i),

      .m_aclk(bulk_ep_in_clock),
      .m_tvalid_o(bulk_tvalid),
      .m_tready_i(bulk_tready),
      .m_tlast_o(bulk_tlast),
      .m_tdata_o(bulk_tdata)
  );

  sync_fifo #(
      .WIDTH (9),
      .ABITS (11),
      .OUTREG(3)
  ) data_in_fifo_inst (
      .clock(bulk_ep_in_clock),
      .reset(~reset_n),

      .valid_i(bulk_tvalid),
      .ready_o(bulk_tready),
      .data_i ({bulk_tlast, bulk_tdata}),

      .valid_o(bulk_ep_in_tvalid_o),
      .ready_i(bulk_ep_in_tready_i),
      .data_o ({bulk_ep_in_tlast_o, bulk_ep_in_tdata_o})
  );

`endif
`endif

  arch_cdc_array #(
      .FPGA_VENDOR(FPGA_VENDOR),
      .FPGA_FAMILY(FPGA_FAMILY),
      .WIDTH(2)
  ) arch_cdc_array_inst (
      .src_clk (axis_aclk),
      .src_data({prog_full, was_last}),
      .dst_clk (bulk_ep_in_clock),
      .dst_data({prog_full_usb, was_last_usb})
  );

endmodule  // bulk_ep_in
