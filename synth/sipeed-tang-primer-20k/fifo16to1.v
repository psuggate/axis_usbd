`timescale 1ns / 100ps
module fifo16to1 (
    clock,
    reset,

    valid_i,
    ready_o,
    data_i,

    valid_o,
    ready_i,
    last_o,
    data_o
);

  parameter WIDTH = 8;
  localparam MSB = WIDTH - 1;
  localparam WSB = WIDTH * 16 - 1;

  parameter ABITS = 4;
  localparam DEPTH = 1 << ABITS;
  localparam ASB = ABITS - 1;
  localparam WADDR = ABITS + 1;

  localparam RBITS = ABITS + 4;
  localparam RADDR = RBITS + 1;
  localparam RSB = RBITS - 1;


  input clock;
  input reset;

  input valid_i;
  output ready_o;
  input [WSB:0] data_i;

  output valid_o;
  input ready_i;
  output last_o;
  output [MSB:0] data_o;


  reg [WSB:0] sram[0:DEPTH-1];

  // Write-port signals
  reg [ABITS:0] waddr;
  reg wready;
  wire [ABITS:0] waddr_next;

  // Read-port signals
  reg rvalid, rlast, xread;
  reg [RBITS:0] raddr;
  reg [WSB:0] xdata, rdata;
  wire [RBITS:0] raddr_next;
  wire [  WSB:0] rdata_next;

  assign ready_o = wready;
  assign valid_o = rvalid;
  assign last_o  = rlast;
  assign data_o  = rdata[MSB:0];


  // -- Write Port -- //

  wire wrfull = waddr_next[ASB:0] == raddr[RSB:4];

  assign waddr_next = waddr + 1;

  always @(posedge clock) begin
    if (reset) begin
      waddr  <= {WADDR{1'b0}};
      wready <= 1'b0;
    end else begin
      wready <= ~wrfull;

      if (valid_i && wready) begin
        sram[waddr] <= data_i;
        waddr <= waddr_next;
      end
    end
  end


  // -- Read Port -- //

  wire rd_ce;
  reg  rempty;
  // wire rempty = raddr == {waddr, 4'h0};

  assign raddr_next = raddr + 1;
  assign rdata_next = {8'hx, rdata[WSB:WIDTH]};

  always @(posedge clock) begin
    if (reset) begin
      raddr  <= {RADDR{1'b0}};
      rempty <= 1'b1;
      rvalid <= 1'b0;
      rlast  <= 1'b0;
      xread  <= 1'b0;
    end else begin
      xdata <= sram[raddr[RSB:4]];

      if (rvalid && ready_i && raddr[3:0] == 4'hf) begin
        xread <= 1'b1;
      end else if (rvalid && ready_i && raddr[3:0] == 4'h0) begin
        xread <= 1'b0;
      end

      rempty <= raddr == {waddr, 4'h0};
      rvalid <= ~rempty;

      if (!rvalid) begin
        rdata <= xdata;
      end else if (rvalid && ready_i) begin
        raddr <= raddr_next;
        rdata <= rlast ? xdata : rdata_next;
        rlast <= xread;
      end

    end
  end


endmodule  // fifo16to1
