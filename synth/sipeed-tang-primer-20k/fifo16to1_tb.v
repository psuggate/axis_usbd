`timescale 1ns / 100ps
module fifo16to1_tb;

  localparam WIDTH = 2;
  localparam ABITS = 2;
  localparam MSB = WIDTH - 1;
  localparam WSB = WIDTH * 16 - 1;


  reg clock = 1'b1;
  reg reset = 1'b0;

  always #5 clock <= ~clock;


  reg wr_valid, rd_ready;
  wire wr_ready, rd_valid, rd_last;
  reg [WSB:0] wr_data;
  wire [MSB:0] rd_data;

  reg start = 1'b0;
  reg frame = 1'b0;
  reg done = 1'b0;
  integer count = 0;

  initial begin
    $dumpfile("fifo16to1_tb.vcd");
    $dumpvars;
    #10 reset <= 1'b1;
    #10 reset <= 1'b0;

    #10 start <= 1'b1;
    #10 start <= 1'b0;

    #10 while (!done) #10;

    #20 $finish;
  end

  initial #4000 $finish;


  // -- Generate Fake Data -- //

  integer rx = 0;

  always @(posedge clock) begin
    if (reset) begin
      count <= 0;
      frame <= 1'b0;
      done <= 1'b0;
      wr_valid <= 1'b0;
      rd_ready <= 1'b0;
      rx <= 0;
    end else begin
      if (start) begin
        frame <= 1'b1;
      end

      if (frame) begin
        rd_ready <= 1'b1;

        if (!wr_valid && wr_ready) begin
          wr_valid <= 1'b1;
          wr_data  <= $urandom;

          if (count < 4) begin
            count <= count + 1;
          end else begin
            frame <= 1'b0;
          end
        end else if (wr_valid && wr_ready) begin
          wr_valid <= 1'b0;
          wr_data  <= 'hx;
        end

      end else begin
        wr_valid <= 1'b0;
        wr_data  <= 'hx;
      end

      if (rd_valid && rd_ready && rd_last) begin
        if (rx < 4) begin
          rx <= rx + 1;
        end else begin
          done <= 1'b1;
        end
      end

    end
  end


  // -- Module Under Test -- //

  fifo16to1 #(
      .WIDTH(WIDTH),
      .ABITS(ABITS)
  ) fifo16to1_inst (
      .clock(clock),
      .reset(reset),

      .valid_i(wr_valid),
      .ready_o(wr_ready),
      .data_i (wr_data),

      .valid_o(rd_valid),
      .ready_i(rd_ready),
      .last_o (rd_last),
      .data_o (rd_data)
  );


endmodule  // fifo16to1_tb
