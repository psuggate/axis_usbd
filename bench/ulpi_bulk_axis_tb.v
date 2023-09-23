`timescale 1ns / 100ps
module axis_usbd_tb;

  localparam string FPGA_VENDOR = "gowin";
  localparam string FPGA_FAMILY = "gw2a";
  localparam bit [63:0] SERIAL_NUMBER = "FACE0123";

  localparam bit HIGH_SPEED = 1'b1;
  localparam bit CHANNEL_IN_ENABLE = 1'b1;
  localparam bit CHANNEL_OUT_ENABLE = 1'b1;
  localparam bit PACKET_MODE = 1'b0;


  // -- Global system signals -- //

  reg usb_clk = 1'b1;
  reg axi_clk = 1'b1;
  reg reset_n = 1'b0;

  always #8 usb_clk <= ~usb_clk;
  always #5 axi_clk <= ~axi_clk;


  // -- Simulaton stimulus -- //

  initial begin : STIM
    #50 reset_n <= 1'b1;
    $dumpfile("ulpi_bulk_axis_tb.vcd");
    $dumpvars;

    #800 $finish;
  end  // STIM


  // -- Logic for communicating with the MUT -- //

  wire ulpi_dir, ulpi_nxt, ulpi_stp;
  wire [7:0] ulpi_data_i, ulpi_data_o;
  wire [7:0] ulpi_data_w = ulpi_data_t ? ulpi_data_i : ulpi_data_o;

  reg s_tvalid, s_tlast, m_tready;
  reg [7:0] s_tdata;

  wire s_tready, m_tvalid, m_tlast;
  wire [7:0] m_tdata;


  // -- Module Under Test -- //

  ulpi_bulk_axis #(
      .FPGA_VENDOR(FPGA_VENDOR),
      .FPGA_FAMILY(FPGA_FAMILY),
      .HIGH_SPEED(HIGH_SPEED),
      .SERIAL_NUMBER(SERIAL_NUMBER),
      .CHANNEL_IN_ENABLE(CHANNEL_IN_ENABLE),
      .CHANNEL_OUT_ENABLE(CHANNEL_OUT_ENABLE),
      .PACKET_MODE(PACKET_MODE)
  ) ulpi_bulk_axis_inst (
      .ulpi_clock_i(usb_clk),
      .ulpi_reset_o(usb_rst),
      .ulpi_dir_i  (ulpi_dir),
      .ulpi_nxt_i  (ulpi_nxt),
      .ulpi_stp_o  (ulpi_stp),
      .ulpi_data_t (ulpi_data_t),
      .ulpi_data_i (ulpi_data_i),
      .ulpi_data_o (ulpi_data_o),

      .aclk(axi_clk),
      .aresetn(reset_n),

      .s_axis_tvalid_i(),
      .s_axis_tready_o(),
      .s_axis_tlast_i (),
      .s_axis_tdata_i (),

      .m_axis_tvalid_o(),
      .m_axis_tready_i(),
      .m_axis_tlast_o (),
      .m_axis_tdata_o ()
  );


endmodule  // axis_usbd_tb
