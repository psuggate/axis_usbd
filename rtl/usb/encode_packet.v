`timescale 1ns / 100ps
module encode_packet (
    reset,
    clock,

    tx_tvalid_o,
    tx_tready_i,
    tx_tlast_o,
    tx_tdata_o,

    hsk_type_i,  // 00 - ACK, 10 - NAK, 11 - STALL, 01 - BLYAT //
    hsk_send_i,
    hsk_done_o,

    tok_send_i,
    tok_done_o,
    tok_type_i,  // 00 - OUT, 01 - SOF, 10 - IN, 11 - SETUP //
    tok_data_i,

    trn_type_i,  // DATA0/1/2 MDATA //
    trn_start_i,
    trn_tvalid_i,
    trn_tready_o,
    trn_tlast_i,
    trn_tdata_i
);

  input reset;
  input clock;

  output tx_tvalid_o;
  input tx_tready_i;
  output tx_tlast_o;
  output [7:0] tx_tdata_o;

  input [1:0] hsk_type_i;  /* 00 - ACK, 10 - NAK, 11 - STALL, 01 - BLYAT */
  input hsk_send_i;
  output hsk_done_o;

  input tok_send_i;
  output tok_done_o;
  input [1:0] tok_type_i;
  input [15:0] tok_data_i;

  input [1:0] trn_type_i;  /* DATA0/1/2 MDATA */
  input trn_start_i;
  input trn_tvalid_i;
  output trn_tready_o;
  input trn_tlast_i;
  input [7:0] trn_tdata_i;

`include "usb_crc.vh"

  localparam [10:0]
	ST_IDLE     = 11'h001,
	ST_HSK      = 11'h002,
	ST_HSK_WAIT = 11'h004,
	ST_DPID     = 11'h008,
	ST_DATA     = 11'h010,
	ST_CRC1     = 11'h020,
	ST_CRC2     = 11'h040,
	ST_TOK1     = 11'h080,
	ST_TOK2     = 11'h100,
	ST_TOK3     = 11'h200,
	ST_TOK4     = 11'h400;

  reg [10:0] state;

  reg [15:0] tx_crc16;
  wire [15:0] tx_crc16_nw;
  reg zero_packet;
  reg tvld, tlst, xrdy;
  reg [7:0] tdat;

  wire tx_ready;


  // -- Input/Output Assignments -- //

  assign hsk_done_o  = state == ST_HSK_WAIT;
  assign tok_done_o  = state == ST_TOK4;


  // -- Internal Signals -- //

  assign tx_crc16_nw = ~{tx_crc16[0], tx_crc16[1], tx_crc16[2], tx_crc16[3],
                         tx_crc16[4], tx_crc16[5], tx_crc16[6], tx_crc16[7],
                         tx_crc16[8], tx_crc16[9], tx_crc16[10], tx_crc16[11],
                         tx_crc16[12], tx_crc16[13], tx_crc16[14], tx_crc16[15]
                        };


  // -- Tx data CRC Calculation -- //

  always @(posedge clock) begin
    if (state == ST_IDLE) begin
      tx_crc16 <= 16'hFFFF;
    end else if (state == ST_DATA && tx_ready && trn_tvalid_i) begin
    // end else if (state == ST_DATA && tx_tready_i && trn_tvalid_i) begin
      tx_crc16 <= crc16(trn_tdata_i, tx_crc16);
    end
  end


  // -- Tx FSM -- //

  always @(posedge clock) begin
    if (reset) begin
      state <= ST_IDLE;
      zero_packet <= 1'bx;
    end else begin
      case (state)
        ST_IDLE: begin
          if (hsk_send_i) begin
            state <= ST_HSK;
            zero_packet <= 1'bx;
          end else if (tok_send_i) begin
            state <= ST_TOK1;
            zero_packet <= 1'bx;
          end else if (trn_start_i) begin
            state <= ST_DPID;
            zero_packet <= trn_tlast_i && !trn_tvalid_i;
          end else begin
            state <= state;
            zero_packet <= 1'bx;
          end
        end

        ST_TOK1: state <= tx_ready ? ST_TOK2 : state; 
        ST_TOK2: state <= tx_ready ? ST_TOK3 : state; 
        ST_TOK3: state <= tx_ready ? ST_TOK4 : state; 
        ST_TOK4: state <= !tok_send_i ? ST_IDLE : state; 

        ST_HSK: begin
          if (tx_ready) begin
            state <= ST_HSK_WAIT;
          end
          zero_packet <= 1'bx;
        end

        ST_HSK_WAIT: begin
          if (!hsk_send_i) begin
            state <= ST_IDLE;
          end
          zero_packet <= 1'bx;
        end

        ST_DPID: begin
          if (tx_ready) begin
            state <= zero_packet ? ST_CRC1 : ST_DATA;
            zero_packet <= 1'bx;
          end else begin
            state <= state;
            zero_packet <= zero_packet;
          end
        end

        ST_DATA: begin
          if (tx_ready && trn_tvalid_i) begin
            if (trn_tlast_i) begin
              state <= ST_CRC1;
            end
          end else if (!trn_tvalid_i) begin
            state <= ST_CRC2;
            // state <= ST_CRC1;
          end
          zero_packet <= 1'bx;
        end

        ST_CRC1: begin
          if (tx_ready) begin
            state <= ST_CRC2;
          end
          zero_packet <= 1'bx;
        end

        ST_CRC2: begin
          if (tx_ready) begin
            state <= ST_IDLE;
          end
          zero_packet <= 1'bx;
        end

        default: begin
          state <= ST_IDLE;
          zero_packet <= 1'bx;
        end
      endcase
    end
  end


  // -- Tx Data-path -- //

`define __upstream_flow_control_works
`ifdef __upstream_flow_control_works
  /**
   * TODO:
   *  - I think that there are upstream data-path problems ??
   *  - Specifically, I don't think the upstream flow-control works correctly !?
   */
  reg tx_cycle_q;

  assign trn_tready_o = xrdy;
  assign tx_ready = !tvld || tvld && tx_tready_i;
  // assign trn_tready_o = !tvld || tvld && tx_tready_i;
  // assign tx_ready = tx_tready_i;
  // assign tx_ready = xrdy;

  assign tx_tvalid_o = tvld;
  assign tx_tlast_o  = tlst;
  assign tx_tdata_o  = tdat;

  always @(posedge clock) begin
    case (state)
      ST_IDLE: tx_cycle_q <= trn_start_i & ~hsk_send_i;
      default: begin
        if (tx_cycle_q && tvld && tlst && tx_tready_i) begin
          tx_cycle_q <= 1'b0;
        end
      end
    endcase
  end

  always @(posedge clock) begin
    if (tx_cycle_q) begin
      xrdy <= !tvld || tvld && tx_tready_i;
    end else begin
      xrdy <= 1'b0;
    end
  end

  always @(posedge clock) begin
    case (state)
      ST_IDLE: begin
        if (hsk_send_i) begin
          tvld <= 1'b1;
          tlst <= 1'b1;
          tdat <= {(~{hsk_type_i, 2'b10}), hsk_type_i, 2'b10};
        end else if (trn_start_i) begin
          tvld <= 1'b1;
          tlst <= 1'b0;
          tdat <= {(~{trn_type_i, 2'b11}), {trn_type_i, 2'b11}};
        end else begin
          tvld <= 1'b0;
          tlst <= 1'b0;
          tdat <= 'bx;
        end
      end

      ST_HSK: begin
        if (tx_tready_i) begin
          tvld <= 1'b0;
          tlst <= 1'b0;
          tdat <= 'bx;
        end
      end

      ST_DPID: begin
        tvld <= 1'b1;
        tlst <= 1'b0;
        if (tx_tready_i) begin
          tdat <= zero_packet || !trn_tvalid_i ? tx_crc16_nw[7:0] : trn_tdata_i;
        end
      end

      ST_DATA: begin
        tvld <= 1'b1;
        tlst <= 1'b0;
        if (tx_tready_i) begin
          tdat <= trn_tvalid_i && !trn_tlast_i ? trn_tdata_i : tx_crc16_nw[7:0];
        end else begin
          tdat <= tdat;
        end
      end

      ST_CRC1: begin
        if (tx_tready_i) begin
          tvld <= 1'b1;
          tlst <= 1'b1;
          tdat <= tx_crc16_nw[15:8];
        end
      end

      ST_CRC2: begin
        if (tx_tready_i) begin
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

  wire trdy_w;

  // assign trn_tready_o = state == ST_DATA & tx_tready_i;
  // assign tx_ready = tx_tready_i;
  assign trn_tready_o = state == ST_DATA & trdy_w;
  assign tx_ready = trdy_w;

  // todo: clean-up this disaster site !?
  always @(*) begin
    if (state == ST_DPID) begin
      tdat = {(~{trn_type_i, 2'b11}), {trn_type_i, 2'b11}};
    end else if (state == ST_HSK) begin
      tdat = {(~{hsk_type_i, 2'b10}), hsk_type_i, 2'b10};
    end else if (state == ST_CRC1 || state == ST_DATA && !trn_tvalid_i) begin
      tdat = tx_crc16_nw[7:0];
    end else if (state == ST_CRC2) begin
      tdat = tx_crc16_nw[15:8];
    end else if (state == ST_TOK1) begin
      tdat = {~{tok_type_i, 2'b01}, {tok_type_i, 2'b01}};
    end else if (state == ST_TOK2) begin
      tdat = tok_data_i[7:0];
    end else if (state == ST_TOK3) begin
      tdat = tok_data_i[15:8];
    end else begin
      tdat = trn_tdata_i;
    end

    if (state == ST_DPID || state == ST_HSK ||
        state == ST_CRC1 || state == ST_CRC2 ||
        state == ST_TOK1 || state == ST_TOK2 || state == ST_TOK3 ||
        state == ST_DATA) begin
      tvld = 1'b1;
    end else begin
      tvld = 1'b0;
    end

    if (state == ST_HSK || state == ST_CRC2 || state == ST_TOK3) begin
      tlst = 1'b1;
    end else begin
      tlst = 1'b0;
    end
  end

  // todo: instantiating this ('BYPASS(1)') causes the same types of failure as
  //   the alternative implementation in the 'ifdef' block above -- this skid-
  //   register works, so does this mean that there is a problem upstream !?
  axis_skid #(
      .WIDTH (8),
      .BYPASS(0)
  ) axis_skid_inst (
      .clock(clock),
      .reset(reset),

      .s_tvalid(tvld),
      .s_tready(trdy_w),
      .s_tlast (tlst),
      .s_tdata (tdat),

      .m_tvalid(tx_tvalid_o),
      .m_tready(tx_tready_i),
      .m_tlast (tx_tlast_o),
      .m_tdata (tx_tdata_o)
  );

`endif


endmodule  // encode_packet
