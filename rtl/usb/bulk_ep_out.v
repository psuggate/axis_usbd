`timescale 1ns / 100ps
//////////////////////////////////////////////////////////////////////////////////
//
// Module Name: bulk_ep_out
// Project Name: axis_usbd
//
// Based on project 'https://github.com/ObKo/USBCore'
// License: MIT
//  Copyright (c) 2021 Dmitry Matyunin
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//
//////////////////////////////////////////////////////////////////////////////////

module bulk_ep_out #(
    parameter FPGA_VENDOR = "xilinx",
    parameter FPGA_FAMILY = "7series"
) (
    input wire reset_n,

    output wire status_full_o,

    input wire bulk_ep_out_clock,
    input wire bulk_ep_out_xfer_i,  // todo: also unconnected in original ...
    output wire bulk_ep_out_ready_read_o,

    input wire bulk_ep_out_tvalid_i,
    output wire bulk_ep_out_tready_o,
    input wire bulk_ep_out_tlast_i,
    input wire [7:0] bulk_ep_out_tdata_i,

    input wire axis_aclk,
    output wire axis_tvalid_o,
    input wire axis_tready_i,
    output wire axis_tlast_o,
    output wire [7:0] axis_tdata_o
);

  reg status_full;
  reg blk_xfer_out_ready_read_out;

  assign status_full_o = status_full;
  assign bulk_ep_out_ready_read_o = blk_xfer_out_ready_read_out;

  always @(posedge bulk_ep_out_clock) begin
    if (!reset_n) begin
      status_full <= 1'b0;
    end else begin
      status_full <= ~bulk_ep_out_tready_o;
    end
  end

`define __small_potatoes
`ifdef __small_potatoes
  // SRAM too small to properly determine "level" ...
  wire prog_full;

  assign prog_full = ~bulk_ep_out_tready_o | bulk_ep_out_tvalid_i & bulk_ep_out_tlast_i;

  always @(posedge bulk_ep_out_clock) begin
    if (!reset_n || bulk_ep_out_xfer_i) begin
      blk_xfer_out_ready_read_out <= 1'b1;
    end else if (prog_full) begin
      blk_xfer_out_ready_read_out <= 1'b0;
    end else begin
      blk_xfer_out_ready_read_out <= blk_xfer_out_ready_read_out;
    end
  end

`else

  wire [11:0] level_w;
  wire prog_full_w = level_w > 960;

  always @(posedge bulk_ep_out_clock) begin
    blk_xfer_out_ready_read_out <= ~prog_full_w;
  end

`endif


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
      .s_clk(bulk_ep_out_clock),
      .s_rst(~reset_n),
      .s_axis_tvalid(bulk_ep_out_tvalid_i),
      .s_axis_tready(bulk_ep_out_tready_o),
      .s_axis_tlast(bulk_ep_out_tlast_i),
      .s_axis_tdata(bulk_ep_out_tdata_i),
      .s_axis_tkeep(1'b0),
      .s_axis_tid(1'b0),
      .s_axis_tdest(1'b0),
      .s_axis_tuser(1'b0),

      // AXI output
      .m_clk(axis_aclk),
      .m_rst(~reset_n),
      .m_axis_tvalid(axis_tvalid_o),
      .m_axis_tready(axis_tready_i),
      .m_axis_tlast(axis_tlast_o),
      .m_axis_tdata(axis_tdata_o),
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
  ) axis_afifo_out_inst (
      .s_aresetn(reset_n),

      .s_aclk(bulk_ep_out_clock),
      .s_tvalid_i(bulk_ep_out_tvalid_i),
      .s_tready_o(bulk_ep_out_tready_o),
      .s_tlast_i(bulk_ep_out_tlast_i),
      .s_tdata_i(bulk_ep_out_tdata_i),

      .m_aclk(axis_aclk),
      .m_tvalid_o(axis_tvalid_o),
      .m_tready_i(axis_tready_i),
      .m_tlast_o(axis_tlast_o),
      .m_tdata_o(axis_tdata_o)
  );

`else

  wire bulk_tvalid, bulk_tready, bulk_tlast;
  wire [7:0] bulk_tdata;

  sync_fifo #(
      .WIDTH (9),
      .ABITS (11),
      .OUTREG(3)
  ) data_out_fifo_inst (
      .clock(bulk_ep_out_clock),
      .reset(~reset_n),

      .valid_i(bulk_ep_out_tvalid_i),
      .ready_o(bulk_ep_out_tready_o),
      .data_i ({bulk_ep_out_tlast_i, bulk_ep_out_tdata_i}),

      .valid_o(bulk_tvalid),
      .ready_i(bulk_tready),
      .data_o ({bulk_tlast, bulk_tdata})
  );

  axis_afifo #(
      .WIDTH(8),
      .ABITS(4)
  ) axis_afifo_out_inst (
      .s_aresetn(reset_n),

      .m_aclk(axis_aclk),
      .m_tvalid_o(axis_tvalid_o),
      .m_tready_i(axis_tready_i),
      .m_tlast_o(axis_tlast_o),
      .m_tdata_o(axis_tdata_o),

      .s_aclk(bulk_ep_out_clock),
      .s_tvalid_i(bulk_tvalid),
      .s_tready_o(bulk_tready),
      .s_tlast_i(bulk_tlast),
      .s_tdata_i(bulk_tdata)
  );

`endif
`endif

endmodule
