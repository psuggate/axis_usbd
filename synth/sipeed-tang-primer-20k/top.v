`timescale 1ns / 100ps
module top (
    input clk_26,
    input rst_n,

    // -- USB PHY (ULPI) -- //
    output wire       ulpi_rst,
    input  wire       ulpi_clk,
    input  wire       ulpi_dir,
    input  wire       ulpi_nxt,
    output wire       ulpi_stp,
    inout  wire [7:0] ulpi_data,

    output [14-1:0] ddr_addr,     //ROW_WIDTH=14
    output [ 3-1:0] ddr_bank,     //BANK_WIDTH=3
    output          ddr_cs,
    output          ddr_ras,
    output          ddr_cas,
    output          ddr_we,
    output          ddr_ck,
    output          ddr_ck_n,
    output          ddr_cke,
    output          ddr_odt,
    output          ddr_reset_n,
    output [ 2-1:0] ddr_dm,       //DM_WIDTH=2
    inout  [16-1:0] ddr_dq,       //DQ_WIDTH=16
    inout  [ 2-1:0] ddr_dqs,      //DQS_WIDTH=2
    inout  [ 2-1:0] ddr_dqs_n     //DQS_WIDTH=2
);

  localparam FPGA_VENDOR = "gowin";
  localparam FPGA_FAMILY = "gw2a";
  localparam [63:0] SERIAL_NUMBER = "GULP0123";

  localparam HIGH_SPEED = 1'b1;
  localparam CHANNEL_IN_ENABLE = 1'b1;
  localparam CHANNEL_OUT_ENABLE = 1'b1;
  localparam PACKET_MODE = 1'b0;


  // -- IOBs -- //

  // -- PLL -- //

  wire axi_clk, axi_lock;
  wire usb_clk, usb_rst_n;
  wire ddr_clk, ddr_lock;

wire clk_x1;

  // So 27.0 MHz divided by 9, then x40 = 120 MHz.
  gowin_rpll #(
      .FCLKIN("27"),
      .IDIV_SEL(8),  // ~=  9
      .FBDIV_SEL(39),  // ~= 40
      .ODIV_SEL(8)
  ) axis_rpll_inst (
      .clkout(axi_clk),   // 120 MHz
      .lock  (axi_lock),
      .clkin (clk_26)
  );

  gowin_rpll #(
      .FCLKIN("27"),
      .IDIV_SEL(3),  // ~=  4
      .FBDIV_SEL(58),  // ~= 59
      .ODIV_SEL(2)  // ??
  ) ddr3_rpll_inst (
      .clkout(ddr_clk),   // 400 MHz
      .lock  (ddr_lock),
      .clkin (clk_26)
  );


  // -- Globalists -- //

  reg reset_n;
  reg rst_n2, rst_n1, rst_n0;

  always @(posedge axi_clk) begin
    {reset_n, rst_n2, rst_n1, rst_n0} <= {rst_n2, rst_n1, rst_n0, rst_n};
  end


  // -- USB ULPI Bulk transfer endpoint (IN & OUT) -- //

  wire ulpi_data_t;
  wire [7:0] ulpi_data_o;

  assign ulpi_rst  = usb_rst_n;
  assign usb_clk   = ~ulpi_clk;
  assign ulpi_data = ulpi_data_t ? {8{1'bz}} : ulpi_data_o;

  wire s_tvalid, s_tready, s_tlast;
  wire [7:0] s_tdata;

  wire m_tvalid, m_tready, m_tlast;
  wire [7:0] m_tdata;

  ulpi_bulk_axis #(
      .FPGA_VENDOR(FPGA_VENDOR),
      .FPGA_FAMILY(FPGA_FAMILY),
      .VENDOR_ID(16'hF4CE),
      .PRODUCT_ID(16'h0003),
      .HIGH_SPEED(HIGH_SPEED),
      .SERIAL_NUMBER(SERIAL_NUMBER),
      .CHANNEL_IN_ENABLE(CHANNEL_IN_ENABLE),
      .CHANNEL_OUT_ENABLE(CHANNEL_OUT_ENABLE),
      .PACKET_MODE(PACKET_MODE)
  ) ulpi_bulk_axis_inst (
      .ulpi_clock_i(usb_clk),
      .ulpi_reset_o(usb_rst_n),

      .ulpi_dir_i (ulpi_dir),
      .ulpi_nxt_i (ulpi_nxt),
      .ulpi_stp_o (ulpi_stp),
      .ulpi_data_t(ulpi_data_t),
      .ulpi_data_i(ulpi_data),
      .ulpi_data_o(ulpi_data_o),

      .aclk(axi_clk),
      .aresetn(reset_n),

      .s_axis_tvalid_i(s_tvalid),
      .s_axis_tready_o(s_tready),
      .s_axis_tlast_i (s_tlast),
      .s_axis_tdata_i (s_tdata),

      .m_axis_tvalid_o(m_tvalid),
      .m_axis_tready_i(m_tready),
      .m_axis_tlast_o (m_tlast),
      .m_axis_tdata_o (m_tdata)
  );


  // -- Just echo/loop IN <-> OUT -- //

  axis_afifo #(
      .WIDTH(8),
      .ABITS(4)
  ) axis_afifo_inst (
      .s_aresetn(reset_n),

      .s_aclk    (axi_clk),
      .s_tvalid_i(m_tvalid),
      .s_tready_o(m_tready),
      .s_tlast_i (m_tlast),
      .s_tdata_i (m_tdata),

      .m_aclk    (axi_clk),
      .m_tvalid_o(s_tvalid),
      .m_tready_i(s_tready),
      .m_tlast_o (s_tlast),
      .m_tdata_o (s_tdata)
  );


  // -- Yucky DDR3 SDRAM core from GoWin -- //

reg [5:0] app_burst_number; // ??
reg [26:0] ap_addr;
reg [2:0] ap_cmd;
reg ap_valid;
wire ap_ready;

reg wr_valid, wr_last;
wire wr_ready;
reg [15:0] wr_stb_n;
reg [127:0] wr_data;

wire rd_valid, rd_last;
wire [127:0] rd_data;

wire init_calib_complete;

always @(posedge clk_x1) begin
  if (!rst_n) begin
    wr_valid <= 1'b0;
    wr_stb_n <= 16'h0000;
  end
end

always @(posedge clk_x1) begin
  if (!rst_n) begin
    app_burst_number <= 6'h00;
    ap_addr <= 27'h0000000;
    ap_cmd <= 3'h0;
    ap_valid <= 1'b0;
  end else begin
    ap_cmd <= ap_cmd;
  end
end


  DDR3_Memory_Interface_Top ddr3_inst (
      .clk(clk_26),  // from on-board oscillator
      .rst_n(rst_n), // global reset

      .memory_clk(ddr_clk),
      .pll_lock(ddr_lock),

      .app_burst_number(app_burst_number),
      .cmd_ready(ap_ready),
      .cmd(ap_cmd),
      .cmd_en(ap_valid),
      .addr({1'b0, ap_addr}),

      .wr_data_rdy(wr_ready),
      .wr_data(wr_data),
      .wr_data_en(wr_valid),
      .wr_data_end(wr_last),
      .wr_data_mask(wr_stb_n),

      .rd_data(rd_data),
      .rd_data_valid(rd_valid),
      .rd_data_end(rd_last),

      .sr_req(1'b0),
      .sr_ack(),
      .ref_req(1'b0),
      .ref_ack(),

      .init_calib_complete(init_calib_complete),
      .clk_out(clk_x1),
      .burst(1'b1),

      // mem interface
      .ddr_rst      (),
      .O_ddr_addr   (ddr_addr),
      .O_ddr_ba     (ddr_bank),
      .O_ddr_cs_n   (ddr_cs),
      .O_ddr_ras_n  (ddr_ras),
      .O_ddr_cas_n  (ddr_cas),
      .O_ddr_we_n   (ddr_we),
      .O_ddr_clk    (ddr_ck),
      .O_ddr_clk_n  (ddr_ck_n),
      .O_ddr_cke    (ddr_cke),
      .O_ddr_odt    (ddr_odt),
      .O_ddr_reset_n(ddr_reset_n),
      .O_ddr_dqm    (ddr_dm),
      .IO_ddr_dq    (ddr_dq),
      .IO_ddr_dqs   (ddr_dqs),
      .IO_ddr_dqs_n (ddr_dqs_n)
  );


endmodule  // top
