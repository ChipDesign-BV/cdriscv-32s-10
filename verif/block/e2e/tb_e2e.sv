// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 v2 -- end-to-end bus protection block bench.
//
// The claim E2E makes is narrow and specific: a payload that arrives
// intact but at the WRONG ADDRESS must be rejected.  That is what
// separates it from a second data ECC, and it is the property this
// bench exists to attack.  Five regimes:
//
//   clean        correct data, address, be and check -> no error
//   data fault   any 1- or 2-bit flip in data    -> error
//   addr fault   right data, wrong address       -> error   <-- the point
//   be fault     any 1- or 2-bit flip in be      -> error   (added
//                2026-09-02 with the {data, addr, be} fold: the fault
//                campaign measured every SDC of the E2E sweep to be a
//                be flip, so the fold grew a third field and this bench
//                grew the regime that attacks it)
//   check fault  any 1-bit flip in the check     -> error
//
// Detection is not claimed to be exhaustive: the check is 7 bits, so
// roughly 1 in 128 random corruptions will alias to the same syndrome.
// The bench measures the escape rate rather than asserting zero, and
// fails only if it exceeds what a 7-bit check can deliver.

`timescale 1ns/1ps

module tb_e2e;

  logic [31:0] data, addr, addr_rx, data_rx;
  logic [3:0]  be, be_rx;
  logic [6:0]  chk, chk_rx;
  logic        err;

  cdriscv_e2e_gen u_gen (.data_i(data),    .addr_i(addr),
                            .be_i(be),        .chk_o(chk));
  cdriscv_e2e_chk u_chk (.data_i(data_rx), .addr_i(addr_rx),
                            .be_i(be_rx),     .chk_i(chk_rx),   .err_o(err));

  int checks = 0, errors = 0;
  int a1_trials = 0, a1_escapes = 0;   // single-bit address fault
  int a2_trials = 0, a2_escapes = 0;   // two-bit address fault
  int ar_trials = 0, ar_escapes = 0;   // wholesale wrong address
  int data_trials = 0, data_escapes = 0;
  int chk_trials  = 0, chk_escapes  = 0;
  int be1_trials = 0, be1_escapes = 0;   // single-bit be fault
  int be2_trials = 0, be2_escapes = 0;   // two-bit be fault

  task automatic drive(logic [31:0] d, logic [31:0] a);
    // a be pattern a real master can drive: word, half, or byte
    case ($urandom_range(0, 3))
      0: be = 4'b1111;
      1: be = 4'b0011 << (2 * $urandom_range(0, 1));
      2: be = 4'b0001 << $urandom_range(0, 3);
      3: be = 4'b1111;
    endcase
    data = d; addr = a; #1;
    data_rx = d; addr_rx = a; be_rx = be; chk_rx = chk; #1;
  endtask

  initial begin
    // ---- 1. clean transfers must never flag ---------------------------
    for (int k = 0; k < 20000; k++) begin
      drive($urandom, $urandom);
      checks++;
      if (err !== 1'b0) begin
        errors++;
        if (errors <= 10)
          $display("[FALSE POSITIVE] data=%08x addr=%08x chk=%02x", data, addr, chk);
      end
    end

    // ---- 2. single- and double-bit data faults ------------------------
    for (int k = 0; k < 20000; k++) begin
      int b0, b1;
      drive($urandom, $urandom);
      b0 = $urandom_range(0,31); b1 = $urandom_range(0,31);
      data_rx = data ^ (32'b1 << b0);
      if (k % 2 == 1) data_rx = data_rx ^ (32'b1 << b1);
      #1;
      if (data_rx !== data) begin
        data_trials++; checks++;
        if (err !== 1'b1) data_escapes++;
      end
    end

    // ---- 3. THE property: right data, wrong address -------------------
    // Split by fault class.  A single-bit address error is what a decode
    // fault or a stuck address line actually looks like, and the XOR fold
    // must catch every one of those.  A wholesale-random address is a
    // much weaker adversary to require detection of: any 7-bit check
    // aliases at ~1/128 on unrelated values, and no fold can beat that.
    // Reporting one merged number would hide the distinction that
    // matters for the safety argument.
    for (int k = 0; k < 20000; k++) begin              // single-bit flips
      logic [31:0] bad_addr;
      drive($urandom, $urandom);
      bad_addr = addr ^ (32'b1 << $urandom_range(0,31));
      addr_rx = bad_addr; #1;
      a1_trials++; checks++;
      if (err !== 1'b1) a1_escapes++;
    end
    for (int k = 0; k < 20000; k++) begin              // two-bit flips
      logic [31:0] bad_addr;
      int b0, b1;
      drive($urandom, $urandom);
      b0 = $urandom_range(0,31); b1 = $urandom_range(0,31);
      bad_addr = addr ^ (32'b1 << b0) ^ (32'b1 << b1);
      if (bad_addr !== addr) begin
        addr_rx = bad_addr; #1;
        a2_trials++; checks++;
        if (err !== 1'b1) a2_escapes++;
      end
    end
    for (int k = 0; k < 20000; k++) begin              // wholesale wrong
      logic [31:0] bad_addr;
      drive($urandom, $urandom);
      bad_addr = $urandom;
      if (bad_addr !== addr) begin
        addr_rx = bad_addr; #1;
        ar_trials++; checks++;
        if (err !== 1'b1) ar_escapes++;
      end
    end

    // ---- 4. corrupted byte enables ------------------------------------
    // The regime the fault campaign demanded: data and address arrive
    // intact, only the byte enables differ.  Every single-bit flip must
    // be caught (odd-weight column: the syndrome cannot be zero), and
    // every two-bit flip too (distinct columns: no pair cancels).
    for (int k = 0; k < 20000; k++) begin              // single-bit flips
      drive($urandom, $urandom);
      be_rx = be ^ (4'b1 << $urandom_range(0, 3));
      #1;
      be1_trials++; checks++;
      if (err !== 1'b1) be1_escapes++;
    end
    for (int k = 0; k < 20000; k++) begin              // two-bit flips
      logic [3:0] bad_be;
      int b0, b1;
      drive($urandom, $urandom);
      b0 = $urandom_range(0,3); b1 = $urandom_range(0,3);
      bad_be = be ^ (4'b1 << b0) ^ (4'b1 << b1);
      if (bad_be !== be) begin
        be_rx = bad_be; #1;
        be2_trials++; checks++;
        if (err !== 1'b1) be2_escapes++;
      end
    end

    // ---- 5. corrupted check bits --------------------------------------
    for (int k = 0; k < 20000; k++) begin
      drive($urandom, $urandom);
      chk_rx = chk ^ (7'b1 << $urandom_range(0,6));
      #1;
      chk_trials++; checks++;
      if (err !== 1'b1) chk_escapes++;
    end

    $display("[tb_e2e] %0d checks, %0d false positives", checks, errors);
    $display("[tb_e2e]   data faults : %0d trials, %0d escapes (%.3f %%)",
             data_trials, data_escapes, 100.0*data_escapes/data_trials);
    $display("[tb_e2e]   ADDR 1-bit  : %0d trials, %0d escapes (%.3f %%)",
             a1_trials, a1_escapes, 100.0*a1_escapes/a1_trials);
    $display("[tb_e2e]   ADDR 2-bit  : %0d trials, %0d escapes (%.3f %%)",
             a2_trials, a2_escapes, 100.0*a2_escapes/a2_trials);
    $display("[tb_e2e]   ADDR random : %0d trials, %0d escapes (%.3f %%, 7-bit floor 0.781 %%)",
             ar_trials, ar_escapes, 100.0*ar_escapes/ar_trials);
    $display("[tb_e2e]   BE 1-bit    : %0d trials, %0d escapes (%.3f %%)",
             be1_trials, be1_escapes, 100.0*be1_escapes/be1_trials);
    $display("[tb_e2e]   BE 2-bit    : %0d trials, %0d escapes (%.3f %%)",
             be2_trials, be2_escapes, 100.0*be2_escapes/be2_trials);
    $display("[tb_e2e]   check faults: %0d trials, %0d escapes (%.3f %%)",
             chk_trials, chk_escapes, 100.0*chk_escapes/chk_trials);
    // A 7-bit check aliases at ~1/128 = 0.78 %; allow 2 % headroom for
    // sampling, and require zero false positives.
    // Single-bit address faults -- the realistic decode/stuck-line case --
    // must be caught with NO escapes.  Random addresses are allowed to
    // alias at the 7-bit floor.
    if (errors == 0 && a1_escapes == 0 && a2_escapes == 0 &&
        data_escapes == 0 && be1_escapes == 0 && be2_escapes == 0 &&
        chk_escapes == 0 && (100.0*ar_escapes/ar_trials) < 2.0)
      $display("[tb_e2e] PASS");
    else
      $display("[tb_e2e] FAIL");
    $finish;
  end
endmodule
