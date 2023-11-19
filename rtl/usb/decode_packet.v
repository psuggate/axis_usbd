`timescale 1ns / 100ps
//
// Based on project 'https://github.com/ObKo/USBCore'
// License: MIT
//  Copyright (c) 2021 Dmitry Matyunin
//
module decode_packet #(
    parameter SINGLE_TRANSACTION_TYPE_REGISTER = 1
) (
    input wire reset,
    input wire clock,

    output wire usb_sof_o,
    output wire crc_err_o,

    input wire rx_tvalid_i,
    output wire rx_tready_o,
    input wire rx_tlast_i,
    input wire [7:0] rx_tdata_i,

    output wire trn_start_o,
    output wire [1:0] trn_type_o,
    output wire [6:0] trn_address_o,
    output wire [3:0] trn_endpoint_o,
    input wire [6:0] usb_address_i,

    output wire rx_trn_valid_o,
    output wire rx_trn_end_o,
    output wire [1:0] rx_trn_type_o, /* DATA0/1/2 MDATA */
    output wire [7:0] rx_trn_data_o,

    output wire trn_hsk_recv_o,
    output wire [1:0] trn_hsk_type_o /* 00 - ACK, 10 - NAK, 11 - STALL, 01 - NYET */
);

  function [4:0] crc5;
    input [10:0] x;
    begin
      crc5[4] = ~(1'b1 ^ x[10] ^ x[7] ^ x[5] ^ x[4] ^ x[1] ^ x[0]);
      crc5[3] = ~(1'b1 ^ x[9] ^ x[6] ^ x[4] ^ x[3] ^ x[0]);
      crc5[2] = ~(1'b1 ^ x[10] ^ x[8] ^ x[7] ^ x[4] ^ x[3] ^ x[2] ^ x[1] ^ x[0]);
      crc5[1] = ~(1'b0 ^ x[9] ^ x[7] ^ x[6] ^ x[3] ^ x[2] ^ x[1] ^ x[0]);
      crc5[0] = ~(1'b1 ^ x[8] ^ x[6] ^ x[5] ^ x[2] ^ x[1] ^ x[0]);
    end
  endfunction

  function [15:0] crc16;
    input [7:0] d;
    input [15:0] c;
    begin
      crc16[0] = d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[5] ^ d[6] ^ d[7] ^ c[8] ^
                 c[9] ^ c[10] ^ c[11] ^ c[12] ^ c[13] ^ c[14] ^ c[15];
      crc16[1] = d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[5] ^ d[6] ^ c[9] ^ c[10] ^
                 c[11] ^ c[12] ^ c[13] ^ c[14] ^ c[15];
      crc16[2] = d[6] ^ d[7] ^ c[8] ^ c[9];
      crc16[3] = d[5] ^ d[6] ^ c[9] ^ c[10];
      crc16[4] = d[4] ^ d[5] ^ c[10] ^ c[11];
      crc16[5] = d[3] ^ d[4] ^ c[11] ^ c[12];
      crc16[6] = d[2] ^ d[3] ^ c[12] ^ c[13];
      crc16[7] = d[1] ^ d[2] ^ c[13] ^ c[14];
      crc16[8] = d[0] ^ d[1] ^ c[0] ^ c[14] ^ c[15];
      crc16[9] = d[0] ^ c[1] ^ c[15];
      crc16[10] = c[2];
      crc16[11] = c[3];
      crc16[12] = c[4];
      crc16[13] = c[5];
      crc16[14] = c[6];
      crc16[15] = d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[5] ^ d[6] ^ d[7] ^ c[7] ^
                  c[8] ^ c[9] ^ c[10] ^ c[11] ^ c[12] ^ c[13] ^ c[14] ^ c[15];
    end
  endfunction

  localparam  [6:0]
	ST_IDLE      = 7'h01,
	ST_SOF       = 7'h02,
	ST_SOF_CRC    = 7'h04,
	ST_TOKEN     = 7'h08,
	ST_TOKEN_CRC = 7'h10,
	ST_DATA      = 7'h20,
	ST_DATA_CRC  = 7'h40;

  reg [6:0] rx_state;

  reg [10:0] token_data;
  reg [4:0] token_crc5;
  reg [15:0] rx_crc16;
  reg [7:0] rx_buf1, rx_buf2;
  wire addr_match_w;
  wire [15:0] rx_data_crc_w;
  wire [4:0] rx_crc5_w;
  wire [3:0] rx_pid_pw, rx_pid_nw;

  reg sof_flag, crc_err_flag;
  reg trn_start_q, rx_trn_end_q, rx_trn_hsk_recv_q;
  reg [1:0] trn_type_q, rx_trn_type_q, rx_trn_hsk_type_q;

  reg rx_vld0, rx_vld1, rx_valid_q, rx_trn_valid_q;


  // -- Input/Output Assignments -- //

  assign usb_sof_o = sof_flag;
  assign crc_err_o = crc_err_flag;

  assign rx_tready_o = 1'b1; // todo: can this fail ??

  // Rx data-path (from USB host) to either USB config OR bulk EP cores
  assign rx_trn_valid_o = rx_trn_valid_q;
  assign rx_trn_end_o   = rx_trn_end_q;
  assign rx_trn_type_o  = SINGLE_TRANSACTION_TYPE_REGISTER ? trn_type_q : rx_trn_type_q;
  assign rx_trn_data_o  = rx_buf1;

  assign trn_hsk_recv_o = rx_trn_hsk_recv_q;
  assign trn_hsk_type_o = SINGLE_TRANSACTION_TYPE_REGISTER ? trn_type_q : rx_trn_hsk_type_q;

  assign trn_start_o    = trn_start_q;
  assign trn_type_o     = trn_type_q;
  assign trn_address_o  = token_data[6:0];
  assign trn_endpoint_o = token_data[10:7];


  // -- Internal Signals -- //

  assign rx_pid_pw     = rx_tdata_i[3:0];
  assign rx_pid_nw     = ~rx_tdata_i[7:4];
  assign rx_crc5_w     = crc5(token_data);
  assign rx_data_crc_w = {rx_buf2, rx_buf1};
  assign addr_match_w  = trn_address_o == usb_address_i;


  // -- Rx Data -- //

  always @(posedge clock) begin
    if (rx_state == ST_DATA) begin
      rx_trn_valid_q <= rx_tvalid_i && !rx_tlast_i && rx_vld0 && addr_match_w;
    end else begin
      rx_trn_valid_q <= 1'b0;
    end
  end

  always @(posedge clock) begin
    if (rx_state == ST_IDLE) begin
      {rx_vld1, rx_vld0} <= 2'b00;
      rx_valid_q <= 1'b0;
    end else if (rx_tvalid_i) begin
      {rx_vld1, rx_vld0} <= {rx_vld0, 1'b1};
      rx_valid_q <= rx_vld0 && addr_match_w;
    end

    if (rx_tvalid_i) begin
      {rx_buf1, rx_buf2} <= {rx_buf2, rx_tdata_i};
    end else begin
      {rx_buf1, rx_buf2} <= {rx_buf2, 8'bx};
    end
  end

  /* Rx Data CRC Calculation */
  always @(posedge clock) begin
    if (rx_state == ST_IDLE) begin
      rx_crc16 <= 16'hFFFF;
    end else if (rx_state == ST_DATA && rx_tvalid_i && rx_vld1) begin
      rx_crc16 <= crc16(rx_buf1, rx_crc16);
    end
  end


  // -- Start-Of-Frame Signal -- //

  always @(posedge clock) begin
    case (rx_state)
      ST_SOF_CRC: sof_flag <= token_crc5 == rx_crc5_w;
      default: sof_flag <= 1'b0;
    endcase
  end

  always @(posedge clock) begin
    case (rx_state)
      ST_SOF_CRC, ST_TOKEN_CRC: crc_err_flag <= token_crc5 != rx_crc5_w;
      ST_DATA_CRC: crc_err_flag <= rx_data_crc_w != rx_crc16;
      default: crc_err_flag <= 1'b0;
    endcase
  end

  // Strobes that indicate the start and end of a (received) packet.
  always @(posedge clock) begin
    case (rx_state)
      ST_TOKEN_CRC: begin
        trn_start_q  <= usb_address_i == token_data[6:0] && token_crc5 == rx_crc5_w;
        rx_trn_end_q <= 1'b0;
      end
      ST_DATA_CRC: begin
        trn_start_q  <= 1'b0;
        rx_trn_end_q <= addr_match_w;
      end
      default: begin
        trn_start_q  <= 1'b0;
        rx_trn_end_q <= 1'b0;
      end
    endcase
  end

  // Note: these data are also used for the USB device address & endpoint
  always @(posedge clock) begin
    case (rx_state)
      ST_TOKEN, ST_SOF: begin
        if (rx_tvalid_i) begin
          token_data[7:0] <= rx_vld0 ? token_data[7:0] : rx_tdata_i;
          token_data[10:8] <= rx_vld0 && !rx_vld1 ? rx_tdata_i[2:0] : token_data[10:8];
          token_crc5 <= rx_vld0 && !rx_vld1 ? rx_tdata_i[7:3] : token_crc5;
        end
      end
      default: begin
        token_data <= token_data;
        token_crc5 <= token_crc5;
      end
    endcase
  end


  // -- Rx FSM -- //

  always @(posedge clock) begin
    if (reset) begin
      rx_state <= ST_IDLE;
    end else begin
      case (rx_state)
        ST_IDLE: begin
          if (rx_tvalid_i && rx_pid_pw == rx_pid_nw) begin
            if (rx_pid_pw == 4'b0101) begin
              rx_state <= ST_SOF;
            end else if (rx_pid_pw[1:0] == 2'b01) begin
              rx_state <= ST_TOKEN;
            end else if (rx_pid_pw[1:0] == 2'b11) begin
              rx_state <= ST_DATA;
            end
          end
        end

        ST_SOF: begin
          if (rx_tvalid_i && rx_tlast_i) begin
            rx_state <= ST_SOF_CRC;
          end
        end

        ST_TOKEN: begin
          if (rx_tvalid_i && rx_tlast_i) begin
            rx_state <= ST_TOKEN_CRC;
          end
        end

        ST_DATA: begin
          if (rx_tvalid_i && rx_tlast_i) begin
            rx_state <= ST_DATA_CRC;
          end
        end

        ST_SOF_CRC: rx_state <= ST_IDLE;
        ST_TOKEN_CRC: rx_state <= ST_IDLE;
        ST_DATA_CRC: rx_state <= ST_IDLE;
        default: rx_state <= ST_IDLE;
      endcase
    end
  end


// -- Transaction Type Register -- //

  // todo: combine into just one register !?
  always @(posedge clock) begin
    if (rx_tvalid_i && rx_state == ST_IDLE && rx_pid_pw == rx_pid_nw) begin
      trn_type_q <= rx_pid_pw[3:2];
      rx_trn_type_q <= rx_pid_pw[3:2];
      rx_trn_hsk_type_q <= rx_pid_pw[3:2];
      rx_trn_hsk_recv_q <= rx_pid_pw[1:0] == 2'b10 && addr_match_w;
    end else begin
      trn_type_q <= trn_type_q;
      rx_trn_hsk_recv_q <= 1'b0;
      /*
      case (rx_pid_pw[1:0])
        2'b01: begin
          trn_type_q <= rx_pid_pw[3:2];
          rx_trn_type_q <= rx_trn_type_q;
          rx_trn_hsk_recv_q <= 1'b0;
          rx_trn_hsk_type_q <= rx_trn_hsk_type_q;
        end
        2'b10: begin
          trn_type_q <= trn_type_q;
          rx_trn_type_q <= rx_trn_type_q;
          rx_trn_hsk_type_q <= rx_pid_pw[3:2];
          rx_trn_hsk_recv_q <= addr_match_w;
        end
        2'b11: begin
          trn_type_q <= trn_type_q;
          rx_trn_type_q <= rx_pid_pw[3:2];
          rx_trn_hsk_recv_q <= 1'b0;
          rx_trn_hsk_type_q <= rx_trn_hsk_type_q;
        end
        default: begin
          trn_type_q <= trn_type_q;
          rx_trn_type_q <= rx_trn_type_q;
          rx_trn_hsk_recv_q <= 1'b0;
          rx_trn_hsk_type_q <= rx_trn_hsk_type_q;
        end
      endcase
      */
    end
  end


endmodule // decode_packet
