`timescale 1ns / 100ps
/**
 * Copyright (C) 2023, Patrick Suggate.
 *
 * Command scheduler for a GoWin DDR3 SDRAM controller. The AXI4-Lite interface
 * is for setting the read- & write- starting addresses. And the AXI4-Stream
 * interface is for streaming reads and writes, using the configured addresses.
 * Complete frames indicated via 's_tlast'/'m_tlast', and DDR3 SDRAM commands
 * are generated as required.
 * 
 * Note: the read and write FIFO's must be large enough to store an entire frame
 * of data.
 * 
 */
module axil_sdram_control (  /*AUTOARG*/);

  parameter DATA_WIDTH = 32;
  localparam DATA_STRBS = DATA_WIDTH / 8;
  localparam MSB = DATA_WIDTH - 1;
  localparam SSB = DATA_STRBS - 1;

  parameter ADDR_WIDTH = 24;
  localparam ASB = ADDR_WIDTH - 1;

  parameter AXIS_WIDTH = 8;
  localparam XSB = AXIS_WIDTH - 1;


  input axi_clock;
  input axi_reset;

  // -- AXI4-Lite Controller Write & Read Channel -- //

  input aw_valid;
  output aw_ready;
  input [2:0] aw_prot; // note: ignored
  input [ASB:0] aw_addr;

  input wr_valid;
  output wr_ready;
  input [SSB:0] wr_strb;
  input [MSB:0] wr_data;

  output wb_valid;
  input wb_ready;
  output wb_resp;

  input ar_valid;
  output ar_ready;
  input [2:0] ar_prot; // note: ignored
  input [ASB:0] ar_addr;

  output rd_valid;
  input rd_ready;
  output rd_resp;
  output [MSB:0] rd_data;

  // -- AXI4-Stream Data Write & Read Channels -- //

  input s_tvalid;
  output s_tready;
  input s_tlast;
  input [XSB:0] s_tdata;

  output m_tvalid;
  input m_tready;
  output m_tlast;
  output [XSB:0] m_tdata;

  // -- To DDR3 Controller -- //

  input ddr_clock;
  input ddr_rst_n;

  output dc_valid;
  input dc_ready;
  output [2:0] dc_command;
  output [5:0] dc_blength;

  output dw_valid;
  input dw_ready;
  output dw_last;
  output [15:0] dw_stb_n;
  output [127:0] dw_data;

  input dr_valid;
  input dr_last;
  input [127:0] dr_data;


  // AXI4-Lite commands are fairly limited ...
  assign dc_blength = 6'h00;


  // -- FIFOs store incoming read & write requests -- //

  // Store:
  //
  //  - command (read or write)
  //  - address
  //  - burst length
  //  - write data
  //  - read & write responses


  localparam COMMAND_WIDTH = 1 + 6 + ADDR_WIDTH;
  localparam CSB = COMMAND_WIDTH - 1;

  wire cmd_mode;
  wire [5:0] cmd_size;
  wire [ASB:0] cmd_addr;

  wire [CSB:0] cmd_data = {cmd_mode, cmd_size, cmd_addr};

  axis_afifo #(
      .WIDTH(COMMAND_WIDTH),
      .ABITS(4)
  ) command_afifo_inst (
      .s_aresetn(reset_n),

      .s_aclk    (axi_clock),
      .s_tvalid_i(m_tvalid),
      .s_tready_o(m_tready),
      .s_tlast_i (m_tlast),
      .s_tdata_i (m_tdata),

      .m_aclk    (ddr_clock),
      .m_tvalid_o(s_tvalid),
      .m_tready_i(s_tready),
      .m_tlast_o (s_tlast),
      .m_tdata_o (s_tdata)
  );

  axis_async_fifo #(
      .WIDTH(DATA_WIDTH),
      .ABITS(9)
  ) write_data_afifo_inst (
      .s_aresetn(reset_n),

      .s_aclk    (axi_clock),
      .s_tvalid_i(m_tvalid),
      .s_tready_o(m_tready),
      .s_tlast_i (m_tlast),
      .s_tdata_i (m_tdata),

      .m_aclk    (ddr_clock),
      .m_tvalid_o(s_tvalid),
      .m_tready_i(s_tready),
      .m_tlast_o (s_tlast),
      .m_tdata_o (s_tdata)
  );


  // -- Memory Controller Commands -- //

  localparam [2:0] STATE_INIT = 3'b000;
  localparam [2:0] STATE_IDLE = 3'b111;

  localparam [2:0] STATE_RADR = 3'b001;
  localparam [2:0] STATE_READ = 3'b100;
  localparam [2:0] STATE_RDAT = 3'b110;

  localparam [2:0] STATE_WADR = 3'b010;
  localparam [2:0] STATE_WDAT = 3'b011;
  localparam [2:0] STATE_WRIT = 3'b101;

  reg [2:0] state;  // smash early, smash often

  localparam [3:0] CMD_NOP = 4'b0000;
  localparam [3:0] CMD_STORE = 4'b1000;
  localparam [3:0] CMD_FETCH = 4'b1001;

  reg [3:0] ap_issue;

  wire ap_ready, ap_valid;
  wire [ 2:0] ap_cmd;
  reg  [14:0] ap_addr;  // Don't need all address bits
  wire [ 5:0] ap_blength;  // Set all bursts to 8 transfers

  reg wr_valid, wr_last;
  wire wr_ready;
  wire [15:0] wr_stb_n = 16'h0000;
  reg [127:0] wr_data;

  wire rd_valid, rd_last;
  wire [127:0] rd_data;

  wire init_calib_complete;


  // -- State-Machine for Issuing DDR3 Read- & Write Commands -- //

  assign ap_blength = 6'h00;
  assign ap_cmd = ap_issue[2:0];
  assign ap_valid = ap_issue[3];

  always @(posedge clk_x1) begin
    if (rst_x1) begin
      state <= STATE_INIT;
      x1_ready <= 1'b0;
      ap_issue <= CMD_NOP;
    end else begin
      case (state)

        // Wait for DDR3 calibration to complete
        STATE_INIT: begin
          cmd_issue <= CMD_NOP;

          if (init_calib_complete) begin
            state <= STATE_IDLE;
            x1_ready <= 1'b1;
          end else begin
            x1_ready <= 1'b0;
          end
        end

        // Wait for DDR3 commands (from USB)
        STATE_IDLE: begin
          x1_ready <= 1'b1;

          if (x1_valid && x1_ready) begin
            x1_addr[14:8] <= x1_data[6:0];

            if (x1_data[7]) begin
              state <= STATE_WADR;
            end else begin
              state <= STATE_RADR;
            end
          end
        end

        // -- DDR3 Read-Data States -- //

        // Read the low byte of the read-address
        STATE_RADR: begin
          if (x1_valid && x1_ready) begin
            x1_ready <= 1'b0;

            state <= STATE_READ;

            ap_addr[7:0] <= x1_data[7:0];
            ap_issue <= CMD_FETCH;
          end

          if (x1_valid && x1_ready && !x1_last) begin
            $error("Invalid READ command");
          end
        end

        // Issue the read command to the DDR3 controller, then wait ...
        STATE_READ: begin
          if (ap_ready) begin
            ap_issue <= CMD_NOP;
            state <= STATE_WAIT;
          end
        end

        // Assert the read-ready signal until all data has been received
        STATE_RDAT: begin
          if (rd_valid && rd_last) begin
            state <= STATE_IDLE;
            x1_ready <= 1'b1;
          end
        end

        // -- DDR3 Write-Data States -- //

        // Read the low byte of the write-address
        STATE_WADR: begin
          if (x1_valid && x1_ready) begin
            x1_addr[7:0] <= x1_data[7:0];
            state <= STATE_WDAT;
          end
        end

        // Receive data from the USB FIFO, and assemble the write-data
        STATE_WDAT: begin
          if (x1_valid && x1_ready) begin
            ap_data[127:0] <= {ap_data[119:0], x1_data[7:0]};

            if (x1_last) begin
              state <= STATE_WRIT;

              ap_issue <= CMD_WRITE;

              wr_valid <= 1'b1;
              wr_last <= 1'b1;
            end
          end
        end

        // Issue the write command to the DDR3 controller, and send the write-
        // data.
        STATE_WRIT: begin
          if (ap_ready) begin
            ap_issue <= CMD_NOP;
          end

          if (wr_ready && wr_valid && wr_last) begin
            state <= STATE_IDLE;
            x1_ready <= 1'b1;

            wr_valid <= 1'b0;
            wr_last <= 1'b0;
          end
        end

        default: begin
          $error("Time to go home");
          x1_ready <= 1'b0;
        end
      endcase
    end
  end


  // -- DDR3 SDRAM command scheduler -- //

  always @(posedge ddr_clock) begin
  end


endmodule  // axil_sdram_control
