// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Behavioural SPI NOR flash model for the QSPI boot loader benches.
//
// Command subset -- exactly what cdriscv_qspi_boot issues, which
// is the read-only subset every common 3 V NOR family implements the
// same way (Winbond W25Qxx, Macronix MX25Lxx, ISSI IS25LPxx, Micron
// M25P/MT25Q for 03h):
//
//   03h  Read Data        opcode + 24-bit address on IO0, data out on
//                         IO1, no dummy cycles, any sclk division of
//                         the loader's clk (the real parts cap 03h at
//                         ~50 MHz, far above anything this subsystem
//                         clocks out)
//   EBh  Quad I/O Fast    opcode on IO0; A23-0 as 6 nibbles plus one
//        Read             mode byte (2 nibbles) on IO[3:0]; then
//                         DummyCycles dummy sclk cycles (bus released);
//                         then data nibbles, high nibble of each byte
//                         first.  DummyCycles=4 matches W25Qxx /
//                         MX25Lxx / IS25LPxx with the mode byte counted
//                         separately, exactly as the loader drives it.
//                         A mode byte of xAh would arm "continuous
//                         read" on real silicon; the model checks the
//                         loader never sends one.
//
// Any other opcode is accepted and ignored (outputs stay released),
// like a real device ignoring a write with WEL clear.
//
// SPI mode 0: the model samples its inputs on the rising sclk edge and
// changes its outputs on the falling edge.  CS# rising resets the
// command state at any point.  Reads wrap through the byte array; the
// array resets to 8'hff (erased flash) and is then filled either from
// the InitFile parameter ($readmemh, one byte per line -- the format
// scripts/mkbootimg.py emits) or hierarchically by a bench.
//
// Observation hooks for benches (read-only): last_opcode_q holds the
// opcode of the current/most recent command, cmd_count_q counts
// commands (CS# falls that shipped an opcode), quad_used_q latches
// whether any EBh was issued since reset.
//
// STATUS: verification model, never synthesised.

`default_nettype none
`timescale 1ns/1ps

module cdriscv_spi_norflash_model #(
    parameter int unsigned MemBytes    = 65536,
    parameter int unsigned DummyCycles = 4,
    parameter string       InitFile    = ""
)(
    input  wire       sclk_i,
    input  wire       cs_ni,
    inout  wire [3:0] io
);

  logic [7:0] mem [0:MemBytes-1];

  initial begin
    for (int i = 0; i < MemBytes; i++) mem[i] = 8'hff;
    if (InitFile != "") $readmemh(InitFile, mem);
  end

  // ---- command state ----------------------------------------------
  typedef enum logic [2:0] {
    F_OPCODE, F_ADDR1, F_ADDR4, F_MODE4, F_DUMMY, F_DATA1, F_DATA4, F_IGNORE
  } fstate_e;

  fstate_e     st_q;
  logic [7:0]  sh_q;           // input shift assembly
  logic [5:0]  cnt_q;          // bits/nibbles/dummies within the state
  logic [23:0] addr_q;
  logic [7:0]  last_opcode_q;
  int unsigned cmd_count_q;
  logic        quad_used_q;

  // ---- outputs ----------------------------------------------------
  logic       drv1_q;          // driving IO1 (03h data)
  logic       drv4_q;          // driving IO[3:0] (EBh data)
  logic       so1_q;
  logic [3:0] so4_q;

  assign io[0] = drv4_q ? so4_q[0] : 1'bz;
  assign io[1] = drv4_q ? so4_q[1] : (drv1_q ? so1_q : 1'bz);
  assign io[2] = drv4_q ? so4_q[2] : 1'bz;
  assign io[3] = drv4_q ? so4_q[3] : 1'bz;

  initial begin
    st_q = F_OPCODE; sh_q = '0; cnt_q = '0; addr_q = '0;
    last_opcode_q = 8'h00; cmd_count_q = 0; quad_used_q = 1'b0;
    drv1_q = 1'b0; drv4_q = 1'b0; so1_q = 1'b0; so4_q = '0;
  end

  // CS# rising kills the transfer wherever it is
  always @(posedge cs_ni) begin
    st_q   <= F_OPCODE;
    cnt_q  <= '0;
    sh_q   <= '0;
    drv1_q <= 1'b0;
    drv4_q <= 1'b0;
  end

  // ---- rising edge: sample inputs ---------------------------------
  always @(posedge sclk_i) begin
    if (!cs_ni) begin
      case (st_q)
        F_OPCODE: begin : b_opcode
          logic [7:0] op;
          sh_q <= {sh_q[6:0], io[0]};
          op = {sh_q[6:0], io[0]};
          if (cnt_q == 6'd7) begin
            last_opcode_q <= op;
            cmd_count_q   <= cmd_count_q + 1;
            cnt_q         <= '0;
            case (op)
              8'h03:   st_q <= F_ADDR1;
              8'hEB:   begin st_q <= F_ADDR4; quad_used_q <= 1'b1; end
              default: st_q <= F_IGNORE;
            endcase
          end else begin
            cnt_q <= cnt_q + 6'd1;
          end
        end
        F_ADDR1: begin
          addr_q <= {addr_q[22:0], io[0]};
          if (cnt_q == 6'd23) begin
            cnt_q <= '0;
            st_q  <= F_DATA1;
          end else cnt_q <= cnt_q + 6'd1;
        end
        F_ADDR4: begin
          addr_q <= {addr_q[19:0], io};
          if (cnt_q == 6'd5) begin
            cnt_q <= '0;
            st_q  <= F_MODE4;
          end else cnt_q <= cnt_q + 6'd1;
        end
        F_MODE4: begin : b_mode
          logic [7:0] m;
          sh_q <= {sh_q[3:0], io};
          m = {sh_q[3:0], io};
          if (cnt_q == 6'd1) begin
            // M[5:4] == 2'b10 arms continuous-read mode on real
            // silicon -- the loader must never send it
            if (m[5:4] == 2'b10)
              $fatal(1, "[flash] mode byte %02x arms continuous read", m);
            cnt_q <= '0;
            st_q  <= F_DUMMY;
          end else cnt_q <= cnt_q + 6'd1;
        end
        F_DUMMY: begin
          if (cnt_q == 6'(DummyCycles - 1)) begin
            cnt_q <= '0;
            st_q  <= F_DATA4;
          end else cnt_q <= cnt_q + 6'd1;
        end
        F_DATA1: begin
          if (cnt_q == 6'd7) begin
            cnt_q  <= '0;
            addr_q <= addr_q + 24'd1;
          end else cnt_q <= cnt_q + 6'd1;
        end
        F_DATA4: begin
          if (cnt_q == 6'd1) begin
            cnt_q  <= '0;
            addr_q <= addr_q + 24'd1;
          end else cnt_q <= cnt_q + 6'd1;
        end
        default: ;   // F_IGNORE: sit out the rest of the command
      endcase
    end
  end

  // ---- falling edge: drive outputs --------------------------------
  function automatic logic [7:0] rd(input logic [23:0] a);
    return mem[a % MemBytes];
  endfunction

  always @(negedge sclk_i) begin : b_out
    logic [7:0] d;
    if (!cs_ni) begin
      // Entering (or continuing) a data state: after the rising edge
      // that completed the address/dummy phase, st_q/cnt_q/addr_q
      // already point at the next thing to send.
      d = rd(addr_q);
      if (st_q == F_DATA1) begin
        drv1_q <= 1'b1;
        so1_q  <= d[3'd7 - cnt_q[2:0]];
      end else if (st_q == F_DATA4) begin
        drv4_q <= 1'b1;
        quad_used_q <= 1'b1;
        so4_q <= (cnt_q[0] == 1'b0) ? d[7:4] : d[3:0];
      end else begin
        drv1_q <= 1'b0;
        drv4_q <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
