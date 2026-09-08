// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- E2E protection endpoints for one bus link.
//
// cdriscv_e2e.sv provides the generator/checker pair (7 check
// bits over {data, addr, be}, each field run through the proven
// (39,32) Hsiao matrix).  This file wraps that pair into the two ENDPOINTS a
// protected master<->slave link needs, so the interconnect itself stays
// free of E2E logic and its muxing stays readable:
//
//   _m  master side: generates the write-path check bits over
//       {wdata, addr, be} as the core presents them, holds the granted
//       address and byte enables until the response returns, and
//       checks every read response from a protected slave against the
//       check bits that slave generated.
//   _s  slave side: checks every delivered write against the check
//       bits carried from the master -- a mismatch here means the
//       interconnect corrupted the payload, the address or the byte
//       enables on the way -- and generates the read-path check bits
//       over {rdata, held address and byte enables of the outstanding
//       access}.
//
// What this covers, and what it does not:
//
//   * A request or response corrupted between master and slave port --
//     data or address -- is flagged at the receiving end.  Wrong-ADDRESS
//     delivery with intact data is the case the TCM-internal ECC cannot
//     see, and is exactly what the address fold catches: the slave's
//     held address no longer matches the master's, so the read-path
//     check bits disagree.
//   * The access-type bit is cross-checked: a read that the slave
//     performed as a write (or vice versa) flags, because the slave
//     only generates read check bits for what it saw as a read.
//   * Byte enables ARE covered (closed 2026-09-02): the fold is
//     {data, addr, be}, each be bit on its own distinct odd-weight
//     Hsiao column (see cdriscv_e2e.sv).  This was the one
//     documented residual of the original {data, addr} fold, and the
//     fault campaign turned it from a paragraph into a number -- ALL
//     10 SDCs of the 400-SEU E2E sweep were be flips (10 of 32 be
//     injections).  On the read path both ends fold the byte enables
//     of the OUTSTANDING access (held at grant, like the address), so
//     a be corrupted on the request wires flags on the response too;
//     the instruction master, which drives no byte enables of its own,
//     folds the constant 4'b1111 the bus presents on its behalf (see
//     cdriscv_bus: a slave port carries be=1111 for a fetch).
//   * Sub-word writes ARE covered on the write path: the check is made
//     on the delivered request wires, before the TCM's internal
//     read-modify-write, and the full 32-bit wdata bus is compared as
//     presented.  Nothing here compares against what the TCM stores,
//     so the RMW merge cannot false-flag.
//
// A write-path mismatch does not kill the write -- gating the request
// would change bus timing -- it completes and the fault latches in the
// safety controller (FLT_E2E), which is where a detected-but-uncontained
// fault belongs.
//
// STATUS: block-verified (verif/block/e2e_link, mutation tested) and
// instantiated by the subsystem on the two TCM links.  NOT qualified
// for safety-critical use.

`default_nettype none

// ---------------------------------------------------------------------
// Master-side endpoint: one per bus master whose TCM traffic is
// protected.
// ---------------------------------------------------------------------
module cdriscv_e2e_link_m (
    input  logic        clk_i,
    input  logic        rst_ni,

    // request, as presented by the master
    input  logic        gnt_i,           // this master's grant
    input  logic        we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,

    // response, as received by the master
    input  logic        rvalid_i,
    input  logic [31:0] rdata_i,
    input  logic        resp_prot_i,     // response is from a protected slave
    input  logic [6:0]  rd_chk_i,        // that slave's read check bits
    input  logic        rd_chk_valid_i,  // ... and it saw the access as a read

    output logic [6:0]  wr_chk_o,        // write-path check bits, travels with the request
    output logic        rd_err_o
);

  // Write path: check bits over the request exactly as the core drives
  // it.  Combinational, alongside the request wires; the slave-side
  // endpoint recomputes them over what actually arrives.
  cdriscv_e2e_gen u_wr_gen (
      .data_i (wdata_i),
      .addr_i (addr_i),
      .be_i   (be_i),
      .chk_o  (wr_chk_o)
  );

  // Read path: hold the granted address (and the access type) until the
  // response returns.  One register is enough because each master has
  // at most one outstanding transaction (see cdriscv_bus).
  // pend_q keeps idle and in-reset cycles from ever flagging: a slave
  // response that this master does not have outstanding -- e.g. one
  // draining across a warm reset -- is not checked.
  logic        pend_q, we_q;
  logic [3:0]  be_q;
  logic [31:0] addr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_q <= 1'b0;
      we_q   <= 1'b0;
      be_q   <= 4'b0;
      addr_q <= 32'b0;
    end else begin
      if (gnt_i) begin
        pend_q <= 1'b1;
        we_q   <= we_i;
        be_q   <= be_i;
        addr_q <= addr_i;
      end else if (rvalid_i) begin
        pend_q <= 1'b0;
      end
    end
  end

  // The received data against the address THIS master asked for.  If
  // the interconnect served the read from the wrong address, the
  // slave's held address -- folded into rd_chk_i -- disagrees with
  // addr_q and the compare fails, identical data or not.
  logic rd_chk_err;
  cdriscv_e2e_chk u_rd_chk (
      .data_i (rdata_i),
      .addr_i (addr_q),
      .be_i   (be_q),
      .chk_i  (rd_chk_i),
      .err_o  (rd_chk_err)
  );

  // Qualified by the outstanding access and the response strobe, so an
  // idle cycle can never flag.  Two ways to fail:
  //   * a read whose payload/address check bits disagree;
  //   * an access whose TYPE the slave disagrees on (rd_chk_valid_i is
  //     the slave's "this was a read": it must equal !we_q).
  assign rd_err_o = pend_q && rvalid_i && resp_prot_i &&
                    ((!we_q && rd_chk_err) || (rd_chk_valid_i == we_q));

endmodule


// ---------------------------------------------------------------------
// Slave-side endpoint: one per protected slave (here: each TCM),
// sitting on the wires between the interconnect and the TCM wrapper.
// ---------------------------------------------------------------------
module cdriscv_e2e_link_s (
    input  logic        clk_i,
    input  logic        rst_ni,

    // request wires as delivered at the slave port (bus-side BYTE
    // address -- the same address the generator folded; the TCM slices
    // its word index internally)
    input  logic        req_i,
    input  logic        gnt_i,
    input  logic        we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,

    // response wires at the slave port
    input  logic        rvalid_i,
    input  logic [31:0] rdata_i,

    input  logic [6:0]  wr_chk_i,        // check bits carried from the writing master

    output logic        wr_err_o,        // delivered write disagrees with wr_chk_i
    output logic [6:0]  rd_chk_o,        // read check bits, travel with the response
    output logic        rd_chk_valid_o   // response is a read this endpoint covered
);

  // Write path: recompute over what actually arrived and compare with
  // what the master computed.  A mismatch means the interconnect
  // corrupted the data or delivered to the wrong address.  The write
  // still completes -- killing it here would change bus timing -- and
  // the error latches in the safety controller instead.
  logic wr_chk_err;
  cdriscv_e2e_chk u_wr_chk (
      .data_i (wdata_i),
      .addr_i (addr_i),
      .be_i   (be_i),
      .chk_i  (wr_chk_i),
      .err_o  (wr_chk_err)
  );

  assign wr_err_o = req_i && gnt_i && we_i && wr_chk_err;

  // Read path: the TCM answers one cycle after acceptance, so the
  // address of the outstanding access is held here and folded into the
  // response's check bits.  Folding the address the SLAVE accepted --
  // not the master's -- is the point: it is what lets the master-side
  // checker see a wrong-address delivery.
  logic        we_q;
  logic [3:0]  be_q;
  logic [31:0] addr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      we_q   <= 1'b0;
      be_q   <= 4'b0;
      addr_q <= 32'b0;
    end else if (req_i && gnt_i) begin
      we_q   <= we_i;
      be_q   <= be_i;
      addr_q <= addr_i;
    end
  end

  cdriscv_e2e_gen u_rd_gen (
      .data_i (rdata_i),
      .addr_i (addr_q),
      .be_i   (be_q),
      .chk_o  (rd_chk_o)
  );

  // Only a read response carries meaningful rdata; a write's response
  // strobe reuses stale decoder output (see cdriscv_tcm) and
  // must not be checked.  The master-side endpoint cross-checks this
  // flag against its own record of the access type.
  assign rd_chk_valid_o = rvalid_i && !we_q;

endmodule
