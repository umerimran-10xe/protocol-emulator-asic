/*
 * Copyright (c) 2026 Umer Imran
 * SPDX-License-Identifier: Apache-2.0
 *
 * SPI slave that loads and reads back the program store.
 *
 * Frame, MSB first, while CS is low:
 *   8-bit header: [7] = 1 for read / 0 for write, [6:0] = start address
 *   then 16-bit words, address auto-incrementing.
 *
 * SCLK, MOSI and CS are asynchronous, so they are double-synchronised and all
 * edge detection happens in the core clock domain. That bounds SCLK to well
 * under the core clock; at 50 MHz core, 10 MHz SCLK has ample margin.
 */

`default_nettype none
`include "protoemu_isa.vh"

module protoemu_cfg (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 sclk_i,
    input  wire                 mosi_i,
    input  wire                 cs_n_i,
    output reg                  miso,

    output reg                  imem_we,
    output reg  [`PE_PC_W-1:0]  imem_waddr,   // held with imem_we, one cycle behind
    output wire [`PE_PC_W-1:0]  imem_raddr,   // live pointer, for readback
    output reg  [`PE_IW-1:0]    imem_wdata,
    input  wire [`PE_IW-1:0]    imem_rdata
);

  reg [2:0] sclk_s, cs_s;
  reg [1:0] mosi_s;

  wire sclk_rise = ~sclk_s[2] &  sclk_s[1];
  wire sclk_fall =  sclk_s[2] & ~sclk_s[1];
  wire cs_active = ~cs_s[1];
  wire cs_start  =  cs_s[2] & ~cs_s[1];   // CS just went low

  reg        phase;        // 0 = header, 1 = data words
  reg        rd;           // header bit 7
  reg [4:0]  bitcnt;
  reg [`PE_IW-2:0] insh;   // inbound shift register (the 16th bit is used directly)
  reg [`PE_IW-1:0] outsh;  // outbound shift register
  reg [`PE_PC_W-1:0] addr; // auto-incrementing word pointer

  assign imem_raddr = addr;

  always @(posedge clk) begin
    if (!rst_n) begin
      sclk_s <= 3'b000; cs_s <= 3'b111; mosi_s <= 2'b00;
      phase <= 1'b0; rd <= 1'b0; bitcnt <= 5'd0;
      insh <= {(`PE_IW-1){1'b0}}; outsh <= {`PE_IW{1'b0}};
      imem_we <= 1'b0; addr <= {`PE_PC_W{1'b0}};
      imem_waddr <= {`PE_PC_W{1'b0}};
      imem_wdata <= {`PE_IW{1'b0}}; miso <= 1'b0;
    end else begin
      sclk_s <= {sclk_s[1:0], sclk_i};
      cs_s   <= {cs_s[1:0],   cs_n_i};
      mosi_s <= {mosi_s[0],   mosi_i};

      imem_we <= 1'b0;      // single-cycle write strobe

      if (cs_start) begin
        phase  <= 1'b0;
        bitcnt <= 5'd0;
        insh   <= {(`PE_IW-1){1'b0}};
      end else if (cs_active) begin
        if (sclk_rise) begin
          insh   <= {insh[`PE_IW-3:0], mosi_s[1]};
          bitcnt <= bitcnt + 1'b1;

          if (!phase) begin
            if (bitcnt == 5'd7) begin
              // {insh[6:0], mosi} is the freshly completed header byte
              rd        <= insh[6];
              addr      <= {insh[5:0], mosi_s[1]};
              phase     <= 1'b1;
              bitcnt    <= 5'd0;
            end
          end else if (bitcnt == 5'd15) begin
            bitcnt <= 5'd0;
            addr   <= addr + 1'b1;
            if (!rd) begin
              imem_wdata <= {insh, mosi_s[1]};
              imem_waddr <= addr;   // this word's address, not the next one
              imem_we    <= 1'b1;
            end
          end
        end

        if (sclk_fall) begin
          // MISO only carries data during a read burst. Holding it low the rest
          // of the time keeps the pin defined even where the store has never
          // been written.
          if (!phase || !rd) begin
            miso <= 1'b0;
          end else if (bitcnt == 5'd0) begin
            // word boundary: imem_rdata already tracks imem_addr
            miso  <= imem_rdata[`PE_IW-1];
            outsh <= {imem_rdata[`PE_IW-2:0], 1'b0};
          end else begin
            miso  <= outsh[`PE_IW-1];
            outsh <= {outsh[`PE_IW-2:0], 1'b0};
          end
        end
      end
    end
  end

  wire _unused = &{1'b0, mosi_s[0], sclk_s[0], cs_s[0], 1'b0};

endmodule
