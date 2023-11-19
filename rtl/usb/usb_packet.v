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

    output wire trn_start_o,
    output wire [1:0] trn_type_o,
    output wire [6:0] trn_address_o,
    output wire [3:0] trn_endpoint_o,
    input wire [6:0] usb_address_i,

    output wire rx_trn_valid_o,
    output wire rx_trn_end_o,
    output wire [1:0] rx_trn_type_o, /* DATA0/1/2 MDATA */
    output wire [7:0] rx_trn_data_o,
    output wire rx_trn_hsk_recv,
    output wire [1:0] rx_trn_hsk_type, /* 00 - ACK, 10 - NAK, 11 - STALL, 01 - NYET */

    input wire [1:0] tx_trn_hsk_type, /* 00 - ACK, 10 - NAK, 11 - STALL, 01 - NYET */
    input wire tx_trn_send_hsk,
    output wire tx_trn_hsk_sent,
    input wire [1:0] tx_trn_data_type, /* DATA0/1/2 MDATA */
    input wire tx_trn_data_start,
    input wire [7:0] tx_trn_data,
    input wire tx_trn_data_valid,
    output wire tx_trn_data_ready,
    input wire tx_trn_data_last,

    output wire start_of_frame,
    output wire crc_error
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
	RX_IDLE      = 7'h01,
	RX_SOF       = 7'h02,
	RX_SOFCRC    = 7'h04,
	RX_TOKEN     = 7'h08,
	RX_TOKEN_CRC = 7'h10,
	RX_DATA      = 7'h20,
	RX_DATA_CRC  = 7'h40;

  localparam [6:0]
	TX_IDLE      = 7'h01,
	TX_HSK       = 7'h02,
	TX_HSK_WAIT  = 7'h04,
	TX_DPID  = 7'h08,
	TX_DATA      = 7'h10,
	TX_CRC1 = 7'h20,
	TX_CRC2 = 7'h40;

  reg [6:0] rx_state, tx_state;

  wire [4:0] rx_crc5;
  wire [3:0] rx_pid;
  reg [10:0] token_data;
  reg [4:0] token_crc5;
  reg [15:0] rx_crc16, tx_crc16;
  wire [15:0] rx_data_crc, tx_crc16_r;
  reg [7:0] rx_buf1, rx_buf2;
  reg tx_zero_packet;

  reg sof_flag;
  reg crc_err_flag;
  reg trn_start_q, rx_trn_end_q;
  reg rx_trn_hsk_recv_q;
  reg [1:0] trn_type_q;
  reg [1:0] rx_trn_type_q;
  reg [1:0] rx_trn_hsk_type_q;

  reg rx_vld0, rx_vld1, rx_valid_q, rx_trn_valid_q;
  wire addr_match_w;

  reg [7:0] tx_tdata;
  reg tx_tvalid;
  reg tx_tlast;


  // -- Input/Output Assignments -- //

  assign axis_rx_tready_o = 1'b1;

  // Rx data-path (from USB host) to either USB config OR bulk EP cores
  assign rx_trn_valid_o  = rx_trn_valid_q;
  assign rx_trn_end_o    = rx_trn_end_q;
  assign rx_trn_type_o   = rx_trn_type_q;
  assign rx_trn_data_o   = rx_buf1;
  assign rx_trn_hsk_recv = rx_trn_hsk_recv_q;
  assign rx_trn_hsk_type = rx_trn_hsk_type_q;

  assign trn_start_o     = trn_start_q;
  assign trn_type_o      = trn_type_q;
  assign trn_address_o   = token_data[6:0];
  assign trn_endpoint_o  = token_data[10:7];

  assign start_of_frame  = sof_flag;
  assign crc_error       = crc_err_flag;


  // -- Internal Signals -- //

  assign rx_crc5 = crc5(token_data);
  assign rx_data_crc = {rx_buf2, rx_buf1};

  assign tx_trn_hsk_sent = tx_state == TX_HSK_WAIT;
  assign tx_crc16_r = ~{tx_crc16[0], tx_crc16[1], tx_crc16[2], tx_crc16[3],
                        tx_crc16[4], tx_crc16[5], tx_crc16[6], tx_crc16[7],
                        tx_crc16[8], tx_crc16[9], tx_crc16[10], tx_crc16[11],
                        tx_crc16[12], tx_crc16[13], tx_crc16[14], tx_crc16[15]
                        };
  assign rx_pid = axis_rx_tdata_i[3:0];


  // -- Rx Data -- //

  assign addr_match_w = trn_address_o == usb_address_i;

  always @(posedge clk) begin
    if (rx_state == RX_DATA) begin
      rx_trn_valid_q <= axis_rx_tvalid_i && !axis_rx_tlast_i && rx_vld0 && addr_match_w;
    end else begin
      rx_trn_valid_q <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (rx_state == RX_IDLE) begin
      {rx_vld1, rx_vld0} <= 2'b00;
      rx_valid_q <= 1'b0;
    end else if (axis_rx_tvalid_i) begin
      {rx_vld1, rx_vld0} <= {rx_vld0, 1'b1};
      rx_valid_q <= rx_vld0 && addr_match_w;
    end

    if (axis_rx_tvalid_i) begin
      {rx_buf1, rx_buf2} <= {rx_buf2, axis_rx_tdata_i};
    end else begin
      {rx_buf1, rx_buf2} <= {rx_buf2, 8'bx};
    end
  end

  /* Rx Data CRC Calculation */
  always @(posedge clk) begin
    if (rx_state == RX_IDLE) begin
      rx_crc16 <= 16'hFFFF;
    end else if (rx_state == RX_DATA && axis_rx_tvalid_i && rx_vld1) begin
      rx_crc16 <= crc16(rx_buf1, rx_crc16);
    end
  end

  /* Tx data CRC Calculation */
  always @(posedge clk) begin
    if (tx_state == TX_IDLE) begin
      tx_crc16 <= 16'hFFFF;
    end else if (tx_state == TX_DATA && axis_tx_tready_i && tx_trn_data_valid) begin
      tx_crc16 <= crc16(tx_trn_data, tx_crc16);
    end
  end


  // -- Start-Of-Frame Signal -- //

  always @(posedge clk) begin
    case (rx_state)
      RX_SOFCRC: sof_flag <= token_crc5 == rx_crc5;
      default: sof_flag <= 1'b0;
    endcase
  end

  always @(posedge clk) begin
    case (rx_state)
      RX_SOFCRC, RX_TOKEN_CRC: crc_err_flag <= token_crc5 != rx_crc5;
      RX_DATA_CRC: crc_err_flag <= rx_data_crc != rx_crc16;
      default: crc_err_flag <= 1'b0;
    endcase
  end

  // Strobes that indicate the start and end of a (received) packet.
  always @(posedge clk) begin
    case (rx_state)
      RX_TOKEN_CRC: begin
        trn_start_q  <= usb_address_i == token_data[6:0] && token_crc5 == rx_crc5;
        rx_trn_end_q <= 1'b0;
      end
      RX_DATA_CRC: begin
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
  always @(posedge clk) begin
    case (rx_state)
      RX_TOKEN, RX_SOF: begin
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
    if (rx_state == RX_IDLE && axis_rx_tvalid_i &&
        rx_pid == ~axis_rx_tdata_i[7:4] && rx_pid[1:0] == 2'b10) begin
      rx_trn_hsk_type_q <= rx_pid[3:2];
      rx_trn_hsk_recv_q <= addr_match_w;
    end else begin
      rx_trn_hsk_type_q <= rx_trn_hsk_type_q;
      rx_trn_hsk_recv_q <= 1'b0;
    end
  end


  // -- Rx FSM -- //

  always @(posedge clk) begin
    if (rst) begin
      rx_state <= RX_IDLE;

      trn_type_q <= 2'bx;
      rx_trn_type_q <= 2'bx;
    end else begin
      case (rx_state)
        RX_IDLE: begin
          if (axis_rx_tvalid_i && rx_pid == ~axis_rx_tdata_i[7:4]) begin
            if (rx_pid == 4'b0101) begin
              rx_state <= RX_SOF;
            end else if (rx_pid[1:0] == 2'b01) begin
              rx_state <= RX_TOKEN;
              trn_type_q <= rx_pid[3:2];
            end else if (rx_pid[1:0] == 2'b11) begin
              rx_state <= RX_DATA;
              rx_trn_type_q <= rx_pid[3:2];
            end
          end
        end

        RX_SOF: begin
          if (axis_rx_tvalid_i && axis_rx_tlast_i) begin
            rx_state <= RX_SOFCRC;
          end
        end

        RX_SOFCRC: begin
          rx_state <= RX_IDLE;
        end

        RX_TOKEN: begin
          if (axis_rx_tvalid_i && axis_rx_tlast_i) begin
            rx_state <= RX_TOKEN_CRC;
          end
        end

        RX_TOKEN_CRC: begin
          rx_state <= RX_IDLE;
        end

        RX_DATA: begin
          if (axis_rx_tvalid_i && axis_rx_tlast_i) begin
            rx_state <= RX_DATA_CRC;
          end
        end

        RX_DATA_CRC: begin
          rx_state <= RX_IDLE;
        end

        default: begin
          rx_state <= RX_IDLE;

          trn_type_q <= 2'bx;
          rx_trn_type_q <= 2'bx;
        end
      endcase
    end
  end


  // -- Tx FSM -- //

  wire tx_ready;

  always @(posedge clk) begin
    if (rst) begin
      tx_state <= TX_IDLE;
      tx_zero_packet <= 1'bx;
    end else begin
      case (tx_state)
        TX_IDLE: begin
          if (tx_trn_send_hsk) begin
            tx_state <= TX_HSK;
            tx_zero_packet <= 1'bx;
          end else if (tx_trn_data_start) begin
            tx_state <= TX_DPID;
            tx_zero_packet <= tx_trn_data_last && !tx_trn_data_valid;
          end else begin
            tx_state <= tx_state;
            tx_zero_packet <= 1'bx;
          end
        end

        TX_HSK: begin
          if (tx_ready) begin
            tx_state <= TX_HSK_WAIT;
          end
          tx_zero_packet <= 1'bx;
        end

        TX_HSK_WAIT: begin
          if (!tx_trn_send_hsk) begin
            tx_state <= TX_IDLE;
          end
          tx_zero_packet <= 1'bx;
        end

        TX_DPID: begin
          if (tx_ready) begin
            tx_state <= tx_zero_packet ? TX_CRC1 : TX_DATA;
            tx_zero_packet <= 1'bx;
          end else begin
            tx_state <= tx_state;
            tx_zero_packet <= tx_zero_packet;
          end
        end

        TX_DATA: begin
          if (tx_ready && tx_trn_data_valid) begin
            if (tx_trn_data_last) begin
              tx_state <= TX_CRC1;
            end
          end else if (!tx_trn_data_valid) begin
            tx_state <= TX_CRC2;
            // tx_state <= TX_CRC1;
          end
          tx_zero_packet <= 1'bx;
        end

        TX_CRC1: begin
          if (tx_ready) begin
            tx_state <= TX_CRC2;
          end
          tx_zero_packet <= 1'bx;
        end

        TX_CRC2: begin
          if (tx_ready) begin
            tx_state <= TX_IDLE;
          end
          tx_zero_packet <= 1'bx;
        end

        default: begin
          tx_state <= TX_IDLE;
          tx_zero_packet <= 1'bx;
        end
      endcase
    end
  end


// -- Tx Data-path -- //

// `define __upstream_flow_control_works
`ifdef __upstream_flow_control_works
/**
 * TODO:
 *  - I think that there are upstream data-path problems ??
 *  - Specifically, I don't think the upstream flow-control works correctly !?
 */
reg tvld, tlst, xrdy;
reg [7:0] tdat;

  // assign tx_trn_data_ready = xrdy;
  assign tx_ready = !tvld || tvld && axis_tx_tready_i;
  assign tx_trn_data_ready = !tvld || tvld && axis_tx_tready_i;
  // assign tx_ready = axis_tx_tready_i;
  // assign tx_ready = xrdy;

  assign axis_tx_tvalid_o = tvld;
  assign axis_tx_tlast_o  = tlst;
  assign axis_tx_tdata_o  = tdat;

reg tx_cycle_q;

always @(posedge clk) begin
  case (tx_state)
      TX_IDLE: tx_cycle_q <= tx_trn_data_start & ~tx_trn_send_hsk;
      default: begin
        if (tx_cycle_q && tvld && tlst && axis_tx_tready_i) begin
          tx_cycle_q <= 1'b0;
        end
      end
  endcase
end

always @(posedge clk) begin
  if (tx_cycle_q) begin
    xrdy <= !tvld || tvld && axis_tx_tready_i;
  end else begin
    xrdy <= 1'b0;
  end
end

  always @(posedge clk) begin
    case (tx_state)
      TX_IDLE: begin
        if (tx_trn_send_hsk) begin
          tvld <= 1'b1;
          tlst <= 1'b1;
          tdat <= {(~{tx_trn_hsk_type, 2'b10}), tx_trn_hsk_type, 2'b10};
        end else if (tx_trn_data_start) begin
          tvld <= 1'b1;
          tlst <= 1'b0;
          tdat <= {(~{tx_trn_data_type, 2'b11}), {tx_trn_data_type, 2'b11}};
        end else begin
          tvld <= 1'b0;
          tlst <= 1'b0;
          tdat <= 'bx;
        end
      end

      TX_HSK: begin
        if (axis_tx_tready_i) begin
          tvld <= 1'b0;
          tlst <= 1'b0;
          tdat <= 'bx;
        end
      end

      TX_DPID: begin
        tvld <= 1'b1;
        tlst <= 1'b0;
        if (axis_tx_tready_i) begin
          tdat <= tx_zero_packet || !tx_trn_data_valid ? tx_crc16_r[7:0] : tx_trn_data;
        end
      end

      TX_DATA: begin
        tvld <= 1'b1;
        tlst <= 1'b0;
        if (axis_tx_tready_i) begin
          tdat <= tx_trn_data_valid && !tx_trn_data_last ? tx_trn_data : tx_crc16_r[7:0];
        end else begin
          tdat <= tdat;
        end
      end

      TX_CRC1: begin
        if (axis_tx_tready_i) begin
          tvld <= 1'b1;
          tlst <= 1'b1;
          tdat <= tx_crc16_r[15:8];
        end
      end

      TX_CRC2: begin
        if (axis_tx_tready_i) begin
          tvld <= 1'b0;
          tlst <= 1'b0;
          tdat <= 'bx;
        end
      end

      default: begin
        tvld <= 1'b0;
        tlst <= 1'b0;
        tdat <= 'bx;
      end
    endcase
  end

`else

  assign tx_trn_data_ready = tx_state == TX_DATA & axis_tx_tready_i;
  assign tx_ready = axis_tx_tready_i;

  assign axis_tx_tdata_o = tx_tdata;
  assign axis_tx_tvalid_o = tx_tvalid;
  assign axis_tx_tlast_o = tx_tlast;

  // todo: clean-up this disaster site !?
  always @(*) begin
    if (tx_state == TX_DPID) begin
      tx_tdata = {(~{tx_trn_data_type, 2'b11}), {tx_trn_data_type, 2'b11}};
    end else if (tx_state == TX_HSK) begin
      tx_tdata = {(~{tx_trn_hsk_type, 2'b10}), tx_trn_hsk_type, 2'b10};
    end else if (tx_state == TX_CRC1 ||
                 tx_state == TX_DATA && !tx_trn_data_valid) begin
      tx_tdata = tx_crc16_r[7:0];
    end else if (tx_state == TX_CRC2) begin
      tx_tdata = tx_crc16_r[15:8];
    end else begin
      tx_tdata = tx_trn_data;
    end

    if (tx_state == TX_DPID || tx_state == TX_HSK ||
        tx_state == TX_CRC1 || tx_state == TX_CRC2 ||
        tx_state == TX_DATA) begin
      tx_tvalid = 1'b1;
    end else begin
      tx_tvalid = 1'b0;
    end

    if (tx_state == TX_HSK || tx_state == TX_CRC2) begin
      tx_tlast = 1'b1;
    end else begin
      tx_tlast = 1'b0;
    end
  end

`endif


endmodule // usb_packet
