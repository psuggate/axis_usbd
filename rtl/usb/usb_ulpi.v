`timescale 1ns / 100ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer: Dmitry Matyunin (https://github.com/mcjtag)
// 
// Create Date: 20.03.2021 17:04:49
// Design Name: 
// Module Name: usb_ulpi
// Project Name: axis_usbd
// Target Devices:
// Tool Versions:
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
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

module usb_ulpi #(
    parameter integer HIGH_SPEED = 1
) (
    input wire rst_n,

    /* ULPI PHY signals */
    input wire ulpi_clk,
    output wire ulpi_reset,
    input wire [7:0] ulpi_data_in,
    output wire [7:0] ulpi_data_out,
    input wire ulpi_dir,
    input wire ulpi_nxt,
    output wire ulpi_stp,

    /* RX AXI-Stream, first data is PID */
    output wire axis_rx_tvalid_o,
    input wire axis_rx_tready_i,
    output wire axis_rx_tlast_o,
    output wire [7:0] axis_rx_tdata_o,

    /* TX AXI-Stream, first data should be PID (in 4 least significant bits) */
    input wire axis_tx_tvalid_i,
    output wire axis_tx_tready_o,
    input wire axis_tx_tlast_i,
    input wire [7:0] axis_tx_tdata_i,

    output ulpi_rx_overflow_o,

    output wire usb_vbus_valid_o,  /* VBUS has valid voltage */
    output wire usb_reset_o,  /* USB bus is in reset state */
    output wire usb_idle_o,  /* USB bus is in idle state */
    output wire usb_suspend_o  /* USB bus is in suspend state */
);

  localparam integer SUSPEND_TIME = 190000;  // ~3 ms
  localparam integer RESET_TIME = 190000;  // ~3 ms
  localparam integer CHIRP_K_TIME = 66000;  // ~1 ms
  localparam integer CHIRP_KJ_TIME = 120;  // ~2 us
  localparam integer SWITCH_TIME = 6000;  // ~100 us 

  localparam [3:0]
	STATE_INIT = 4'h0, 
	STATE_WRITE_REGA = 4'h1,
	STATE_WRITE_REGD = 4'h2,
	STATE_STP = 4'h3,
	STATE_RESET = 4'h4,
	STATE_SUSPEND = 4'h5,
	STATE_IDLE = 4'h6,
	STATE_TX = 4'h7,
	STATE_TX_LAST = 4'h8,
	STATE_CHIRP_START = 4'h9,
	STATE_CHIRP_STARTK = 4'hA,
	STATE_CHIRPK = 4'hB,
	STATE_CHIRPKJ = 4'hC,
	STATE_SWITCH_FSSTART = 4'hD,
	STATE_SWITCH_FS = 4'hE;

  reg [3:0] state, snext;

  reg dir_q, stp_q;
  reg [7:0] reg_data;
  reg [7:0] buf_data;
  reg buf_valid, buf_last;

  wire [3:0] tx_pid;
  wire tx_eop;
  wire bus_tx_ready_w;
  wire tx_ready_w;

  reg [2:0] chirp_kj_counter;
  reg hs_enabled = 1'b0;

  reg [1:0] usb_line_state;
  reg [17:0] state_counter;

  reg packet = 1'b0;
  reg [7:0] packet_buf;

  reg rx_tvalid;
  reg rx_tlast;
  reg [7:0] rx_tdata;
  reg tx_ready;

  reg usb_vbus_valid_out;
  reg [7:0] ulpi_data_out_buf;
  reg usb_reset_out;


  assign axis_rx_tvalid_o = rx_tvalid;
  assign axis_rx_tlast_o = rx_tlast;
  assign axis_rx_tdata_o = rx_tdata;

  // assign axis_tx_tready_o = tx_ready_w;
  assign axis_tx_tready_o = tx_ready;

  // todo: should this be registered ??
  assign ulpi_stp = ulpi_dir && !axis_rx_tready_i || state == STATE_STP;
  assign ulpi_reset = rst_n;
  assign ulpi_data_out = ulpi_data_out_buf;

  assign usb_vbus_valid_o = usb_vbus_valid_out;
  assign usb_reset_o = usb_reset_out;
  assign usb_idle_o = (state == STATE_IDLE) ? 1'b1 : 1'b0;
  assign usb_suspend_o = (state == STATE_SUSPEND) ? 1'b1 : 1'b0;


  // -- Errors in this ULPI Core -- //

  reg rx_err;

  assign ulpi_rx_overflow_o = rx_err;

  always @(posedge ulpi_clk) begin
    if (rst_n) begin
      rx_err <= 1'b0;
    end else if (rx_tvalid && !axis_rx_tready_i) begin
      rx_err <= 1'b1;
    end
  end


  // -- Chirping -- //

  always @(posedge ulpi_clk) begin
    if (dir_q && ulpi_dir && !ulpi_nxt && (ulpi_data_in[1:0] != usb_line_state)) begin
      if (state == STATE_CHIRPKJ) begin
        if (ulpi_data_in[1:0] == 2'b01) begin
          chirp_kj_counter <= chirp_kj_counter + 1;
        end
      end else begin
        chirp_kj_counter <= 0;
      end
      usb_line_state <= ulpi_data_in[1:0];
      state_counter  <= 0;
    end else if (state == STATE_CHIRP_STARTK) begin
      state_counter <= 0;
    end else if (state == STATE_SWITCH_FSSTART) begin
      state_counter <= 0;
    end else begin
      state_counter <= state_counter + 1;
    end
  end


  // -- Control Registers -- //

  always @(posedge ulpi_clk) begin
    dir_q <= ulpi_dir;
  end

  always @(posedge ulpi_clk) begin
    if (!dir_q && !ulpi_dir) begin
      if (state == STATE_RESET) begin
        usb_reset_out <= 1'b1;
      end else if (state == STATE_IDLE) begin
        usb_reset_out <= 1'b0;
      end else begin
        usb_reset_out <= usb_reset_out;
      end
    end else begin
      usb_reset_out <= usb_reset_out;
    end
  end

  always @(posedge ulpi_clk) begin
    if (!rst_n) begin
      hs_enabled <= 1'b0;
    end else begin
      case (state)
        STATE_SWITCH_FSSTART: begin
          hs_enabled <= 1'b0;
        end
        STATE_CHIRPKJ: begin
          hs_enabled <= 1'b1;
        end
        default: begin
          hs_enabled <= hs_enabled;
        end
      endcase
    end
  end

  // PHY is driving, and for an 'RX CMD', update bus-status
  always @(posedge ulpi_clk) begin
    if (dir_q && ulpi_dir && !ulpi_nxt) begin
      usb_vbus_valid_out <= ulpi_data_in[3:2] == 2'b11;
    end
  end


  // -- TX Flow Control -- //

  assign tx_ready_w = bus_tx_ready_w && (state == STATE_IDLE || state == STATE_TX && !buf_valid);
  assign bus_tx_ready_w = ~ulpi_dir & ~dir_q;

  `define __salad_farmer
`ifdef __salad_farmer
  always @(posedge ulpi_clk) begin
    if (dir_q || ulpi_dir) begin
      buf_valid <= 1'b0;
      buf_last  <= 1'bx;
      buf_data  <= 8'bx;

      tx_ready  <= 1'b0;
    end else begin
      case (state)
        STATE_IDLE: begin
          buf_data  <= 8'bx;
          buf_last  <= 1'bx;
          buf_valid <= 1'b0;

          if (usb_line_state == 2'b00 && state_counter > RESET_TIME) begin
            tx_ready <= 1'b0;
          end else if (!hs_enabled && usb_line_state == 2'b01 && state_counter > SUSPEND_TIME) begin
            tx_ready <= 1'b0;
          end else begin
            tx_ready <= 1'b1;
          end
        end

        STATE_TX: begin
          if (ulpi_nxt) begin
            buf_valid <= 1'b0;

            if (axis_tx_tvalid_i && !buf_valid) begin
              tx_ready <= ~axis_tx_tlast_i;
            end else if (buf_valid) begin
              tx_ready <= ~buf_last;
            end else begin
              tx_ready <= axis_tx_tvalid_i & ~axis_tx_tlast_i;
            end
          end else begin
            if (axis_tx_tvalid_i && tx_ready && !buf_valid) begin
              buf_data  <= axis_tx_tdata_i;
              buf_last  <= axis_tx_tlast_i;
              buf_valid <= 1'b1;
            end
            tx_ready <= 1'b0;
          end
        end

        default: begin
          buf_valid <= 1'b0;
          buf_last  <= 1'bx;
          buf_data  <= 8'bx;

          tx_ready  <= 1'b0;
        end
      endcase
    end
  end
`endif


  // -- Capture Incoming USB Packets -- //

  always @(posedge ulpi_clk) begin
    if (dir_q && ulpi_dir && ulpi_nxt) begin
      packet_buf <= ulpi_data_in;

      if (!packet) begin
        rx_tvalid <= 1'b0;
        packet <= 1'b1;
      end else begin
        rx_tdata  <= packet_buf;
        rx_tvalid <= 1'b1;
      end
      rx_tlast <= 1'b0;
    end else if (packet && dir_q && (ulpi_dir && ulpi_data_in[5:4] != 2'b01 || !ulpi_dir)) begin
      rx_tdata <= packet_buf;
      rx_tvalid <= 1'b1;
      rx_tlast <= 1'b1;
      packet <= 1'b0;
    end else begin
      rx_tvalid <= 1'b0;
      rx_tlast  <= 1'b0;
    end
  end


  // -- ULPI FSM -- //

  always @(posedge ulpi_clk) begin
    if (dir_q || ulpi_dir) begin
      // We are not driving
      state <= state;
      snext <= 'bx;
      ulpi_data_out_buf <= 'bx;
      reg_data <= 'bx;
    end else begin
      // We are driving
      case (state)
        default: begin  // STATE_INIT
          state <= STATE_WRITE_REGA;
          snext <= STATE_SWITCH_FSSTART;
          ulpi_data_out_buf <= 8'h8A;
          reg_data <= 8'h00;
        end

        // Update ULPI registers
        STATE_WRITE_REGA: begin
          if (ulpi_nxt) begin
            state <= STATE_WRITE_REGD;
            ulpi_data_out_buf <= reg_data;
            reg_data <= 'bx;
          end else begin
            state <= STATE_WRITE_REGA;
            ulpi_data_out_buf <= ulpi_data_out_buf;
            reg_data <= reg_data;
          end
          snext <= snext;
        end
        STATE_WRITE_REGD: begin
          if (ulpi_nxt) begin
            state <= STATE_STP;
            ulpi_data_out_buf <= 8'h00;
          end else begin
            state <= STATE_WRITE_REGD;
            ulpi_data_out_buf <= ulpi_data_out_buf;
          end
          snext <= snext;
          reg_data <= 'bx;
        end

        STATE_RESET: begin
          if (HIGH_SPEED == 1) begin
            state <= hs_enabled ? STATE_SWITCH_FSSTART : STATE_CHIRP_START;
          end else if (usb_line_state != 2'b00) begin
            state <= STATE_IDLE;
          end else begin
            state <= state;
          end
          snext <= 'bx;
          ulpi_data_out_buf <= 'bx;
          reg_data <= 'bx;
        end

        STATE_SUSPEND: begin
          if (usb_line_state != 2'b01) begin
            state <= STATE_IDLE;
          end
          snext <= 'bx;
          ulpi_data_out_buf <= 'bx;
          reg_data <= 'bx;
        end

        // TODO: turn 'stp' into a register, and remove this state ?!?
        STATE_STP: begin
          state <= snext;
          snext <= 'bx;
          ulpi_data_out_buf <= 'bx;
          reg_data <= 'bx;
        end

        STATE_IDLE: begin
          if (usb_line_state == 2'b00 && state_counter > RESET_TIME) begin
            state <= STATE_RESET;
            ulpi_data_out_buf <= 'bx;
          end else if (!hs_enabled && usb_line_state == 2'b01 && state_counter > SUSPEND_TIME) begin
            state <= STATE_SUSPEND;
            ulpi_data_out_buf <= 'bx;
          end else if (axis_tx_tvalid_i) begin
            ulpi_data_out_buf <= {4'b0100, axis_tx_tdata_i[3:0]};
            // buf_valid <= 1'b0;

            if (axis_tx_tlast_i) begin
              state <= STATE_TX_LAST;
            end else begin
              state <= STATE_TX;
            end
          end
          snext <= 'bx;
          reg_data <= 'bx;
        end

        STATE_TX: begin
          if (ulpi_nxt) begin
            if (axis_tx_tvalid_i && !buf_valid) begin
              ulpi_data_out_buf <= axis_tx_tdata_i;

              if (axis_tx_tlast_i) begin
                state <= STATE_TX_LAST;
              end
            end else if (buf_valid) begin
              ulpi_data_out_buf <= buf_data;
              // buf_valid <= 1'b0;
              if (buf_last) begin
                state <= STATE_TX_LAST;
              end
            end else begin
              ulpi_data_out_buf <= 8'h00;
            end
          end else begin
            if (axis_tx_tvalid_i && !buf_valid) begin
              // buf_data  <= axis_tx_tdata_i;
              // buf_last  <= axis_tx_tlast_i;
              // buf_valid <= 1'b1;
            end
          end
        end
        STATE_TX_LAST: begin
          if (ulpi_nxt) begin
            state <= STATE_STP;
            snext <= STATE_IDLE;
            ulpi_data_out_buf <= 8'h00;
          end else begin
            state <= STATE_TX_LAST;
            snext <= 'bx;
            ulpi_data_out_buf <= ulpi_data_out_buf;
          end
          reg_data <= 'bx;
        end

        STATE_CHIRP_START: begin
          reg_data <= 8'b0_1_0_10_1_00;
          ulpi_data_out_buf <= 8'h84;
          state <= STATE_WRITE_REGA;
          snext <= STATE_CHIRP_STARTK;
        end
        STATE_CHIRP_STARTK: begin
          if (ulpi_nxt) begin
            ulpi_data_out_buf <= 8'h00;
            state <= STATE_CHIRPK;
          end else begin
            ulpi_data_out_buf <= 8'h40;
            state <= STATE_CHIRP_STARTK;
          end
          snext <= 'bx;
          reg_data <= 'bx;
        end
        STATE_CHIRPK: begin
          if (state_counter > CHIRP_K_TIME) begin
            ulpi_data_out_buf <= 8'h00;
            state <= STATE_STP;
            snext <= STATE_CHIRPKJ;
          end
          reg_data <= 'bx;
        end
        STATE_CHIRPKJ: begin
          if (chirp_kj_counter > 3 && state_counter > CHIRP_KJ_TIME) begin
            reg_data <= 8'b0_1_0_00_0_00;
            ulpi_data_out_buf <= 8'h84;
            state <= STATE_WRITE_REGA;
            snext <= STATE_IDLE;
          end
        end

        STATE_SWITCH_FSSTART: begin
          reg_data <= 8'b0_1_0_00_1_01;
          ulpi_data_out_buf <= 8'h84;
          state <= STATE_WRITE_REGA;
          snext <= STATE_SWITCH_FS;
        end
        STATE_SWITCH_FS: begin
          if (state_counter > SWITCH_TIME) begin
            if (usb_line_state == 2'b00 && HIGH_SPEED == 1) begin
              state <= STATE_CHIRP_START;
            end else begin
              state <= STATE_IDLE;
            end
          end
          snext <= 'bx;
          ulpi_data_out_buf <= 'bx;
          reg_data <= 'bx;
        end
      endcase
    end
  end


endmodule
