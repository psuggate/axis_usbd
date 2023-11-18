`timescale 1ns / 100ps
//
// Based on project 'https://github.com/ObKo/USBCore'
// License: MIT
//  Copyright (c) 2021 Dmitry Matyunin
//
module usb_packet (
    input wire rst,
    input wire clk,

    input wire axis_rx_tvalid_i,
    output wire axis_rx_tready_o,
    input wire axis_rx_tlast_i,
    input wire [7:0] axis_rx_tdata_i,

    output wire axis_tx_tvalid_o,
    input wire axis_tx_tready_i,
    output wire axis_tx_tlast_o,
    output wire [7:0] axis_tx_tdata_o,

    output wire [1:0] trn_type,
    output wire [6:0] trn_address,
    output wire [3:0] trn_endpoint,
    output wire trn_start,

    /* DATA0/1/2 MDATA */
    output wire rx_trn_valid,
    output wire rx_trn_end,
    output wire [1:0] rx_trn_data_type,
    output wire [7:0] rx_trn_data,
    output wire rx_trn_hsk_received,
    output wire [1:0] rx_trn_hsk_type,

    /* 00 - ACK, 10 - NAK, 11 - STALL, 01 - NYET */
    input wire [1:0] tx_trn_hsk_type,
    input wire tx_trn_send_hsk,
    output wire tx_trn_hsk_sended,
    /* DATA0/1/2 MDATA */
    input wire [1:0] tx_trn_data_type,
    input wire tx_trn_data_start,
    input wire [7:0] tx_trn_data,
    input wire tx_trn_data_valid,
    output wire tx_trn_data_ready,
    input wire tx_trn_data_last,

    output wire start_of_frame,
    output wire crc_error,
    input wire [6:0] device_address
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
	STATE_RX_IDLE      = 7'h01,
	STATE_RX_SOF       = 7'h02,
	STATE_RX_SOFCRC    = 7'h04,
	STATE_RX_TOKEN     = 7'h08,
	STATE_RX_TOKEN_CRC = 7'h10,
	STATE_RX_DATA      = 7'h20,
	STATE_RX_DATA_CRC  = 7'h40;

  localparam [6:0]
	STATE_TX_IDLE      = 7'h01,
	STATE_TX_HSK       = 7'h02,
	STATE_TX_HSK_WAIT  = 7'h04,
	STATE_TX_DATA_PID  = 7'h08,
	STATE_TX_DATA      = 7'h10,
	STATE_TX_DATA_CRC1 = 7'h20,
	STATE_TX_DATA_CRC2 = 7'h40;

  reg [6:0] rx_state;
  reg [6:0] tx_state;

  wire [4:0] rx_crc5;
  wire [3:0] rx_pid;
  reg [10:0] rx_counter;
  reg [10:0] token_data;
  reg [4:0] token_crc5;
  reg [15:0] rx_crc16;
  wire [15:0] rx_data_crc;
  reg [15:0] tx_crc16;
  wire [15:0] tx_crc16_r;
  reg [7:0] rx_buf1;
  reg [7:0] rx_buf2;
  reg tx_zero_packet;
  reg sof_flag;
  reg crc_err_flag;
  reg trn_start_out;
  reg rx_trn_end_out;
  reg rx_trn_hsk_received_out;
  reg [1:0] trn_type_out;
  reg [1:0] rx_trn_data_type_out;
  reg [1:0] rx_trn_hsk_type_out;

  reg rx_vld0, rx_vld1, rx_valid_q, rx_trn_valid_q;
  wire rx_valid_w, rx_trn_valid_w;

  reg [7:0] tx_tdata;
  reg tx_tvalid;
  reg tx_tlast;


  assign rx_crc5 = crc5(token_data);
  assign rx_data_crc = {rx_buf2, rx_buf1};
  assign trn_address = token_data[6:0];
  assign trn_endpoint = token_data[10:7];

  assign start_of_frame = sof_flag;
  assign crc_error = crc_err_flag;
  assign trn_start = trn_start_out;
  assign trn_type = trn_type_out;


  assign tx_trn_data_ready = tx_state == STATE_TX_DATA & axis_tx_tready_i;
  assign tx_trn_hsk_sended = tx_state == STATE_TX_HSK_WAIT;
  assign tx_crc16_r = ~{tx_crc16[0], tx_crc16[1], tx_crc16[2], tx_crc16[3],
                        tx_crc16[4], tx_crc16[5], tx_crc16[6], tx_crc16[7],
                        tx_crc16[8], tx_crc16[9], tx_crc16[10], tx_crc16[11],
                        tx_crc16[12], tx_crc16[13], tx_crc16[14], tx_crc16[15]
                        };
  assign rx_pid = axis_rx_tdata_i[3:0];
  assign axis_rx_tready_o = 1'b1;

  assign axis_tx_tdata_o = tx_tdata;
  assign axis_tx_tvalid_o = tx_tvalid;
  assign axis_tx_tlast_o = tx_tlast;


  // -- Rx Data -- //

  assign rx_trn_valid = rx_trn_valid_q;
  // assign rx_trn_valid = rx_trn_valid_w;
  assign rx_trn_end = rx_trn_end_out;
  assign rx_trn_data_type = rx_trn_data_type_out;
  assign rx_trn_data = rx_buf1;
  assign rx_trn_hsk_received = rx_trn_hsk_received_out;
  assign rx_trn_hsk_type = rx_trn_hsk_type_out;

  assign rx_trn_valid_w = rx_state == STATE_RX_DATA && axis_rx_tvalid_i && rx_valid_q;
  assign rx_valid_w = trn_address == device_address;

  always @(posedge clk) begin
    if (rx_state == STATE_RX_DATA) begin
      rx_trn_valid_q <= axis_rx_tvalid_i && !axis_rx_tlast_i && rx_vld0 && rx_valid_w;
    end else begin
      rx_trn_valid_q <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (rx_state == STATE_RX_IDLE) begin
      {rx_vld1, rx_vld0} <= 2'b00;
      rx_valid_q <= 1'b0;
    end else if (axis_rx_tvalid_i) begin
      {rx_vld1, rx_vld0} <= {rx_vld0, 1'b1};
      rx_valid_q <= rx_vld0 && rx_valid_w;
    end

    if (axis_rx_tvalid_i) begin
      {rx_buf1, rx_buf2} <= {rx_buf2, axis_rx_tdata_i};
    end else begin
      {rx_buf1, rx_buf2} <= {rx_buf2, 8'bx};
    end
  end

  /* Rx Data CRC Calculation */
  always @(posedge clk) begin
    if (rx_state == STATE_RX_IDLE) begin
      rx_crc16 <= 16'hFFFF;
    end else if (rx_state == STATE_RX_DATA && axis_rx_tvalid_i && rx_vld1) begin
      rx_crc16 <= crc16(rx_buf1, rx_crc16);
    end
  end

  /* Tx data CRC Calculation */
  always @(posedge clk) begin
    if (tx_state == STATE_TX_IDLE) begin
      tx_crc16 <= 16'hFFFF;
    end else if (tx_state == STATE_TX_DATA && axis_tx_tready_i && tx_trn_data_valid) begin
      tx_crc16 <= crc16(tx_trn_data, tx_crc16);
    end
  end


  // -- Start-Of-Frame Signal -- //

  always @(posedge clk) begin
    case (rx_state)
      STATE_RX_SOFCRC: sof_flag <= token_crc5 == rx_crc5;
      default: sof_flag <= 1'b0;
    endcase
  end

  always @(posedge clk) begin
    case (rx_state)
      STATE_RX_SOFCRC, STATE_RX_TOKEN_CRC: crc_err_flag <= token_crc5 != rx_crc5;
      STATE_RX_DATA_CRC: crc_err_flag <= rx_data_crc != rx_crc16;
      default: crc_err_flag <= 1'b0;
    endcase
  end

  // Strobes that indicate the start and end of a (received) packet.
  always @(posedge clk) begin
    case (rx_state)
      STATE_RX_TOKEN_CRC: begin
        trn_start_out  <= device_address == token_data[6:0] && token_crc5 == rx_crc5;
        rx_trn_end_out <= 1'b0;
      end
      STATE_RX_DATA_CRC: begin
        trn_start_out  <= 1'b0;
        rx_trn_end_out <= rx_valid_w;
      end
      default: begin
        trn_start_out  <= 1'b0;
        rx_trn_end_out <= 1'b0;
      end
    endcase
  end

  always @(posedge clk) begin
    case (rx_state)
      STATE_RX_TOKEN, STATE_RX_SOF: begin
        if (axis_rx_tvalid_i) begin
          token_data[7:0] <= rx_vld0 ? token_data[7:0] : axis_rx_tdata_i;
          token_data[10:8] <= rx_vld0 && !rx_vld1 ? axis_rx_tdata_i[2:0] : token_data[10:8];
          token_crc5 <= rx_vld0 && !rx_vld1 ? axis_rx_tdata_i[7:3] : token_crc5;
        end
      end
      default: begin
        token_data <= token_data;
        token_crc5 <= token_crc5;
      end
    endcase
  end

  always @(posedge clk) begin
    if (rx_state == STATE_RX_IDLE && axis_rx_tvalid_i &&
        rx_pid == ~axis_rx_tdata_i[7:4] && rx_pid[1:0] == 2'b10) begin
      rx_trn_hsk_type_out <= rx_pid[3:2];
      rx_trn_hsk_received_out <= rx_valid_w;
    end else begin
      rx_trn_hsk_type_out <= rx_trn_hsk_type_out;
      rx_trn_hsk_received_out <= 1'b0;
    end
  end


  // -- Rx FSM -- //

  always @(posedge clk) begin
    if (rst) begin
      rx_state <= STATE_RX_IDLE;

      trn_type_out <= 2'bx;
      rx_trn_data_type_out <= 2'bx;
    end else begin
      case (rx_state)
        STATE_RX_IDLE: begin
          if (axis_rx_tvalid_i && rx_pid == ~axis_rx_tdata_i[7:4]) begin
            if (rx_pid == 4'b0101) begin
              rx_state <= STATE_RX_SOF;
            end else if (rx_pid[1:0] == 2'b01) begin
              rx_state <= STATE_RX_TOKEN;
              trn_type_out <= rx_pid[3:2];
            end else if (rx_pid[1:0] == 2'b11) begin
              rx_state <= STATE_RX_DATA;
              rx_trn_data_type_out <= rx_pid[3:2];
            end
          end
        end

        STATE_RX_SOF: begin
          if (axis_rx_tvalid_i && axis_rx_tlast_i) begin
            rx_state <= STATE_RX_SOFCRC;
          end
        end

        STATE_RX_SOFCRC: begin
          rx_state <= STATE_RX_IDLE;
        end

        STATE_RX_TOKEN: begin
          if (axis_rx_tvalid_i && axis_rx_tlast_i) begin
            rx_state <= STATE_RX_TOKEN_CRC;
          end
        end

        STATE_RX_TOKEN_CRC: begin
          rx_state <= STATE_RX_IDLE;
        end

        STATE_RX_DATA: begin
          if (axis_rx_tvalid_i && axis_rx_tlast_i) begin
            rx_state <= STATE_RX_DATA_CRC;
          end
        end

        STATE_RX_DATA_CRC: begin
          rx_state <= STATE_RX_IDLE;
        end

        default: begin
          rx_state <= STATE_RX_IDLE;

          trn_type_out <= 2'bx;
          rx_trn_data_type_out <= 2'bx;
        end
      endcase
    end
  end


  // -- Tx FSM -- //

  always @(posedge clk) begin
    if (rst) begin
      tx_state <= STATE_TX_IDLE;
      tx_zero_packet <= 1'bx;
    end else begin
      case (tx_state)
        STATE_TX_IDLE: begin
          if (tx_trn_send_hsk) begin
            tx_state <= STATE_TX_HSK;
            tx_zero_packet <= 1'bx;
          end else if (tx_trn_data_start) begin
            tx_state <= STATE_TX_DATA_PID;
            tx_zero_packet <= tx_trn_data_last && !tx_trn_data_valid;
          end else begin
            tx_state <= tx_state;
            tx_zero_packet <= 1'bx;
          end
        end

        STATE_TX_HSK: begin
          if (axis_tx_tready_i) begin
            tx_state <= STATE_TX_HSK_WAIT;
          end
          tx_zero_packet <= 1'bx;
        end

        STATE_TX_HSK_WAIT: begin
          if (!tx_trn_send_hsk) begin
            tx_state <= STATE_TX_IDLE;
          end
          tx_zero_packet <= 1'bx;
        end

        STATE_TX_DATA_PID: begin
          if (axis_tx_tready_i) begin
            tx_state <= tx_zero_packet ? STATE_TX_DATA_CRC1 : STATE_TX_DATA;
            tx_zero_packet <= 1'bx;
          end else begin
            tx_state <= tx_state;
            tx_zero_packet <= tx_zero_packet;
          end
        end

        STATE_TX_DATA: begin
          if (axis_tx_tready_i && tx_trn_data_valid) begin
            if (tx_trn_data_last) begin
              tx_state <= STATE_TX_DATA_CRC1;
            end
          end else if (!tx_trn_data_valid) begin
            tx_state <= STATE_TX_DATA_CRC2;
          end
          tx_zero_packet <= 1'bx;
        end

        STATE_TX_DATA_CRC1: begin
          if (axis_tx_tready_i) begin
            tx_state <= STATE_TX_DATA_CRC2;
          end
          tx_zero_packet <= 1'bx;
        end

        STATE_TX_DATA_CRC2: begin
          if (axis_tx_tready_i) begin
            tx_state <= STATE_TX_IDLE;
          end
          tx_zero_packet <= 1'bx;
        end

        default: begin
          tx_state <= STATE_TX_IDLE;
          tx_zero_packet <= 1'bx;
        end
      endcase
    end
  end


  // todo: clean-up this disaster site !?
  always @(*) begin
    if (tx_state == STATE_TX_DATA_PID) begin
      tx_tdata = {(~{tx_trn_data_type, 2'b11}), {tx_trn_data_type, 2'b11}};
    end else if (tx_state == STATE_TX_HSK) begin
      tx_tdata = {(~{tx_trn_hsk_type, 2'b10}), tx_trn_hsk_type, 2'b10};
    end else if (tx_state == STATE_TX_DATA_CRC1 ||
                 tx_state == STATE_TX_DATA && !tx_trn_data_valid) begin
      tx_tdata = tx_crc16_r[7:0];
    end else if (tx_state == STATE_TX_DATA_CRC2) begin
      tx_tdata = tx_crc16_r[15:8];
    end else begin
      tx_tdata = tx_trn_data;
    end

    if (tx_state == STATE_TX_DATA_PID || tx_state == STATE_TX_HSK ||
        tx_state == STATE_TX_DATA_CRC1 || tx_state == STATE_TX_DATA_CRC2 ||
        tx_state == STATE_TX_DATA) begin
      tx_tvalid = 1'b1;
    end else begin
      tx_tvalid = 1'b0;
    end

    if (tx_state == STATE_TX_HSK || tx_state == STATE_TX_DATA_CRC2) begin
      tx_tlast = 1'b1;
    end else begin
      tx_tlast = 1'b0;
    end
  end


endmodule // usb_packet
