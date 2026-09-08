// SPDX-FileCopyrightText: 2026 ChipDesign B.V.
// SPDX-License-Identifier: Apache-2.0
//
// cdriscv-32s-10 -- QSPI boot system bench (`make bootsim`).
//
// The one bench where BootEnable=1: the subsystem comes out of reset
// with EMPTY TCMs and an SPI NOR flash model on its QSPI port, holding
// a real program image packed by scripts/mkbootimg.py from the smoke
// program.  The test passes ONLY if the core boots through the full
// QSPI path -- header, (optionally quad) payload, CRC -- and the
// program then runs to its normal PASS via the exit register, exactly
// as it does in tb_cdriscv_subsys with a preloaded TCM.
//
//   +FLASH_HEX=<file>  byte-per-line flash image (mkbootimg.py output)
//   +MAX_CYCLES=<n>    give up after n cycles (default 600000)
//   +TRACE=1           print every retired instruction
//
// Additional cross-checks: the core must not retire a single
// instruction before boot_done, boot_fault must never rise, and the
// bench reports the cycle boot_done rose for the record.
//
// The four QSPI data lines are wired as at chip level: the loader
// drives a line only while its io_oe bit is set, the flash drives
// during data phases, and the bench adds nothing else -- a fight over
// the bus would show as X at the receiver, not as a lucky pass.

`default_nettype none
`timescale 1ns/1ps

module tb_cdriscv_boot;

  localparam time ClkPeriod    = 10ns;    // 100 MHz system clock
  localparam time RefClkPeriod = 1000ns;  // 1 MHz reference clock

  logic clk, rst_n;
  logic ref_clk, ref_rst_n;

  initial begin
    clk = 1'b0;
    forever #(ClkPeriod/2) clk = ~clk;
  end

  initial begin
    ref_clk = 1'b0;
    forever #(RefClkPeriod/2) ref_clk = ~ref_clk;
  end

  initial begin
    rst_n     = 1'b0;
    ref_rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ref_clk);
    ref_rst_n = 1'b1;
  end

  // ------------------------------------------------------------------
  // Device under test -- the ONE bench that overrides BootEnable to 1
  // (it defaults to 0 in cdriscv-32s-10, the signed-off configuration;
  // a chip build that boots from flash is what this models)
  // ------------------------------------------------------------------
  logic        fetch_enable;
  logic        err_pin, reset_req, fault_any;

  logic        adc_start;
  logic [2:0]  adc_ch;
  logic        adc_valid;
  logic [11:0] adc_data;

  logic        ext_psel, ext_penable, ext_pwrite, ext_pready;
  logic [11:0] ext_paddr;
  logic [31:0] ext_pwdata;

  logic        core_sleep, retire_valid;
  logic        corrupt_mode;
  int          retire_count;
  logic [31:0] retire_pc, retire_instr;

  logic        qspi_sclk, qspi_cs_n;
  logic [3:0]  qspi_io_o, qspi_io_oe;
  wire  [3:0]  qspi_io;

  cdriscv_subsys #(
      .Lockstep   (1'b1),
      .ItcmWords  (4096),
      .DtcmWords  (4096),
      .MbistAuto  (1'b0),
      .BootEnable (1'b1)      // the point of this bench
  ) dut (
      .clk_i          (clk),
      .rst_ni         (rst_n),
      .ref_clk_i      (ref_clk),
      .ref_rst_ni     (ref_rst_n),
      .boot_addr_i    (32'h0000_0000),
      .fetch_enable_i (fetch_enable),
      .irq_i          ('0),
      .fault_ext_i    ('0),
      .err_pin_o      (err_pin),
      .reset_req_o    (reset_req),
      .fault_any_o    (fault_any),
      .adc_start_o    (adc_start),
      .adc_ch_o       (adc_ch),
      .adc_valid_i    (adc_valid),
      .adc_data_i     (adc_data),
      .dac_data_o     (),
      .dac_we_o       (),
      .atest_en_o     (),
      .atest_sel_o    (),
      .ana_flag_i     ('0),
      .ext_psel_o     (ext_psel),
      .ext_penable_o  (ext_penable),
      .ext_paddr_o    (ext_paddr),
      .ext_pwrite_o   (ext_pwrite),
      .ext_pwdata_o   (ext_pwdata),
      .ext_pstrb_o    (),
      .ext_prdata_i   (32'h0),
      .ext_pready_i   (ext_pready),
      .ext_pslverr_i  (1'b0),
      .core_sleep_o   (core_sleep),
      .retire_valid_o (retire_valid),
      .retire_pc_o    (retire_pc),
      .retire_instr_o (retire_instr),
      .qspi_sclk_o    (qspi_sclk),
      .qspi_cs_no     (qspi_cs_n),
      .qspi_io_i      (qspi_io),
      .qspi_io_o      (qspi_io_o),
      .qspi_io_oe_o   (qspi_io_oe)
  );

  // ---- QSPI pad wiring + flash --------------------------------------
  for (genvar b = 0; b < 4; b++) begin : g_pad
    assign qspi_io[b] = qspi_io_oe[b] ? qspi_io_o[b] : 1'bz;
  end

  cdriscv_spi_norflash_model #(.MemBytes(65536), .DummyCycles(4)) u_flash (
      .sclk_i (qspi_sclk),
      .cs_ni  (qspi_cs_n),
      .io     (qspi_io)
  );

  // ------------------------------------------------------------------
  // ADC model (the smoke program runs an AMS sequence), as in
  // tb_cdriscv_subsys
  // ------------------------------------------------------------------
  int unsigned adc_delay;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      adc_valid <= 1'b0;
      adc_data  <= 12'b0;
      adc_delay <= 0;
    end else begin
      adc_valid <= 1'b0;
      if (adc_start) begin
        adc_delay <= 20;
      end else if (adc_delay > 1) begin
        adc_delay <= adc_delay - 1;
      end else if (adc_delay == 1) begin
        adc_delay <= 0;
        adc_valid <= 1'b1;
        adc_data  <= 12'h100 + {9'b0, adc_ch};
      end
    end
  end

  // ------------------------------------------------------------------
  // Exit register (SoC expansion slot), as in tb_cdriscv_subsys
  // ------------------------------------------------------------------
  logic        exit_seen;
  logic [31:0] exit_code;

  assign ext_pready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      exit_seen <= 1'b0;
      exit_code <= 32'b0;
    end else if (ext_psel && ext_penable && ext_pwrite && (ext_paddr[7:0] == 8'h00)) begin
      exit_seen <= 1'b1;
      exit_code <= ext_pwdata;
    end
  end

  // ------------------------------------------------------------------
  // Stimulus and checks
  // ------------------------------------------------------------------
  string       flash_hex;
  int unsigned max_cycles, cycle, boot_cycle;
  bit          trace_en;
  int          errors;

  wire boot_done  = dut.g_boot.u_boot.boot_done_o;
  wire boot_fault = dut.g_boot.u_boot.boot_fault_o;

  initial begin
    fetch_enable = 1'b0;
    errors       = 0;
    boot_cycle   = 0;

    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 600000;
    trace_en = $test$plusargs("TRACE");

    corrupt_mode = $test$plusargs("CORRUPT");
    if ($value$plusargs("FLASH_HEX=%s", flash_hex)) begin
      $display("[TB] loading flash from %s", flash_hex);
      $readmemh(flash_hex, u_flash.mem);
      if (corrupt_mode) begin
        // Flip one bit in the first payload byte (offset 0x1c).  The
        // header stays valid, so the loader reads the full image and
        // must fail the CRC -- exercising retry, then boot_fault into
        // the safety controller's dedicated ungated port and its
        // err_pin reaction, end to end.  In corrupt mode the timeout IS
        // the verdict point; keep it long enough for all 4 attempts.
        u_flash.mem[32'h1c] = u_flash.mem[32'h1c] ^ 8'h01;
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 80000;
        $display("[TB] CORRUPT mode: payload bit flipped at 0x1c");
      end
    end else begin
      $display("[TB] FATAL: +FLASH_HEX not given -- an empty flash cannot boot");
      $finish;
    end

    // fetch_enable up front: the loader, not this pin, is what must
    // hold the core until the image is verified
    @(posedge rst_n);
    repeat (5) @(posedge clk);
    fetch_enable = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (trace_en && retire_valid) begin
      $display("[TRACE] %8t pc=%08x instr=%08x", $time, retire_pc, retire_instr);
    end
    if (rst_n && retire_valid) retire_count++;
    if (rst_n && retire_valid && !boot_done) begin
      errors++;
      $display("[TB] ERROR: instruction retired before boot_done (pc=%08x)", retire_pc);
    end
    if (rst_n && boot_fault) begin
      errors++;
      $display("[TB] ERROR: boot_fault asserted");
    end
    if (boot_done && boot_cycle == 0) begin
      boot_cycle = cycle;
      $display("[TB] boot_done at cycle %0d", cycle);
    end
    if (fault_any) begin
      $display("[TB] fault reported, safety status = %08x", dut.u_safety.status_q);
    end
  end

  initial begin
    cycle = 0;
    retire_count = 0;
    forever begin
      @(posedge clk);
      cycle++;
      if (exit_seen) begin
        if (exit_code == 32'b0 && errors == 0 && boot_done && !err_pin) begin
          // err_pin must be LOW after a clean boot: boot_fault is 0, so
          // the safety controller's ungated boot_fault term leaves the
          // pin driven only by the (quiet) fault reactions.
          $display("[TB] PASS after %0d cycles (boot at %0d)", cycle, boot_cycle);
        end else begin
          $display("[TB] FAIL, exit code %08x, %0d bench errors", exit_code, errors);
        end
        $finish;
      end
      if (cycle >= max_cycles) begin
        if (corrupt_mode) begin
          // +CORRUPT: the timeout IS the pass condition -- the core must
          // never start.  Verdict: boot_fault reaches err_pin through
          // the safety controller's dedicated ungated boot_fault_i term
          // -- no software exists to configure any reaction, and the
          // fault deliberately does not latch into the sticky status --
          // zero instructions retired.
          if (boot_fault && err_pin && !boot_done && retire_count == 0)
            $display("[TB] PASS corrupt-image: fault latched, err_pin high, 0 retires after %0d cycles", cycle);
          else
            $display("[TB] FAIL corrupt-image: fault=%b err_pin=%b done=%b retires=%0d",
                     boot_fault, err_pin, boot_done, retire_count);
        end else begin
          $display("[TB] TIMEOUT after %0d cycles (boot_done=%b boot_fault=%b)",
                   cycle, boot_done, boot_fault);
        end
        $finish;
      end
    end
  end

  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("tb_cdriscv_boot.vcd");
      $dumpvars(0, tb_cdriscv_boot);
    end
  end

endmodule

`default_nettype wire
