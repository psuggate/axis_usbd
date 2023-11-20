`timescale 1ns / 100ps
module usb_encode (
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

      function src_ready(input svalid, input tvalid, input dvalid, input dready);
        src_ready = dready || !(tvalid || (dvalid && svalid));
      endfunction

      function tmp_valid(input svalid, input tvalid, input dvalid, input dready);
        tmp_valid = !src_ready(svalid, tvalid, dvalid, dready);
      endfunction

      function dst_valid(input svalid, input tvalid, input dvalid, input dready);
        dst_valid = tvalid || svalid || (dvalid && !dready);
      endfunction

      function src_to_tmp(input src_ready, input dst_valid, input dst_ready);
        src_to_tmp = src_ready && !dst_ready && dst_valid;
      endfunction

      function tmp_to_dst(input tmp_valid, input dst_ready);
        tmp_to_dst = tmp_valid && dst_ready;
      endfunction

      function src_to_dst(input src_ready, input dst_valid, input dst_ready);
        src_to_dst = src_ready && (dst_ready || !dst_valid);
      endfunction

reg xvalid, tvalid, uready;
reg xlast, tlast;
reg [7:0] xdata, tdata;
wire tvalid_next, xvalid_next, uready_next;

reg [15:0] crc16_q;

reg xhsk_q, xtok_q, xdat_q, zero_q, xcrc_q;
reg hend_q, kend_q;


assign hsk_done_o = hend_q;
assign tok_done_o = kend_q;

assign tx_tvalid_o = tvalid;
assign tx_tlast_o  = tlast;
assign tx_tdata_o  = tdata;

assign trn_tready_o = uready;

assign uready_next = src_ready(trn_tvalid_i, xvalid, tvalid, tx_tready_i);
assign xvalid_next = tmp_valid(trn_tvalid_i, xvalid, tvalid, tx_tready_i);
assign tvalid_next = dst_valid(trn_tvalid_i, xvalid, tvalid, tx_tready_i);


  // -- Tx data CRC Calculation -- //

  wire [15:0] crc16_nw;

  assign crc16_nw = ~{crc16_q[0], crc16_q[1], crc16_q[2], crc16_q[3],
                      crc16_q[4], crc16_q[5], crc16_q[6], crc16_q[7],
                      crc16_q[8], crc16_q[9], crc16_q[10], crc16_q[11],
                      crc16_q[12], crc16_q[13], crc16_q[14], crc16_q[15]
                     };

  always @(posedge clock) begin
    if (!xdat_q) begin
      crc16_q <= 16'hFFFF;
    end else if (trn_tvalid_i && uready) begin
      crc16_q <= crc16(trn_tdata_i, crc16_q);
    end
  end


`ifndef __potato_salad

// -- ACKs for Handshakes and Tokens -- //

always @(posedge clock) begin
  if (!hsk_send_i) begin
    hend_q <= 1'b0;
  end else if (xhsk_q && hsk_send_i && tx_tready_i) begin
    hend_q <= 1'b1;
  end else begin
    hend_q <= hend_q;
  end
end

always @(posedge clock) begin
  if (!tok_send_i) begin
    kend_q <= 1'b0;
  end else if (xtok_q && tok_send_i && tlast && tx_tready_i) begin
    kend_q <= 1'b1;
  end else begin
    kend_q <= kend_q;
  end
end


// -- FSM -- //

wire [2:0] state = {xdat_q, xtok_q, xhsk_q};

always @(posedge clock) begin
  if (reset) begin
    {xdat_q, xtok_q, xhsk_q, zero_q, xcrc_q} <= 5'b00000;

    uready <= 1'b0;
    tvalid <= 1'b0;
    tlast  <= 1'b0;
    tdata  <= 8'bx;

    xvalid <= 1'b0;
    xlast  <= 1'bx;
    xdata  <= 8'bx;
  end else begin
    case (state)
        3'b001: begin
          // Handshake packet
          if (!hsk_send_i) begin
            xhsk_q <= 1'b0;
          end

          if (tx_tready_i) begin
            tvalid <= 1'b0;
            tlast  <= 1'b0;
          end

          zero_q <= 1'bx;
          xcrc_q <= 1'bx;
          uready <= 1'b0;
          xvalid <= 1'b0;
          xlast  <= 1'bx;
          xdata  <= 8'bx;
        end

        3'b010: begin
          // Token packet
          if (!tok_send_i) begin
            xtok_q <= 1'b0;
          end

          if (tx_tready_i) begin
            if (zero_q) begin
              zero_q <= 1'b0;

              tvalid <= 1'b1;
              tlast  <= 1'b0;
              tdata  <= tok_data_i[7:0];
            end else if (tlast) begin
              tvalid <= 1'b0;
              tlast  <= 1'b0;
              tdata  <= 8'bx;
            end else begin
              tvalid <= 1'b1;
              tlast  <= 1'b1;
              tdata  <= tok_data_i[15:8];
            end
          end
        end

        3'b100: begin
          if (xcrc_q && tx_tready_i) begin
            // Sending 2nd byte of CRC16
            if (tlast) begin
              {xdat_q, xcrc_q} <= 2'b00;

              tvalid <= 1'b0;
              tlast  <= 1'b0;
              tdata  <= 8'bx;
            end else begin
              tvalid <= 1'b1;
              tlast  <= 1'b1;
              tdata  <= crc16_nw[15:8];
            end
          end else if (tx_tready_i && (zero_q || !trn_tvalid_i)) begin
            // Sending 1st byte of CRC16
            {zero_q, xcrc_q} <= 2'b01;

            tvalid <= 1'b1;
            tlast  <= 1'b0;
            tdata  <= crc16_nw[7:0];
          end else begin
            // Transfer data from source to destination
            if (uready && trn_tvalid_i && trn_tlast_i) begin
              uready <= 1'b0;
            end else begin
              uready <= uready_next;
            end
            tvalid <= tvalid_next;
            xvalid <= xvalid_next;

            if (src_to_dst(uready, tvalid, tx_tready_i)) begin
              tdata  <= trn_tdata_i;
              zero_q <= trn_tlast_i;
            end else if (tmp_to_dst(xvalid, tx_tready_i)) begin
              tdata <= xdata;
              zero_q <= xlast;
            end

            if (src_to_tmp(uready, tvalid, tx_tready_i)) begin
              xdata <= trn_tdata_i;
              xlast <= trn_tlast_i;
            end
          end
        end

        default: begin
          if (hsk_send_i) begin
            {xdat_q, xtok_q, xhsk_q} <= 3'b001;

            uready <= 1'b0; // data not coming from upstream
            tvalid <= 1'b1;
            tlast  <= 1'b1;
            tdata  <= {~{hsk_type_i, 2'b10}, hsk_type_i, 2'b10};
          end else if (tok_send_i) begin
            {xdat_q, xtok_q, xhsk_q} <= 5'b010;
            zero_q <= 1'b1;

            uready <= 1'b0; // data not coming from upstream
            tvalid <= 1'b1;
            tlast  <= 1'b0;
            tdata  <= {~{tok_type_i, 2'b01}, {tok_type_i, 2'b01}};
          end else if (trn_start_i) begin
            {xdat_q, xtok_q, xhsk_q} <= 3'b100;
            zero_q <= trn_tlast_i; // PID-only packet ??

            uready <= 1'b1;
            tvalid <= 1'b1;
            tlast  <= 1'b0;
            tdata  <= {~{trn_type_i, 2'b11}, {trn_type_i, 2'b11}};
          end else begin
            {xdat_q, xtok_q, xhsk_q} <= 3'b000;
            {zero_q, xcrc_q} <= 2'b00;

            uready <= 1'b0;
            tvalid <= 1'b0;
            tlast  <= 1'b0;
            tdata  <= 8'bx;
          end
        end
    endcase
  end
end

`else

always @(posedge clock) begin
  if (reset) begin
    {xdat_q, xtok_q, xhsk_q, zero_q, xcrc_q} <= 5'b000;
    {kend_q, hend_q} <= 5'b000;

    uready <= 1'b0;
    tvalid <= 1'b0;
    tlast  <= 1'b0;
    tdata  <= 8'bx;
  end else if (xhsk_q) begin

    // Handshake packet
    if (!hsk_send_i && hend_q) begin
      hend_q <= 1'b0;
      xhsk_q <= 1'b0;
    end else if (tx_tready_i) begin
      tvalid <= 1'b0;
      tlast  <= 1'b0;
      hend_q <= 1'b1;
    end

  end else if (xtok_q) begin

    // Token packet
    if (tx_tready_i) begin
      if (zero_q) begin
        zero_q <= 1'b0;

        tvalid <= 1'b1;
        tlast  <= 1'b0;
        tdata  <= tok_data_i[7:0];
      end else if (tlast) begin
        kend_q <= 1'b1;

        tvalid <= 1'b0;
        tlast  <= 1'b0;
        tdata  <= 8'bx;
      end else begin
        tvalid <= 1'b1;
        tlast  <= 1'b1;
        tdata  <= tok_data_i[15:8];
      end
    end else if (kend_q && !tok_send_i) begin
      xtok_q <= 1'b0;
      kend_q <= 1'b0;
    end

  end else if (xdat_q) begin

    if (xcrc_q && tx_tready_i) begin
      // Sending 2nd byte of CRC16
      if (tlast) begin
        {xdat_q, xcrc_q} <= 2'b00;

        tvalid <= 1'b0;
        tlast  <= 1'b0;
        tdata  <= 8'bx;
      end else begin
        tvalid <= 1'b1;
        tlast  <= 1'b1;
        tdata  <= crc16_nw[15:8];
      end
    end else if (tx_tready_i && (zero_q || !trn_tvalid_i)) begin
      // Sending 1st byte of CRC16
      {zero_q, xcrc_q} <= 2'b01;

      tvalid <= 1'b1;
      tlast  <= 1'b0;
      tdata  <= crc16_nw[7:0];
    end else begin
      // Transfer data from source to destination
      if (uready && trn_tvalid_i && trn_tlast_i) begin
        uready <= 1'b0;
      end else begin
        uready <= uready_next;
      end
      tvalid <= tvalid_next;
      xvalid <= xvalid_next;

      if (src_to_dst(uready, tvalid, tx_tready_i)) begin
        tdata  <= trn_tdata_i;
        zero_q <= trn_tlast_i;
      end else if (tmp_to_dst(xvalid, tx_tready_i)) begin
        tdata <= xdata;
        zero_q <= xlast;
      end

      if (src_to_tmp(uready, tvalid, tx_tready_i)) begin
        xdata <= trn_tdata_i;
        xlast <= trn_tlast_i;
      end
    end

  end else begin // todo: don't need this state ??
    {kend_q, hend_q} <= 3'b000;

    if (hsk_send_i) begin
      {xdat_q, xtok_q, xhsk_q} <= 3'b001;

      uready <= 1'b0; // data not coming from upstream
      tvalid <= 1'b1;
      tlast  <= 1'b1;
      tdata  <= {~{hsk_type_i, 2'b10}, hsk_type_i, 2'b10};
    end else if (tok_send_i) begin
      {xdat_q, xtok_q, xhsk_q} <= 5'b010;
      zero_q <= 1'b1;

      uready <= 1'b0; // data not coming from upstream
      tvalid <= 1'b1;
      tlast  <= 1'b0;
      tdata  <= {~{tok_type_i, 2'b01}, {tok_type_i, 2'b01}};
    end else if (trn_start_i) begin
      {xdat_q, xtok_q, xhsk_q} <= 3'b100;
      zero_q <= trn_tlast_i; // PID-only packet ??

      uready <= 1'b1;
      tvalid <= 1'b1;
      tlast  <= 1'b0;
      tdata  <= {~{trn_type_i, 2'b11}, {trn_type_i, 2'b11}};
    end else begin
      {xdat_q, xtok_q, xhsk_q} <= 3'b000;
      {zero_q, xcrc_q} <= 2'b00;

      uready <= 1'b0;
      tvalid <= 1'b0;
      tlast  <= 1'b0;
      tdata  <= 8'bx;
    end
  end
end
`endif


endmodule // usb_encode
