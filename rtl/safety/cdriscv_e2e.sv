// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- end-to-end (E2E) bus protection.
//
// The TCMs in variant 1 are ECC-protected *inside* the memory: a word
// is encoded on the way in and checked on the way out, so a fault in
// the array is caught.  What is NOT covered is everything between the
// core and the array -- address decode, bus muxing, the interconnect
// itself.  A fault there delivers the wrong word, correctly ECC'd, and
// nothing notices.
//
// E2E closes that by carrying the check bits with the payload from
// producer to consumer, so the consumer verifies what it received
// rather than trusting that the path was sound.  This module is the
// generator/checker pair; the bus carries e2e_word_t instead of raw
// data.
//
// Address is folded into the check: the same data at the wrong address
// must NOT pass.  That is what makes this end-to-end rather than merely
// a second data ECC -- a decode fault changes the address, which
// changes the expected syndrome, which the consumer sees as an error.
//
// Byte enables are folded in too (added 2026-09-02).  The fault
// injection campaign measured why: of 400 systematic SEUs on the
// protected links, every silent data corruption -- all 10 of them --
// was a byte-enable flip (10 of the 32 be injections), the one request
// wire the original {data, addr} fold excluded.  A be corrupted in
// flight changes which bytes a sub-word write commits, with the data
// and address arriving intact, so no other mechanism can see it.
//
// Reuses the (39,32) Hsiao code the TCMs already use, so the same
// generator, the same proof and the same block-level bench apply.
//
// STATUS: block-verified (doc/variant_status.md, section 2) and
// instantiated by the subsystem (via cdriscv_e2e_link).
// This repository's own O1-O7 and O9
// gates are met on this RTL; O8 (gate level) is open -- see README.md.
// NOT qualified for safety-critical use.

`default_nettype none

module cdriscv_e2e_gen (
    input  logic [31:0] data_i,
    input  logic [31:0] addr_i,
    input  logic [3:0]  be_i,
    output logic [6:0]  chk_o
);
  logic [6:0] data_chk;
  logic [31:0] cw_unused;
  cdriscv_ecc_enc u_enc (.data_i(data_i), .cw_o({data_chk, cw_unused}));

  // Fold the address in: a transfer that arrives at the wrong address
  // carries a syndrome that no longer matches.
  //
  // The obvious fold -- XOR the address in 7-bit slices -- is WRONG, and
  // measurably so.  It maps address bits i and i+7 onto the same check
  // bit, so flipping both cancels exactly; tb_v2_e2e measured 11.1 % of
  // two-bit address faults escaping.  Two stuck address lines, or an MBU
  // in an address register, are precisely that case.
  //
  // The cure is to give every address bit a DISTINCT 7-bit column, so no
  // pair can cancel.  The (39,32) Hsiao matrix already has that property
  // by construction -- its columns are distinct and odd-weight -- and it
  // is already proven, so the address runs through the same encoder
  // rather than through a hand-rolled fold.
  logic [6:0]  addr_chk;
  logic [31:0] addr_cw_unused;
  cdriscv_ecc_enc u_addr_enc (.data_i(addr_i), .cw_o({addr_chk, addr_cw_unused}));

  // The byte enables get the same treatment, for the same reason: the
  // four be bits run as {28'h0, be} through the same proven Hsiao
  // encoder, so each be bit lands on a distinct odd-weight column of
  // the same matrix.  Odd weight means a single be flip always changes
  // the check bits; distinct columns mean no two be flips can cancel
  // each other -- exactly the no-two-bits-cancel property the address
  // fold has, and NOT the property a naive slice-XOR would have given.
  // (The zero padding costs nothing: constant inputs fold away in
  // synthesis, leaving four XOR taps.)
  //
  // Fault classes that pair a be bit with the SAME-index data or
  // address bit share a column across fields and would cancel; the
  // pre-existing data^addr fold has the identical cross-field
  // characteristic and it is accepted for the same reason -- those
  // are physically unrelated wires in different request phases, not a
  // plausible common-cause pair, and the block bench (tb_e2e) injects
  // faults confined to one field, matching the fault model.
  logic [6:0]  be_chk;
  logic [31:0] be_cw_unused;
  cdriscv_ecc_enc u_be_enc (.data_i({28'h0, be_i}),
                                   .cw_o({be_chk, be_cw_unused}));

  assign chk_o = data_chk ^ addr_chk ^ be_chk;
endmodule


module cdriscv_e2e_chk (
    input  logic [31:0] data_i,
    input  logic [31:0] addr_i,
    input  logic [3:0]  be_i,
    input  logic [6:0]  chk_i,
    output logic        err_o
);
  logic [6:0] expect_chk;
  cdriscv_e2e_gen u_gen (.data_i(data_i), .addr_i(addr_i), .be_i(be_i),
                                .chk_o(expect_chk));
  assign err_o = (expect_chk != chk_i);
endmodule
