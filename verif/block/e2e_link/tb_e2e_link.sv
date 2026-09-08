// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- E2E link endpoint block bench.
//
// block-e2e proved the generator/checker pair itself (escape statistics
// per fault class).  This bench proves the LINK built from it: a
// master-side endpoint and a slave-side endpoint joined by wires the
// bench can corrupt in flight, in front of a TCM-shaped slave model
// (grant when requested, response one cycle later).  The properties,
// in the order they are attacked:
//
//   1. clean traffic never flags -- including back-to-back accesses
//      with changing addresses, which is what catches an endpoint that
//      folds the wrong ADDRESS PHASE (live wires instead of the held
//      address of the outstanding access);
//   2. a corrupted data payload flags at the receiving end, both
//      directions (wdata on the write path, rdata on the read path);
//   3. a corrupted ADDRESS flags -- the E2E property.  The directed
//      version stores the SAME data at two addresses and corrupts the
//      address in flight: identical payload, wrong address, must fail;
//   4. corrupted BYTE ENABLES flag.  This was the documented E2E gap
//      until 2026-09-02 -- the fault campaign measured all 10 SDCs of
//      its E2E sweep to be be flips -- and the {data, addr, be} fold
//      closed it, so this phase expects DETECTION: a be corrupted on a
//      write beat flags at the slave, and one corrupted on a read
//      request flags on the response (both ends fold the be of the
//      outstanding access, so they disagree);
//   5. corrupted check bits flag, both directions;
//   6. a corrupted access-type bit flags (the slave answered a write
//      where the master issued a read, or the reverse);
//   7. errors are qualified: idle cycles never flag, even with garbage
//      driven onto the request wires, and a response from an
//      unprotected slave is never checked.
//
// Only fault classes the (39,32) Hsiao fold detects with certainty are
// injected (1- and 2-bit flips confined to one field, any check-bit
// flip), so every expectation is deterministic -- escape statistics for
// mixed multi-bit faults are block-e2e's business, not this bench's.
//
// Every cycle checks BOTH error outputs against an explicit
// expectation, so a spurious flag anywhere in the run fails the bench,
// not only in the phase that looks at it.

`timescale 1ns/1ps

module tb_e2e_link;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---- master-side request/response wires ---------------------------
  logic        m_req, m_we;
  logic [3:0]  m_be;
  logic [31:0] m_addr, m_wdata;
  logic        m_gnt;
  logic        m_rvalid;
  logic [31:0] m_rdata;

  // ---- in-flight corruption (the interconnect under attack) ---------
  logic [31:0] x_req_addr, x_req_wdata;   // request path
  logic [3:0]  x_req_be;
  logic        x_req_we;
  logic [6:0]  x_wr_chk;
  logic [31:0] x_rdata;                   // response path
  logic [6:0]  x_rd_chk;

  // ---- slave-side wires, as delivered -------------------------------
  logic        s_we;
  logic [3:0]  s_be;
  logic [31:0] s_addr, s_wdata;
  logic [6:0]  s_wr_chk;

  assign s_addr   = m_addr  ^ x_req_addr;
  assign s_wdata  = m_wdata ^ x_req_wdata;
  assign s_we     = m_we    ^ x_req_we;
  assign s_be     = m_be    ^ x_req_be;

  // ---- TCM-shaped slave model: grant on request, answer next cycle --
  logic [31:0] mem [0:255];
  logic        s_rvalid_q;
  logic [31:0] s_rdata_q;

  assign m_gnt = m_req;                    // always ready, like the TCM

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_rvalid_q <= 1'b0;
      s_rdata_q  <= 32'b0;
    end else begin
      s_rvalid_q <= m_req && m_gnt;
      if (m_req && m_gnt) begin
        if (s_we) mem[s_addr[9:2]] <= s_wdata;
        else      s_rdata_q        <= mem[s_addr[9:2]];
      end
    end
  end

  assign m_rvalid = s_rvalid_q;
  assign m_rdata  = s_rdata_q ^ x_rdata;

  // ---- DUT: the two endpoints ---------------------------------------
  logic [6:0]  wr_chk, s_rd_chk, m_rd_chk;
  logic        rd_chk_valid;
  logic        wr_err, rd_err;
  logic        prot_en;

  assign s_wr_chk = wr_chk   ^ x_wr_chk;
  assign m_rd_chk = s_rd_chk ^ x_rd_chk;

  cdriscv_e2e_link_m u_m (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .gnt_i          (m_gnt),
      .we_i           (m_we),
      .be_i           (m_be),
      .addr_i         (m_addr),
      .wdata_i        (m_wdata),
      .rvalid_i       (m_rvalid),
      .rdata_i        (m_rdata),
      .resp_prot_i    (m_rvalid && prot_en),
      .rd_chk_i       (m_rd_chk),
      .rd_chk_valid_i (rd_chk_valid),
      .wr_chk_o       (wr_chk),
      .rd_err_o       (rd_err)
  );

  cdriscv_e2e_link_s u_s (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .req_i          (m_req),
      .gnt_i          (m_gnt),
      .we_i           (s_we),
      .be_i           (s_be),
      .addr_i         (s_addr),
      .wdata_i        (s_wdata),
      .rvalid_i       (s_rvalid_q),
      .rdata_i        (s_rdata_q),
      .wr_chk_i       (s_wr_chk),
      .wr_err_o       (wr_err),
      .rd_chk_o       (s_rd_chk),
      .rd_chk_valid_o (rd_chk_valid)
  );

  // ---- per-cycle expectations ---------------------------------------
  logic exp_wr_err;                        // this cycle
  logic exp_rd_err,  exp_rd_err_nx;       // response cycle, one behind
  logic [31:0] x_rdata_nx;
  logic [6:0]  x_rd_chk_nx;
  logic prot_en_nx;

  int checks = 0, errors = 0;

  // one bench cycle: sample at the negedge, advance, shift the
  // response-phase values in, reset the request wires to idle
  task automatic tick();
    @(negedge clk);
    checks += 2;
    if (wr_err !== exp_wr_err) begin
      errors++;
      if (errors <= 10)
        $display("[MISMATCH] t=%0t wr_err=%b expected %b", $time, wr_err, exp_wr_err);
    end
    if (rd_err !== exp_rd_err) begin
      errors++;
      if (errors <= 10)
        $display("[MISMATCH] t=%0t rd_err=%b expected %b", $time, rd_err, exp_rd_err);
    end
    @(posedge clk);
    #1;
    exp_rd_err    = exp_rd_err_nx;   exp_rd_err_nx = 1'b0;
    x_rdata       = x_rdata_nx;      x_rdata_nx    = 32'b0;
    x_rd_chk      = x_rd_chk_nx;     x_rd_chk_nx   = 7'b0;
    prot_en       = prot_en_nx;      prot_en_nx    = 1'b1;
    m_req = 1'b0; m_we = 1'b0; m_be = 4'b1111;
    x_req_addr = 32'b0; x_req_wdata = 32'b0; x_req_we = 1'b0; x_wr_chk = 7'b0;
    x_req_be = 4'b0;
    exp_wr_err = 1'b0;
  endtask

  // issue one access, with the corruption and expectations for it.
  // The byte enables travel with every access: m_be is set by the
  // caller (rnd_be() for the clean helpers) and xbe corrupts them in
  // flight, the same shape as the address/data corruption.
  task automatic issue(input logic         we,
                       input logic [31:0]  a,
                       input logic [31:0]  d,
                       input logic [3:0]   be,
                       input logic [3:0]   xbe,
                       input logic [31:0]  xa,
                       input logic [31:0]  xd,
                       input logic         xw,
                       input logic [6:0]   xwc,
                       input logic [31:0]  xr,
                       input logic [6:0]   xrc,
                       input logic         prot,
                       input logic         ewr,
                       input logic         erd);
    m_req = 1'b1; m_we = we; m_be = be; m_addr = a; m_wdata = d;
    x_req_addr = xa; x_req_wdata = xd; x_req_we = xw; x_wr_chk = xwc;
    x_req_be = xbe;
    exp_wr_err = ewr;
    x_rdata_nx = xr; x_rd_chk_nx = xrc; prot_en_nx = prot;
    exp_rd_err_nx = erd;
    tick();
  endtask

  // a byte-enable pattern a real master can drive
  function automatic logic [3:0] rnd_be();
    case ($urandom_range(0, 3))
      1:       return 4'b0011 << (2 * $urandom_range(0, 1));
      2:       return 4'b0001 << $urandom_range(0, 3);
      default: return 4'b1111;
    endcase
  endfunction

  task automatic wr_clean(input logic [31:0] a, input logic [31:0] d);
    issue(1'b1, a, d, rnd_be(), 4'b0, 32'b0, 32'b0, 1'b0, 7'b0, 32'b0, 7'b0,
          1'b1, 1'b0, 1'b0);
  endtask

  task automatic rd_clean(input logic [31:0] a);
    issue(1'b0, a, $urandom, rnd_be(), 4'b0, 32'b0, 32'b0, 1'b0, 7'b0, 32'b0,
          7'b0, 1'b1, 1'b0, 1'b0);
  endtask

  // idle cycle with garbage on the request wires -- including we high
  // and a corrupted check line as seen at the slave: nothing may flag,
  // which is what pins the req/gnt qualification down
  task automatic junk();
    m_req = 1'b0; m_we = 1'b1;
    m_addr = $urandom; m_wdata = $urandom; m_be = $urandom;
    x_req_addr = $urandom | 32'b1; x_req_wdata = $urandom;
    x_req_be = 4'b1 << $urandom_range(0, 3);
    x_req_we = 1'b0; x_wr_chk = 7'b1 << $urandom_range(0, 6);
    exp_wr_err = 1'b0;
    tick();
  endtask

  function automatic logic [31:0] rnd_addr();
    return {22'b0, $urandom} & 32'h0000_03fc;   // word aligned, inside the model
  endfunction

  function automatic logic [31:0] flip32(input int nbits);
    logic [31:0] m, m2;
    m = 32'b1 << $urandom_range(0, 31);
    if (nbits == 2) begin
      m2 = m;
      while (m2 == m) m2 = 32'b1 << $urandom_range(0, 31);
      m = m | m2;
    end
    return m;
  endfunction

  initial begin
    exp_wr_err = 1'b0; exp_rd_err = 1'b0; exp_rd_err_nx = 1'b0;
    x_rdata = 32'b0; x_rdata_nx = 32'b0; x_rd_chk = 7'b0; x_rd_chk_nx = 7'b0;
    prot_en = 1'b1; prot_en_nx = 1'b1;
    m_req = 1'b0; m_we = 1'b0; m_addr = 32'b0; m_wdata = 32'b0; m_be = 4'b1111;
    x_req_addr = 32'b0; x_req_wdata = 32'b0; x_req_we = 1'b0; x_wr_chk = 7'b0;
    x_req_be = 4'b0;

    for (int i = 0; i < 256; i++) mem[i] = $urandom;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk); #1;

    // ---- 1. idle, then clean traffic: never flags -------------------
    repeat (25) tick();
    repeat (25) junk();

    for (int k = 0; k < 3000; k++) begin
      int burst;
      burst = $urandom_range(1, 8);            // back-to-back, changing address
      for (int b = 0; b < burst; b++) begin
        if ($urandom_range(0, 1)) wr_clean(rnd_addr(), $urandom);
        else                      rd_clean(rnd_addr());
        k++;
      end
      if ($urandom_range(0, 2) == 0) junk();
      else repeat ($urandom_range(0, 2)) tick();
    end

    // ---- 2. write path: corrupted wdata / addr / check bits ---------
    for (int k = 0; k < 400; k++)   // data, 1- and 2-bit
      issue(1'b1, rnd_addr(), $urandom, rnd_be(), 4'b0,
            32'b0, flip32((k % 2) + 1), 1'b0,
            7'b0, 32'b0, 7'b0, 1'b1, 1'b1, 1'b0);
    for (int k = 0; k < 400; k++)   // ADDRESS, 1- and 2-bit: same data, wrong place
      issue(1'b1, rnd_addr(), $urandom, rnd_be(), 4'b0,
            flip32((k % 2) + 1), 32'b0, 1'b0,
            7'b0, 32'b0, 7'b0, 1'b1, 1'b1, 1'b0);
    for (int k = 0; k < 200; k++)   // carried check bits
      issue(1'b1, rnd_addr(), $urandom, rnd_be(), 4'b0, 32'b0, 32'b0, 1'b0,
            7'b1 << $urandom_range(0, 6), 32'b0, 7'b0, 1'b1, 1'b1, 1'b0);
    repeat (5) tick();

    // ---- 2b. write path: corrupted BYTE ENABLES ----------------------
    // Until 2026-09-02 this was the E2E gap -- the one request wire the
    // fold excluded, and the source of every SDC in the fault
    // campaign's E2E sweep.  The {data, addr, be} fold closes it, so
    // this test expects DETECTION: 1- and 2-bit be flips, data and
    // address intact, every one must flag at the slave.
    for (int k = 0; k < 200; k++) begin
      logic [3:0] xbe;
      xbe = 4'b1 << $urandom_range(0, 3);
      if (k % 2 == 1) begin
        logic [3:0] x2;
        x2 = 4'b1 << $urandom_range(0, 3);
        while (x2 == xbe) x2 = 4'b1 << $urandom_range(0, 3);
        xbe = xbe | x2;
      end
      issue(1'b1, rnd_addr(), $urandom, rnd_be(), xbe, 32'b0, 32'b0, 1'b0,
            7'b0, 32'b0, 7'b0, 1'b1, 1'b1, 1'b0);
    end
    repeat (5) tick();

    // ---- 3. read path: wrong-address delivery ------------------------
    // The directed core of the E2E claim: the same payload stored at
    // two addresses, the request diverted from one to the other in
    // flight.  The data arriving at the master is bit-identical to what
    // it asked for; only the address is wrong; it must still flag.
    for (int k = 0; k < 100; k++) begin
      logic [31:0] a, d, xa;
      a  = rnd_addr();
      xa = 32'b1 << $urandom_range(2, 9);      // stays inside the model
      d  = $urandom;
      wr_clean(a, d);
      wr_clean(a ^ xa, d);                     // same data at both addresses
      issue(1'b0, a, 32'b0, 4'b1111, 4'b0, xa, 32'b0, 1'b0, 7'b0, 32'b0, 7'b0,
            1'b1, 1'b0, 1'b1);
    end
    for (int k = 0; k < 300; k++)   // random reads, 1- and 2-bit address faults
      issue(1'b0, rnd_addr(), 32'b0, rnd_be(), 4'b0,
            flip32((k % 2) + 1), 32'b0, 1'b0,
            7'b0, 32'b0, 7'b0, 1'b1, 1'b0, 1'b1);
    // byte enables of a READ corrupted in flight: the slave folds the
    // be it held, the master the be it drove, so the response flags.
    for (int k = 0; k < 200; k++)
      issue(1'b0, rnd_addr(), 32'b0, rnd_be(), 4'b1 << $urandom_range(0, 3),
            32'b0, 32'b0, 1'b0,
            7'b0, 32'b0, 7'b0, 1'b1, 1'b0, 1'b1);
    repeat (5) tick();

    // ---- 4. read path: corrupted rdata / check bits ------------------
    for (int k = 0; k < 400; k++)
      issue(1'b0, rnd_addr(), 32'b0, rnd_be(), 4'b0, 32'b0, 32'b0, 1'b0, 7'b0,
            flip32((k % 2) + 1), 7'b0, 1'b1, 1'b0, 1'b1);
    for (int k = 0; k < 200; k++)
      issue(1'b0, rnd_addr(), 32'b0, rnd_be(), 4'b0, 32'b0, 32'b0, 1'b0, 7'b0,
            32'b0, 7'b1 << $urandom_range(0, 6), 1'b1, 1'b0, 1'b1);
    repeat (5) tick();

    // ---- 5. access type corrupted in flight --------------------------
    for (int k = 0; k < 100; k++)   // read arrives as a write
      issue(1'b0, rnd_addr(), $urandom, rnd_be(), 4'b0, 32'b0, 32'b0, 1'b1,
            7'b0, 32'b0, 7'b0, 1'b1, 1'b0, 1'b1);
    for (int k = 0; k < 100; k++)   // write arrives as a read
      issue(1'b1, rnd_addr(), $urandom, rnd_be(), 4'b0, 32'b0, 32'b0, 1'b1,
            7'b0, 32'b0, 7'b0, 1'b1, 1'b0, 1'b1);
    repeat (5) tick();

    // ---- 6. an unprotected response is never checked -----------------
    for (int k = 0; k < 100; k++)
      issue(1'b0, rnd_addr(), 32'b0, rnd_be(), 4'b0, 32'b0, 32'b0, 1'b0, 7'b0,
            flip32(1), 7'b0, 1'b0 /* prot */, 1'b0, 1'b0 /* no flag */);
    repeat (5) tick();

    // ---- 7. idle again ----------------------------------------------
    repeat (25) tick();
    repeat (25) junk();
    repeat (5)  tick();

    $display("[tb_e2e_link] %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("[tb_e2e_link] PASS");
    else             $display("[tb_e2e_link] FAIL");
    $finish;
  end

endmodule
