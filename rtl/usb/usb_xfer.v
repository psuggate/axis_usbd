`timescale 1ns / 100ps
//
// Based on project 'https://github.com/ObKo/USBCore'
// License: MIT
//  Copyright (c) 2021 Dmitry Matyunin
//
module usb_xfer #(
    parameter integer HIGH_SPEED = 1
) (
    input wire clk,
    input wire rst,

    /* Transaction */
    input wire [1:0] trn_type,
    input wire [6:0] trn_address,
    input wire [3:0] trn_endpoint,
    input wire trn_start,

    /* DATA0/1/2 MDATA */
    input wire [1:0] rx_trn_data_type,
    input wire rx_trn_end,
    input wire [7:0] rx_trn_data,
    input wire rx_trn_valid,
    input wire [1:0] rx_trn_hsk_type,
    input wire rx_trn_hsk_recv,
    /* 00 - ACK, 10 - NAK, 11 - STALL, 01 - NYET */
    output wire [1:0] tx_trn_hsk_type,
    output wire tx_trn_send_hsk,
    input wire tx_trn_hsk_sent,
    output wire [1:0] tx_trn_data_type,
    output wire tx_trn_data_start,
    output wire [7:0] tx_trn_data,
    output wire tx_trn_data_valid,
    input wire tx_trn_data_ready,
    output wire tx_trn_data_last,
    input wire crc_error,

    /* Ctl */
    output wire ctl_xfer_o,  /* '1' when processing control transfer */
    input wire ctl_xfer_done_i,  /* '1' when control request completed */
    output wire [3:0] ctl_xfer_endpoint_o,
    output wire [7:0] ctl_xfer_type_o,
    output wire [7:0] ctl_xfer_request_o,
    output wire [15:0] ctl_xfer_value_o,
    output wire [15:0] ctl_xfer_index_o,
    output wire [15:0] ctl_xfer_length_o,
    input wire ctl_xfer_accept_i,

    output wire [7:0] ctl_xfer_data_out,
    output wire ctl_xfer_data_out_valid,

    input wire ctl_tvalid_i,
    output wire ctl_tready_o,
    input wire ctl_tlast_i,
    input wire [7:0] ctl_tdata_i,

    /* Bulk EP IN/OUT */
    output wire [3:0] blk_xfer_endpoint_o,
    output wire blk_in_xfer_o,
    output wire blk_out_xfer_o,

    /* Has complete packet */
    input wire bid_has_data_i,
    input wire bid_tvalid_i,
    output wire bid_tready_o,
    input wire bid_tlast_i,
    input wire [7:0] bid_tdata_i,

    /* Can accept full packet */
    input wire blk_xfer_out_ready_read,
    output wire [7:0] blk_xfer_out_data,
    output wire blk_xfer_out_data_valid
);

  localparam [4:0]
	STATE_IDLE = 0,
	STATE_CONTROL_SETUP = 1,
	STATE_CONTROL_SETUP_ACK = 2,
	STATE_CONTROL_WAIT_DATAIN = 3,
	STATE_CONTROL_DATAIN = 4,
	STATE_CONTROL_DATAIN_Z = 5,
	STATE_CONTROL_DATAIN_ACK = 6,
	STATE_CONTROL_WAIT_DATAOUT = 7,
	STATE_CONTROL_DATAOUT = 8,
	STATE_CONTROL_DATAOUT_MYACK = 9,
	STATE_CONTROL_STATUS_OUT = 10,
	STATE_CONTROL_STATUS_OUT_D = 11,
	STATE_CONTROL_STATUS_OUT_ACK = 12,
	STATE_CONTROL_STATUS_IN = 13,
	STATE_CONTROL_STATUS_IN_MYACK = 14,
	STATE_CONTROL_STATUS_IN_D = 15,
	STATE_CONTROL_STATUS_IN_ACK = 16,
	STATE_BULK_IN = 17,
	STATE_BULK_IN_MYACK = 18,
	STATE_BULK_IN_ACK = 19,
	STATE_BULK_OUT = 20,
	STATE_BULK_OUT_ACK = 21;

  localparam [1:0] HSK_ACK = 2'b00, HSK_NAK = 2'b10, HSK_STALL = 2'b11, HSK_NYET = 2'b01;

  reg [4:0] state;
  reg [10:0] rx_counter;
  reg [15:0] tx_counter;
  reg [15:0] ctl_xfer_length_int;
  reg [7:0] ctl_xfer_type_int;
  reg [15:0] data_types;
  reg [3:0] current_endpoint;
  reg [1:0] ctl_status;
  reg ctl_xfer_eop;
  reg tx_counter_over;
  reg ctl_xfer_int;
  reg blk_in_xfer_int;
  reg blk_out_xfer_int;
  reg tx_trn_data_start_int;
  reg [7:0] ctl_xfer_request_int;
  reg [15:0] ctl_xfer_value_int;
  reg [15:0] ctl_xfer_index_int;
  reg tx_trn_send_hsk_int;
  reg tx_trn_data_valid_int;
  reg tx_trn_data_last_int;


  // -- Input/Output Assignments -- //

  assign ctl_xfer_o = ctl_xfer_int;
  assign ctl_xfer_request_o = ctl_xfer_request_int;
  assign ctl_xfer_value_o = ctl_xfer_value_int;
  assign ctl_xfer_index_o = ctl_xfer_index_int;
  assign ctl_xfer_endpoint_o = current_endpoint;
  assign ctl_xfer_length_o = ctl_xfer_length_int;
  assign ctl_xfer_type_o = ctl_xfer_type_int;

  assign blk_xfer_endpoint_o = current_endpoint;
  assign blk_in_xfer_o = blk_in_xfer_int;
  assign blk_out_xfer_o = blk_out_xfer_int;

  assign ctl_tready_o = state == STATE_CONTROL_DATAIN && tx_trn_data_ready;

  assign blk_xfer_out_data = rx_trn_data;
  assign blk_xfer_out_data_valid = state == STATE_BULK_OUT && rx_trn_valid;

  assign ctl_xfer_data_out = rx_trn_data;
  assign ctl_xfer_data_out_valid = rx_trn_valid;

  // Signals for bulk EP IN transfers
  assign bid_tready_o = state == STATE_BULK_IN && tx_trn_data_ready;

  assign tx_trn_send_hsk = tx_trn_send_hsk_int;
  assign tx_trn_hsk_type = state == STATE_CONTROL_SETUP_ACK ? 2'b00 : ctl_status;
  assign tx_trn_data_start = tx_trn_data_start_int;
  assign tx_trn_data_type = {data_types[current_endpoint], 1'b0};
  assign tx_trn_data_valid = tx_trn_data_valid_int;
  assign tx_trn_data_last = tx_trn_data_last_int;
  assign tx_trn_data = state == STATE_CONTROL_DATAIN ? ctl_tdata_i : bid_tdata_i;


  /* Rx Counter */
  always @(posedge clk) begin
    if (state == STATE_IDLE || state == STATE_CONTROL_SETUP_ACK) begin
      rx_counter <= 0;
    end else if (rx_trn_valid) begin
      rx_counter <= rx_counter + 1;
    end
  end

  /* Toggling */
  always @(posedge clk) begin
    if (rst) begin
      data_types <= 16'b1;
    end else begin
      if (state == STATE_CONTROL_SETUP_ACK) begin
        data_types[current_endpoint] <= 1'b1;
      end else if (state == STATE_CONTROL_DATAIN_ACK) begin
        if (rx_trn_hsk_recv && rx_trn_hsk_type == HSK_ACK) begin
          data_types[current_endpoint] <= ~data_types[current_endpoint];
        end
      end else if (state == STATE_CONTROL_STATUS_IN_ACK) begin
        if (rx_trn_hsk_recv && rx_trn_hsk_type == HSK_ACK) begin
          data_types[current_endpoint] <= ~data_types[current_endpoint];
        end
      end else if (state == STATE_BULK_IN_ACK) begin
        if (rx_trn_hsk_recv && rx_trn_hsk_type == HSK_ACK) begin
          data_types[current_endpoint] <= ~data_types[current_endpoint];
        end
      end
    end
  end

  /* FSM */
  always @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      ctl_xfer_int <= 1'b0;
    end else begin
      case (state)
        STATE_IDLE: begin
          ctl_xfer_int <= 1'b0;
          blk_in_xfer_int <= 1'b0;
          blk_out_xfer_int <= 1'b0;
          if (trn_start) begin
            if (trn_type == 2'b11) begin
              state <= STATE_CONTROL_SETUP;
              current_endpoint <= trn_endpoint;
            end else if (trn_type == 2'b10) begin
              current_endpoint <= trn_endpoint;
              if (bid_has_data_i) begin
                blk_in_xfer_int <= 1'b1;
                tx_trn_data_start_int <= 1'b1;
                tx_counter <= 0;
                state <= STATE_BULK_IN;
              end else begin
                ctl_status <= HSK_NAK;
                state <= STATE_BULK_IN_MYACK;
              end
            end else if (trn_type == 2'b00) begin
              blk_out_xfer_int <= 1'b1;
              current_endpoint <= trn_endpoint;
              if (blk_xfer_out_ready_read) begin
                ctl_status <= HSK_ACK;
              end else begin
                ctl_status <= HSK_NAK;
              end
              state <= STATE_BULK_OUT;
            end
          end
        end

        STATE_CONTROL_SETUP: begin
          if (rx_trn_valid) begin
            if (rx_counter == 0) begin
              ctl_xfer_type_int <= rx_trn_data;
            end else if (rx_counter == 1) begin
              ctl_xfer_request_int <= rx_trn_data;
            end else if (rx_counter == 2) begin
              ctl_xfer_value_int[7:0] <= rx_trn_data;
            end else if (rx_counter == 3) begin
              ctl_xfer_value_int[15:8] <= rx_trn_data;
            end else if (rx_counter == 4) begin
              ctl_xfer_index_int[7:0] <= rx_trn_data;
            end else if (rx_counter == 5) begin
              ctl_xfer_index_int[15:8] <= rx_trn_data;
            end else if (rx_counter == 6) begin
              ctl_xfer_length_int[7:0] <= rx_trn_data;
            end else if (rx_counter == 7) begin
              ctl_xfer_length_int[15:8] <= rx_trn_data;
              state <= STATE_CONTROL_SETUP_ACK;
              ctl_xfer_int <= 1'b1;
            end
          end
        end

        STATE_CONTROL_SETUP_ACK: begin
          if (tx_trn_hsk_sent) begin
            if (ctl_xfer_length_int == 0) begin
              if (ctl_xfer_type_int[7]) begin
                state <= STATE_CONTROL_STATUS_OUT;
              end else begin
                state <= STATE_CONTROL_STATUS_IN;
              end
            end else if (ctl_xfer_type_int[7]) begin
              state <= STATE_CONTROL_WAIT_DATAIN;
              tx_counter <= 0;
            end else if (!ctl_xfer_type_int[7]) begin
              state <= STATE_CONTROL_WAIT_DATAOUT;
            end
          end
        end

        STATE_CONTROL_WAIT_DATAIN: begin
          if (trn_start && trn_type == 2'b10) begin
            if (ctl_xfer_accept_i) begin
              state <= STATE_CONTROL_DATAIN;
            end else begin
              state <= STATE_CONTROL_DATAIN_Z;
            end
            tx_trn_data_start_int <= 1'b1;
          end
        end

        STATE_CONTROL_WAIT_DATAOUT: begin
          if (trn_start && trn_type == 2'b00) begin
            if (ctl_xfer_accept_i) begin
              ctl_status <= HSK_ACK;
            end else begin
              ctl_status <= HSK_NAK;
            end
            state <= STATE_CONTROL_DATAOUT;
          end
        end

        STATE_CONTROL_DATAOUT: begin
          if (rx_trn_end || rx_trn_valid &&
              (rx_counter[5:0] == 63 || rx_counter == ctl_xfer_length_int - 1)
              ) begin
            state <= STATE_CONTROL_DATAOUT_MYACK;
          end
        end

        STATE_CONTROL_DATAOUT_MYACK: begin
          if (tx_trn_hsk_sent) begin
            if (rx_counter == ctl_xfer_length_int) begin
              state <= STATE_CONTROL_STATUS_IN;
            end else begin
              state <= STATE_CONTROL_WAIT_DATAOUT;
            end
          end
        end

        STATE_CONTROL_DATAIN: begin
          if (ctl_tvalid_i && tx_trn_data_ready) begin
            if (tx_counter[5:0] == 63 || tx_counter == ctl_xfer_length_int - 1 || ctl_tlast_i) begin
              tx_trn_data_start_int <= 1'b0;
              state <= STATE_CONTROL_DATAIN_ACK;
              if (ctl_tlast_i) begin
                ctl_xfer_eop <= 1'b1;
              end
            end
            tx_counter <= tx_counter + 1;
          end
        end

        STATE_CONTROL_DATAIN_Z: begin
          tx_trn_data_start_int <= 1'b0;
          ctl_xfer_eop <= 1'b1;
          state <= STATE_CONTROL_DATAIN_ACK;
        end

        STATE_CONTROL_DATAIN_ACK: begin
          if (rx_trn_hsk_recv) begin
            if (rx_trn_hsk_type == 2'b00) begin
              if (tx_counter == ctl_xfer_length_int || ctl_xfer_eop) begin
                ctl_xfer_eop <= 1'b0;
                state <= STATE_CONTROL_STATUS_OUT;
              end else begin
                state <= STATE_CONTROL_WAIT_DATAIN;
              end
            end else begin
              state <= STATE_IDLE;
            end
          end
        end

        STATE_CONTROL_STATUS_OUT: begin
          if (trn_start && trn_type == 2'b00) begin
            state <= STATE_CONTROL_STATUS_OUT_D;
          end
        end

        STATE_CONTROL_STATUS_OUT_D: begin
          if (rx_trn_end) begin
            state <= STATE_CONTROL_STATUS_OUT_ACK;
            if (ctl_xfer_done_i) begin
              ctl_status <= HSK_ACK;
            end else begin
              ctl_status <= HSK_NAK;
            end
          end
        end

        STATE_CONTROL_STATUS_OUT_ACK: begin
          if (tx_trn_hsk_sent) begin
            if (ctl_status == HSK_NAK) begin
              state <= STATE_CONTROL_STATUS_OUT;
            end else begin
              state <= STATE_IDLE;
            end
          end
        end

        STATE_CONTROL_STATUS_IN: begin
          if (trn_start && trn_type == 2'b10) begin
            if (ctl_xfer_done_i) begin
              tx_trn_data_start_int <= 1'b1;
              state <= STATE_CONTROL_STATUS_IN_D;
            end else begin
              ctl_status <= HSK_NAK;
              state <= STATE_CONTROL_STATUS_IN_MYACK;
            end
          end
        end

        STATE_CONTROL_STATUS_IN_MYACK: begin
          if (tx_trn_hsk_sent) begin
            state <= STATE_CONTROL_STATUS_IN;
          end
        end

        STATE_CONTROL_STATUS_IN_D: begin
          tx_trn_data_start_int <= 1'b0;
          state <= STATE_CONTROL_STATUS_IN_ACK;
        end

        STATE_CONTROL_STATUS_IN_ACK: begin
          if (rx_trn_hsk_recv) begin
            state <= STATE_IDLE;
          end
        end

        STATE_BULK_IN: begin
          if (bid_tvalid_i && tx_trn_data_ready) begin
            if (tx_counter_over || bid_tlast_i) begin
              tx_trn_data_start_int <= 1'b0;
              state <= STATE_BULK_IN_ACK;
            end
            tx_counter <= tx_counter + 1;
          end else if (!bid_tvalid_i) begin
            tx_trn_data_start_int <= 1'b0;
            state <= STATE_BULK_IN_ACK;
          end
        end

        STATE_BULK_IN_ACK: begin
          if (rx_trn_hsk_recv) begin
            state <= STATE_IDLE;
          end
        end

        STATE_BULK_IN_MYACK: begin
          if (tx_trn_hsk_sent) begin
            state <= STATE_IDLE;
          end
        end

        STATE_BULK_OUT: begin
          if (rx_trn_end) begin
            state <= STATE_BULK_OUT_ACK;
          end
        end

        STATE_BULK_OUT_ACK: begin
          if (tx_trn_hsk_sent) begin
            state <= STATE_IDLE;
          end
        end
      endcase
    end
  end

  always @(*) begin
    case (state)
      STATE_CONTROL_SETUP_ACK: tx_trn_send_hsk_int <= 1'b1;
      STATE_CONTROL_STATUS_OUT_ACK: tx_trn_send_hsk_int <= 1'b1;
      STATE_CONTROL_STATUS_IN_MYACK: tx_trn_send_hsk_int <= 1'b1;
      STATE_BULK_IN_MYACK: tx_trn_send_hsk_int <= 1'b1;
      STATE_BULK_OUT_ACK: tx_trn_send_hsk_int <= 1'b1;
      STATE_CONTROL_DATAOUT_MYACK: tx_trn_send_hsk_int <= 1'b1;
      default: tx_trn_send_hsk_int <= 1'b0;
    endcase

    case (state)
      STATE_CONTROL_DATAIN: tx_trn_data_valid_int <= ctl_tvalid_i;
      STATE_BULK_IN: tx_trn_data_valid_int <= bid_tvalid_i;
      default: tx_trn_data_valid_int <= 1'b0;
    endcase

    if (state == STATE_CONTROL_DATAIN && (tx_counter[5:0] == 63 || tx_counter == ctl_xfer_length_int - 1)) begin
      tx_trn_data_last_int <= 1'b1;
    end else if (state == STATE_BULK_IN && (tx_counter_over || bid_tlast_i)) begin
      tx_trn_data_last_int <= 1'b1;
    end else if (state == STATE_CONTROL_STATUS_IN_D) begin
      tx_trn_data_last_int <= 1'b1;
    end else if (state == STATE_CONTROL_DATAIN_Z) begin
      tx_trn_data_last_int <= 1'b1;
    end else if (state == STATE_CONTROL_DATAIN) begin
      tx_trn_data_last_int <= ctl_tlast_i;
    end else begin
      tx_trn_data_last_int <= 1'b0;
    end
  end

  always @(*) begin
    if (tx_counter[5:0] == 63 && HIGH_SPEED == 0) begin
      tx_counter_over <= 1'b1;
    end else if (tx_counter[8:0] == 511 && HIGH_SPEED == 1) begin
      tx_counter_over <= 1'b1;
    end else begin
      tx_counter_over <= 1'b0;
    end
  end

endmodule
