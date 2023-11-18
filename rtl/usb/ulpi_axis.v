`timescale 1ns / 100ps
module ulpi_axis (/*AUTOARG*/);

input reset;

input ulpi_clock_i;
output ulpi_rst_no;

input ulpi_dir_i;
output ulpi_stp_o;
input ulpi_nxt_i;
inout [7:0] ulpi_data_io;

output m_tvalid_o;
input m_tready_i;
output m_tlast_o;
output [7:0] m_tdata_o;


  localparam integer SUSPEND_TIME = 190000;  // ~3 ms
  localparam integer RESET_TIME = 190000;  // ~3 ms
  localparam integer CHIRP_K_TIME = 66000;  // ~1 ms
  localparam integer CHIRP_KJ_TIME = 120;  // ~2 us
  localparam integer SWITCH_TIME = 6000;  // ~100 us 


reg dir_q, nxt_q, stp_q;
reg [7:0] txdat_q, rxdat_q;
wire stp_w;

reg frame_q, valid_q, tlast_q;
reg [7:0] tdata_q;


assign ulpi_rst_no  = reset; // todo: okay ??
assign ulpi_stp_o   = stp_q;
assign ulpi_data_io = dir_q ? 'bz : txdat_q;

assign m_tvalid_o = valid_q;
assign m_tlast_o  = tlast_q;
assign m_tdata_o  = tdata_q;


wire rx_vld_w = dir_q && ulpi_dir_i && ulpi_nxt_i;
wire rx_end_w = dir_q && ulpi_dir_i && !ulpi_nxt_i && ulpi_data_io[5:4] != 2'b01;
wire rx_err_w = dir_q && ulpi_dir_i && !ulpi_nxt_i && ulpi_data_io[5:4] == 2'b11;


always @(posedge ulpi_clock_i) begin
  if (reset) begin
    frame_q <= 1'b0;
    valid_q <= 1'b0;
    tlast_q <= 1'bx;
    tdata_q <= 8'bx;
    rxdat_q <= 8'bx;
  end if (dir_q && ulpi_dir_i && ulpi_nxt_i) begin
    rxdat_q <= ulpi_data_io;

    if (!frame_q) begin
      valid_q <= 1'b0;
      frame_q <= 1'b1;
      tdata_q <= 'bx;
    end else begin
      valid_q <= 1'b1;
      tdata_q <= rdat_q;
    end
    tlast_q <= 1'b0;

  end else if (frame_q && dir_q == ulpi_dir_i && ( ((ulpi_dir_i == 1'b1) && (ulpi_data_in[4] == 1'b0)) || (ulpi_dir_i == 1'b0) ) ) begin
      tdata_q <= rxdat_q;
      valid_q <= 1'b1;
      tlast_q <= 1'b1;
      frame_q <= 1'b0;
    end else begin
      valid_q <= 1'b0;
      tlast_q  <= 1'b0;
    end
  end



endmodule // ulpi_axis
