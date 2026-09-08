// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// Block bench for cdriscv_qspi_boot: the loader against the
// behavioural NOR flash model (verif/models/cdriscv_spi_norflash_model.sv) and
// a TCM-shaped write monitor on its bus-master port.
//
// What is checked, scenario by scenario (the DUT is reset between
// scenarios -- the sticky bits are per cold boot):
//
//   1  1-bit image, both segments      word-exact load against the
//                                      source image, write count, all
//                                      writes full-word, payload read
//                                      with 03h (flag clear), boot_done
//                                      rises exactly once and is sticky
//   2  quad image                      same image content via EBh --
//                                      the switch happens ONLY because
//                                      the flag says so, and the data
//                                      still matches word for word
//   3  seg1 absent (len 0)             seg0 loads, nothing touches the
//                                      D-TCM window
//   4  corrupt CRC                     exactly RetryMax retries
//                                      (RetryMax+1 attempts, counted at
//                                      CS#), then boot_fault sticky,
//                                      boot_done NEVER rises
//   5  bad magic                       fault after the retries with
//                                      ZERO bus writes
//   6  wild segment (overruns I-TCM)   fault with ZERO bus writes
//   7  wild segment (outside any TCM)  fault with ZERO bus writes
//   8  flash/bus timeout               the monitor withholds gnt; the
//                                      progress watchdog must fault
//                                      after the retries, not hang
//   9  bus error response              slave err on a beat is a failed
//                                      attempt, then a fault
//  10  SclkDiv=4 divider               a second DUT built with /4 loads
//                                      the scenario-1 image correctly
//
// The expected words are recorded while the bench BUILDS the flash
// content, so the comparison is against the source image, not against
// anything the loader computed.  The bench's CRC helper is the same
// published algorithm the RTL implements; its independent cross-check
// is scripts/mkbootimg.py (python binascii.crc32) driving the same
// loader in `make bootsim`.

`default_nettype none
`timescale 1ns/1ps

module tb_qspi_boot;

  localparam int unsigned RetryMax   = 3;
  localparam int unsigned TimeoutCyc = 200;
  localparam logic [31:0] ItcmBase   = 32'h0000_0000;
  localparam int unsigned ItcmBytes  = 16384;
  localparam logic [31:0] DtcmBase   = 32'h1000_0000;
  localparam int unsigned DtcmBytes  = 16384;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst_n = 1'b0;

  // ---- DUT --------------------------------------------------------
  logic        mreq, mgnt, mrvalid, mwe, merr;
  logic [3:0]  mbe;
  logic [31:0] maddr, mwdata;
  logic        sclk, cs_n;
  logic [3:0]  io_o, io_oe;
  wire  [3:0]  qio;
  logic        boot_done, boot_fault;

  cdriscv_qspi_boot #(
      .SclkDiv       (2),
      .RetryMax      (RetryMax),
      .TimeoutCycles (TimeoutCyc),
      .QuadDummy     (4),
      .ItcmBase      (ItcmBase),
      .ItcmBytes     (ItcmBytes),
      .DtcmBase      (DtcmBase),
      .DtcmBytes     (DtcmBytes)
  ) dut (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .hold_i       (1'b0),
      .mst_req_o    (mreq),
      .mst_gnt_i    (mgnt),
      .mst_rvalid_i (mrvalid),
      .mst_we_o     (mwe),
      .mst_be_o     (mbe),
      .mst_addr_o   (maddr),
      .mst_wdata_o  (mwdata),
      .mst_err_i    (merr),
      .qspi_sclk_o  (sclk),
      .qspi_cs_no   (cs_n),
      .qspi_io_i    (qio),
      .qspi_io_o    (io_o),
      .qspi_io_oe_o (io_oe),
      .boot_done_o  (boot_done),
      .boot_fault_o (boot_fault)
  );

  // pad-style wiring: the loader drives per its oe, the flash per its own
  for (genvar b = 0; b < 4; b++) begin : g_pad
    assign qio[b] = io_oe[b] ? io_o[b] : 1'bz;
  end

  cdriscv_spi_norflash_model #(.MemBytes(65536), .DummyCycles(4)) u_flash (
      .sclk_i (sclk),
      .cs_ni  (cs_n),
      .io     (qio)
  );

  // ---- TCM-shaped write monitor ------------------------------------
  // gnt combinational (like the TCM when idle), rvalid one cycle later
  // -- never in the same cycle as gnt.  Scenario knobs: stall_gnt
  // withholds every grant, err_resp answers every beat with err.
  logic stall_gnt, err_resp;

  logic        rv_q, err_q;
  assign mgnt    = mreq && !stall_gnt;
  assign mrvalid = rv_q;
  assign merr    = err_q;

  logic [31:0] got_itcm [0:ItcmBytes/4-1];
  logic        got_itcm_v [0:ItcmBytes/4-1];
  logic [31:0] got_dtcm [0:DtcmBytes/4-1];
  logic        got_dtcm_v [0:DtcmBytes/4-1];

  int unsigned wr_count;      // accepted write beats
  int unsigned bad_wr_count;  // writes that were not full-word or out of range

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rv_q  <= 1'b0;
      err_q <= 1'b0;
    end else begin
      rv_q  <= mreq && mgnt;
      err_q <= (mreq && mgnt) && err_resp;
      if (mreq && mgnt) begin
        wr_count <= wr_count + 1;
        if (!mwe || mbe != 4'hf) bad_wr_count <= bad_wr_count + 1;
        else if (maddr >= ItcmBase && maddr < ItcmBase + ItcmBytes) begin
          got_itcm[(maddr - ItcmBase) >> 2]   <= mwdata;
          got_itcm_v[(maddr - ItcmBase) >> 2] <= 1'b1;
        end else if (maddr >= DtcmBase && maddr < DtcmBase + DtcmBytes) begin
          got_dtcm[(maddr - DtcmBase) >> 2]   <= mwdata;
          got_dtcm_v[(maddr - DtcmBase) >> 2] <= 1'b1;
        end else begin
          bad_wr_count <= bad_wr_count + 1;
        end
      end
    end
  end

  // ---- event counters ---------------------------------------------
  int unsigned cs_falls;      // command sessions
  int unsigned done_rises;

  always @(negedge cs_n) if (rst_n) cs_falls++;
  always @(posedge boot_done) done_rises++;

  // ---- second DUT: the /4 divider ---------------------------------
  logic        m4req, m4gnt, m4rvalid, m4we, rv4_q;
  logic [3:0]  m4be;
  logic [31:0] m4addr, m4wdata;
  logic        sclk4, cs_n4;
  logic [3:0]  io4_o, io4_oe;
  wire  [3:0]  qio4;
  logic        done4, fault4;
  logic        rst4_n = 1'b0;

  cdriscv_qspi_boot #(
      .SclkDiv       (4),
      .RetryMax      (RetryMax),
      .TimeoutCycles (TimeoutCyc),
      .QuadDummy     (4),
      .ItcmBase      (ItcmBase),
      .ItcmBytes     (ItcmBytes),
      .DtcmBase      (DtcmBase),
      .DtcmBytes     (DtcmBytes)
  ) dut4 (
      .clk_i        (clk),
      .rst_ni       (rst4_n),
      .hold_i       (1'b0),
      .mst_req_o    (m4req),
      .mst_gnt_i    (m4gnt),
      .mst_rvalid_i (m4rvalid),
      .mst_we_o     (m4we),
      .mst_be_o     (m4be),
      .mst_addr_o   (m4addr),
      .mst_wdata_o  (m4wdata),
      .mst_err_i    (1'b0),
      .qspi_sclk_o  (sclk4),
      .qspi_cs_no   (cs_n4),
      .qspi_io_i    (qio4),
      .qspi_io_o    (io4_o),
      .qspi_io_oe_o (io4_oe),
      .boot_done_o  (done4),
      .boot_fault_o (fault4)
  );

  for (genvar b = 0; b < 4; b++) begin : g_pad4
    assign qio4[b] = io4_oe[b] ? io4_o[b] : 1'bz;
  end

  cdriscv_spi_norflash_model #(.MemBytes(65536), .DummyCycles(4)) u_flash4 (
      .sclk_i (sclk4),
      .cs_ni  (cs_n4),
      .io     (qio4)
  );

  logic [31:0] got4_itcm [0:ItcmBytes/4-1];
  logic [31:0] got4_dtcm [0:DtcmBytes/4-1];

  assign m4gnt    = m4req;
  assign m4rvalid = rv4_q;
  always_ff @(posedge clk or negedge rst4_n) begin
    if (!rst4_n) rv4_q <= 1'b0;
    else begin
      rv4_q <= m4req && m4gnt;
      if (m4req && m4gnt) begin
        if (m4addr < ItcmBase + ItcmBytes) got4_itcm[(m4addr - ItcmBase) >> 2] <= m4wdata;
        else                               got4_dtcm[(m4addr - DtcmBase) >> 2] <= m4wdata;
      end
    end
  end

  // ---- scoreboard --------------------------------------------------
  int errors = 0;
  int checks = 0;

  task automatic check(input string what, input logic [31:0] got,
                       input logic [31:0] exp);
    checks++;
    if (got !== exp) begin
      errors++;
      $display("FAIL %-46s got %08x exp %08x", what, got, exp);
    end
  endtask

  // ---- image builder -----------------------------------------------
  // Writes header + payload into a flash array AND records the expected
  // words, so the load comparison is against the source of the image.
  logic [31:0] exp_itcm [0:ItcmBytes/4-1];
  logic        exp_itcm_v [0:ItcmBytes/4-1];
  logic [31:0] exp_dtcm [0:DtcmBytes/4-1];
  logic        exp_dtcm_v [0:DtcmBytes/4-1];
  int unsigned exp_words;

  function automatic logic [31:0] crc32_byte(input logic [31:0] c,
                                             input logic [7:0]  b);
    logic [31:0] r;
    r = c ^ {24'h0, b};
    for (int i = 0; i < 8; i++) r = (r >> 1) ^ (r[0] ? 32'hEDB8_8320 : 32'h0);
    return r;
  endfunction

  task automatic fl_word(input int flash, input int a, input logic [31:0] w);
    if (flash == 0) begin
      u_flash.mem[a+0] = w[7:0];   u_flash.mem[a+1] = w[15:8];
      u_flash.mem[a+2] = w[23:16]; u_flash.mem[a+3] = w[31:24];
    end else begin
      u_flash4.mem[a+0] = w[7:0];   u_flash4.mem[a+1] = w[15:8];
      u_flash4.mem[a+2] = w[23:16]; u_flash4.mem[a+3] = w[31:24];
    end
  endtask

  // seed-driven pattern word: distinct per address and per scenario
  function automatic logic [31:0] pat(input logic [31:0] seed, input int i);
    return seed ^ (32'(i) * 32'h9E37_79B9) ^ {12'h0, 20'(i)};
  endfunction

  task automatic build_image(input int flash,
                             input bit quad,
                             input logic [31:0] d0, input logic [31:0] l0,
                             input logic [31:0] d1, input logic [31:0] l1,
                             input logic [31:0] seed,
                             input logic [31:0] magic,
                             input logic [31:0] crc_xor);
    logic [31:0] crc, w;
    int          off;
    crc = 32'hFFFF_FFFF;
    off = 28;
    exp_words = 0;
    for (int i = 0; i < ItcmBytes/4; i++) exp_itcm_v[i] = 1'b0;
    for (int i = 0; i < DtcmBytes/4; i++) exp_dtcm_v[i] = 1'b0;
    // seg0 payload
    for (int i = 0; i < int'(l0)/4; i++) begin
      w = pat(seed, i);
      fl_word(flash, off, w);
      off += 4;
      crc = crc32_byte(crc, w[7:0]);   crc = crc32_byte(crc, w[15:8]);
      crc = crc32_byte(crc, w[23:16]); crc = crc32_byte(crc, w[31:24]);
      if (d0 + 32'(4*i) >= ItcmBase && d0 + 32'(4*i) < ItcmBase + ItcmBytes) begin
        exp_itcm[(d0 - ItcmBase + 32'(4*i)) >> 2]   = w;
        exp_itcm_v[(d0 - ItcmBase + 32'(4*i)) >> 2] = 1'b1;
        exp_words++;
      end
    end
    // seg1 payload
    for (int i = 0; i < int'(l1)/4; i++) begin
      w = pat(~seed, i);
      fl_word(flash, off, w);
      off += 4;
      crc = crc32_byte(crc, w[7:0]);   crc = crc32_byte(crc, w[15:8]);
      crc = crc32_byte(crc, w[23:16]); crc = crc32_byte(crc, w[31:24]);
      exp_dtcm[(d1 - DtcmBase + 32'(4*i)) >> 2]   = w;
      exp_dtcm_v[(d1 - DtcmBase + 32'(4*i)) >> 2] = 1'b1;
      exp_words++;
    end
    // header
    fl_word(flash, 0,  magic);
    fl_word(flash, 4,  {31'b0, quad});
    fl_word(flash, 8,  d0);
    fl_word(flash, 12, l0);
    fl_word(flash, 16, d1);
    fl_word(flash, 20, l1);
    fl_word(flash, 24, (crc ^ 32'hFFFF_FFFF) ^ crc_xor);
  endtask

  // ---- scenario driver ---------------------------------------------
  task automatic reset_dut();
    rst_n = 1'b0;
    stall_gnt = 1'b0;
    err_resp  = 1'b0;
    repeat (5) @(posedge clk);
    wr_count = 0; bad_wr_count = 0; cs_falls = 0; done_rises = 0;
    for (int i = 0; i < ItcmBytes/4; i++) got_itcm_v[i] = 1'b0;
    for (int i = 0; i < DtcmBytes/4; i++) got_dtcm_v[i] = 1'b0;
    rst_n = 1'b1;
    @(posedge clk);
  endtask

  task automatic wait_verdict(input int max_cycles);
    int n;
    n = 0;
    while (!boot_done && !boot_fault && n < max_cycles) begin
      @(posedge clk); n++;
    end
    // settle: retries after a first fault must not still be running
    repeat (50) @(posedge clk);
  endtask

  task automatic check_loaded(input string tag);
    int mism;
    mism = 0;
    for (int i = 0; i < ItcmBytes/4; i++) begin
      if (exp_itcm_v[i] !== got_itcm_v[i]) mism++;
      else if (exp_itcm_v[i] && (exp_itcm[i] !== got_itcm[i])) mism++;
    end
    for (int i = 0; i < DtcmBytes/4; i++) begin
      if (exp_dtcm_v[i] !== got_dtcm_v[i]) mism++;
      else if (exp_dtcm_v[i] && (exp_dtcm[i] !== got_dtcm[i])) mism++;
    end
    check({tag, ": word-exact load (mismatches)"}, 32'(mism), 32'd0);
    check({tag, ": write count"}, wr_count, exp_words);
    check({tag, ": all writes full-word, in range"}, bad_wr_count, 32'd0);
  endtask

  // ------------------------------------------------------------------
  initial begin : main
    logic [31:0] v;

    $display("tb_qspi_boot: loader block bench");

    // ---- 1: 1-bit image, both segments ---------------------------
    build_image(0, 1'b0, 32'h0000_0100, 32'd256, 32'h1000_0040, 32'd64,
                32'h1111_2222, 32'hCD10_B007, 32'h0);
    reset_dut();
    wait_verdict(40000);
    check("s1: boot_done", {31'b0, boot_done}, 32'h1);
    check("s1: no boot_fault", {31'b0, boot_fault}, 32'h0);
    check_loaded("s1");
    check("s1: released exactly once", done_rises, 32'd1);
    check("s1: two commands (header+payload)", cs_falls, 32'd2);
    check("s1: payload used 03h (flag clear)", {24'b0, u_flash.last_opcode_q}, 32'h03);
    check("s1: quad never used", {31'b0, u_flash.quad_used_q}, 32'h0);
    v = {31'b0, boot_done};
    repeat (500) @(posedge clk);
    check("s1: boot_done sticky", {31'b0, boot_done}, v);
    check("s1: still exactly one release", done_rises, 32'd1);

    // ---- 2: quad image -------------------------------------------
    build_image(0, 1'b1, 32'h0000_0000, 32'd128, 32'h1000_0000, 32'd32,
                32'h3333_4444, 32'hCD10_B007, 32'h0);
    reset_dut();
    wait_verdict(40000);
    check("s2: boot_done", {31'b0, boot_done}, 32'h1);
    check_loaded("s2");
    check("s2: payload used EBh (flag set)", {24'b0, u_flash.last_opcode_q}, 32'hEB);

    // ---- 3: seg1 absent ------------------------------------------
    build_image(0, 1'b0, 32'h0000_0000, 32'd96, 32'h0, 32'd0,
                32'h5555_6666, 32'hCD10_B007, 32'h0);
    reset_dut();
    wait_verdict(40000);
    check("s3: boot_done", {31'b0, boot_done}, 32'h1);
    check_loaded("s3");
    begin
      int dt;
      dt = 0;
      for (int i = 0; i < DtcmBytes/4; i++) if (got_dtcm_v[i]) dt++;
      check("s3: nothing written to D-TCM", 32'(dt), 32'd0);
    end

    // ---- 4: corrupt CRC ------------------------------------------
    build_image(0, 1'b0, 32'h0000_0000, 32'd64, 32'h1000_0000, 32'd16,
                32'h7777_8888, 32'hCD10_B007, 32'h0000_0001);
    reset_dut();
    wait_verdict(200000);
    check("s4: boot_fault", {31'b0, boot_fault}, 32'h1);
    check("s4: boot_done never rose", done_rises, 32'd0);
    check("s4: exactly RetryMax retries (CS sessions)",
          cs_falls, 32'(2 * (RetryMax + 1)));
    repeat (1000) @(posedge clk);
    check("s4: boot_fault sticky", {31'b0, boot_fault}, 32'h1);
    check("s4: no release after the fault", done_rises, 32'd0);

    // ---- 5: bad magic --------------------------------------------
    // The wrong magic used here is cdriscv-32s-20's (32'hCD20_B007):
    // an image packed for the other variant must not boot this one.
    build_image(0, 1'b0, 32'h0000_0000, 32'd64, 32'h0, 32'd0,
                32'h9999_aaaa, 32'hCD20_B007, 32'h0);
    reset_dut();
    wait_verdict(200000);
    check("s5: boot_fault", {31'b0, boot_fault}, 32'h1);
    check("s5: header-only attempts (CS sessions)",
          cs_falls, 32'(RetryMax + 1));
    check("s5: ZERO bus writes", wr_count, 32'd0);

    // ---- 6: wild segment, overruns the I-TCM ---------------------
    build_image(0, 1'b0, 32'h0000_3F00, 32'd512, 32'h0, 32'd0,
                32'hbbbb_cccc, 32'hCD10_B007, 32'h0);
    reset_dut();
    wait_verdict(200000);
    check("s6: boot_fault", {31'b0, boot_fault}, 32'h1);
    check("s6: ZERO bus writes", wr_count, 32'd0);

    // ---- 7: wild segment, outside any TCM ------------------------
    build_image(0, 1'b0, 32'h2000_0000, 32'd64, 32'h0, 32'd0,
                32'hdddd_eeee, 32'hCD10_B007, 32'h0);
    reset_dut();
    wait_verdict(200000);
    check("s7: boot_fault", {31'b0, boot_fault}, 32'h1);
    check("s7: ZERO bus writes", wr_count, 32'd0);

    // ---- 8: bus/flash timeout ------------------------------------
    build_image(0, 1'b0, 32'h0000_0000, 32'd64, 32'h0, 32'd0,
                32'h1234_5678, 32'hCD10_B007, 32'h0);
    reset_dut();
    stall_gnt = 1'b1;
    wait_verdict(400000);
    check("s8: timeout faults", {31'b0, boot_fault}, 32'h1);
    check("s8: boot_done never rose", done_rises, 32'd0);
    check("s8: attempts were bounded (CS sessions)",
          cs_falls, 32'(2 * (RetryMax + 1)));

    // ---- 9: bus error response -----------------------------------
    build_image(0, 1'b0, 32'h0000_0000, 32'd64, 32'h0, 32'd0,
                32'h0bad_0bad, 32'hCD10_B007, 32'h0);
    reset_dut();
    err_resp = 1'b1;
    wait_verdict(200000);
    check("s9: bus error faults", {31'b0, boot_fault}, 32'h1);
    check("s9: boot_done never rose", done_rises, 32'd0);

    // ---- 10: SclkDiv=4 DUT ---------------------------------------
    build_image(1, 1'b0, 32'h0000_0100, 32'd256, 32'h1000_0040, 32'd64,
                32'h1111_2222, 32'hCD10_B007, 32'h0);
    rst4_n = 1'b1;
    begin
      int n;
      n = 0;
      while (!done4 && !fault4 && n < 80000) begin @(posedge clk); n++; end
    end
    check("s10: /4 divider boot_done", {31'b0, done4}, 32'h1);
    check("s10: /4 no fault", {31'b0, fault4}, 32'h0);
    begin
      int mism;
      mism = 0;
      for (int i = 0; i < 64; i++)
        if (got4_itcm[(32'h100 >> 2) + i] !== pat(32'h1111_2222, i)) mism++;
      for (int i = 0; i < 16; i++)
        if (got4_dtcm[(32'h40 >> 2) + i] !== pat(~32'h1111_2222, i)) mism++;
      check("s10: /4 word-exact load", 32'(mism), 32'd0);
    end

    // ---- verdict --------------------------------------------------
    if (errors == 0) $display("tb_qspi_boot: PASS (%0d checks)", checks);
    else             $display("tb_qspi_boot: FAIL (%0d of %0d checks)", errors, checks);
    $finish;
  end

  // global watchdog: a hung loader must fail loudly, not run for ever
  initial begin
    #200ms;
    $display("tb_qspi_boot: FAIL (global timeout)");
    $finish;
  end

endmodule

`default_nettype wire
