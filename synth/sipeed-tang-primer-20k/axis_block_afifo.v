`timescale 1ns / 100ps
module axis_block_afifo (  /*AUTOARG*/);

  parameter WIDTH = 8;
  parameter ABITS = 11;

  localparam MSB = WIDTH - 1;
  localparam ASB = ABITS - 1;
  localparam DEPTH = 1 << ABITS;
  localparam ADDRS = ABITS + 1;


  input s_clock;
  input s_reset;
  input s_tvalid;
  output s_tready;
  input s_tlast;
  input [MSB:0] s_tdata;

  input m_clock;
  input m_reset;
  output m_tvalid;
  input m_tready;
  output m_tlast;
  output [MSB:0] m_tdata;


  // -- Block SRAM, with Registered Outputs -- //

  reg [WIDTH:0] bram[0:DEPTH-1];


  // -- Globals and Cross-Domain Signals -- //

  (* ASYNC_REG = "TRUE" *)
  reg [ABITS:0] wc_gray_sync;
  (* ASYNC_REG = "TRUE" *)
  reg [ABITS:0] wr_gray_sync;

  (* ASYNC_REG = "TRUE" *)
  reg [ABITS:0] rc_gray_sync;
  (* ASYNC_REG = "TRUE" *)
  reg [ABITS:0] rd_gray_sync;

  reg [ABITS:0] wc_gray, wr_gray, rc_gray, rd_gray;
  wire [ABITS:0] w_count_x, r_count_x, wr_addr_x, rd_addr_x;

  // Convert Gray to binary
  assign w_count_x = wc_gray_sync ^ {1'b0, w_count_x[ABITS:1]};
  assign wr_addr_x = wr_gray_sync ^ {1'b0, wr_addr_x[ABITS:1]};

  assign r_count_x = rc_gray_sync ^ {1'b0, r_count_x[ABITS:1]};
  assign rd_addr_x = rd_gray_sync ^ {1'b0, rd_addr_x[ABITS:1]};

  always @(posedge m_clock) begin
    wc_gray_sync <= wc_gray;  // write counter -> read domain
    wr_gray_sync <= wr_gray;  // write pointer -> read domain
  end

  always @(posedge s_clock) begin
    rc_gray_sync <= rc_gray;  // read counter -> write domain
    rd_gray_sync <= rd_gray;  // read pointer -> write domain
  end


  // -- Write Clock Domain -- //

  reg [ABITS:0] w_count, wr_addr;
  wire [ABITS:0] wr_addr_next, wr_gray_next;

  assign wr_addr_next = wr_addr + 1;
  assign wr_gray_next = wr_addr_next ^ {1'b0, wr_addr_next[ABITS:1]};

  always @(posedge s_clock) begin
    if (s_reset) begin
      w_count <= {ADDRS{1'b0}};
      wc_gray <= {ADDRS{1'b0}};

      wr_addr <= {ADDRS{1'b0}};
      wr_gray <= {ADDRS{1'b0}};
    end else begin
      // Count each end-of-frame
      if (s_tvalid && s_tlast && s_tready) begin
        w_count <= w_count_next;
        wc_gray <= wc_gray_next;
      end

      // Count each transfer
      if (s_tvalid && s_tready) begin
        wr_addr <= wr_addr_next;
        wr_gray <= wr_gray_next;

        bram[wr_addr] <= {s_tlast, s_tdata};
      end
    end
  end


  // -- Read Clock Domain -- //

  reg [ABITS:0] r_count, rd_addr;
  wire [ABITS:0] r_count_next, rc_gray_next;
  wire [ABITS:0] rd_addr_next, rd_gray_next;

  assign r_count_next = r_count + 1;
  assign rc_gray_next = r_count_next ^ {1'b0, r_count_next[ABITS:1]};

  assign rd_addr_next = rd_addr + 1;
  assign rd_gray_next = rd_addr_next ^ {1'b0, rd_addr_next[ABITS:1]};

  always @(posedge m_clock) begin
    if (m_reset) begin
      r_count <= {ADDRS{1'b0}};
      rc_gray <= {ADDRS{1'b0}};

      rd_addr <= {ADDRS{1'b0}};
      rd_gray <= {ADDRS{1'b0}};
    end else begin
      // Count each end-of-frame
      if (m_tvalid && m_tlast && m_tready) begin
        r_count <= r_count_next;
        rc_gray <= rc_gray_next;
      end

      // Count each transfer
      if (m_tvalid && m_tready) begin
        rd_addr <= rd_addr_next;
        rd_gray <= rd_gray_next;
      end
    end
  end

  // todo: Output AXIS register
  always @(posedge m_clock) begin
    if (m_tvalid && m_tready) begin
      {m_tlast, m_tdata} <= bram[rd_addr];
    end else if (!m_tvalid && !rempty) begin
    end
  end

endmodule  // axis_block_afifo
