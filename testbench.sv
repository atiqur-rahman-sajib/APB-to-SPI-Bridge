//==============================================================================
// testbench.sv  -  APB to SPI Bridge integration test
//
// Verifies the full data path:
//   APB write -> bridge serializes onto MOSI -> slave shifts response back on
//   MISO -> bridge captures it -> APB read returns the captured byte.
//
// Components:
//   - APB master tasks (apb_write / apb_read) on the CPU side
//   - Behavioural SPI slave that snoops MOSI and drives MISO with a known byte
//
// Each test:
//   1. CPU writes TX_DATA
//   2. CPU writes CTRL.start = 1
//   3. CPU polls STATUS.busy until 0
//   4. Compare slave-received byte against CPU's TX_DATA
//   5. CPU reads RX_DATA, compare against slave's transmitted byte
//==============================================================================

`timescale 1ns/1ns

module tb;

    // -------------------- Clock / reset --------------------
    logic pclk = 0;
    logic presetn;
    always #5 pclk = ~pclk;          // 100 MHz APB clock

    // -------------------- APB --------------------
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [7:0]  paddr;
    logic [7:0]  pwdata;
    logic [7:0]  prdata;
    logic        pready;

    // -------------------- SPI --------------------
    wire         sclk;
    wire         cs_n;
    wire         mosi;
    logic        miso;

    // -------------------- DUT --------------------
    apb_spi_bridge #(.CLK_DIV(4)) dut (
        .pclk(pclk), .presetn(presetn),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata),
        .prdata(prdata), .pready(pready),
        .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    // ============================================================
    // APB master driver (tasks)
    // ============================================================
    task automatic apb_write(input logic [7:0] addr, input logic [7:0] data);
        @(posedge pclk);
        psel    <= 1'b1;
        penable <= 1'b0;
        pwrite  <= 1'b1;
        paddr   <= addr;
        pwdata  <= data;
        @(posedge pclk);
        penable <= 1'b1;             // access phase
        @(posedge pclk);
        while (!pready) @(posedge pclk);
        psel    <= 1'b0;
        penable <= 1'b0;
        pwrite  <= 1'b0;
    endtask

    task automatic apb_read(input  logic [7:0] addr,
                            output logic [7:0] data);
        @(posedge pclk);
        psel    <= 1'b1;
        penable <= 1'b0;
        pwrite  <= 1'b0;
        paddr   <= addr;
        @(posedge pclk);
        penable <= 1'b1;
        @(posedge pclk);
        while (!pready) @(posedge pclk);
        data    = prdata;
        psel    <= 1'b0;
        penable <= 1'b0;
    endtask

    // ============================================================
    // Behavioural SPI slave
    // ============================================================
    bit  [7:0] slave_tx_byte = 8'h00;       // what slave sends back on MISO
    bit  [7:0] slave_rx_byte;                // what slave captured from MOSI
    bit  [7:0] slave_tx_shift;
    bit  [7:0] slave_rx_shift;
    int        slave_bit_idx;

    // Drive MISO from the slave's TX shift register MSB whenever cs_n is low
    assign miso_drv = slave_tx_shift[7];

    always @(*) begin
        if (cs_n)
            miso = 1'b0;        // bus released when not selected
        else
            miso = slave_tx_shift[7];
    end

    // On falling edge of cs_n, latch the byte to send and reset capture
    always @(negedge cs_n) begin
        slave_tx_shift <= slave_tx_byte;
        slave_rx_shift <= 8'h00;
        slave_bit_idx  <= 0;
    end

    // Mode 0: slave samples MOSI on rising edge of SCLK,
    //         shifts its own data on the falling edge.
    always @(posedge sclk) if (!cs_n) begin
        slave_rx_shift <= {slave_rx_shift[6:0], mosi};
        slave_bit_idx  <= slave_bit_idx + 1;
    end

    always @(negedge sclk) if (!cs_n) begin
        slave_tx_shift <= {slave_tx_shift[6:0], 1'b0};
    end

    // Latch the received byte at end-of-frame (cs_n rising)
    always @(posedge cs_n) begin
        slave_rx_byte <= slave_rx_shift;
    end

    // ============================================================
    // Helpers
    // ============================================================
    int errors = 0;

    task automatic do_spi_xfer(input  logic [7:0] cpu_tx,
                               input  logic [7:0] slv_tx,
                               output logic [7:0] cpu_rx);
        logic [7:0] status;

        // Pre-load slave's response
        slave_tx_byte = slv_tx;

        // CPU side: write TX_DATA, then write CTRL.start
        apb_write(8'h08, cpu_tx);
        apb_write(8'h00, 8'h01);

        // Poll STATUS.busy until 0
        do begin
            apb_read(8'h04, status);
        end while (status[0] == 1'b1);

        // Read back RX_DATA
        apb_read(8'h0C, cpu_rx);
    endtask

    task automatic check_xfer(input  logic [7:0] cpu_tx,
                              input  logic [7:0] slv_tx,
                              input  string      label);
        logic [7:0] cpu_rx;
        do_spi_xfer(cpu_tx, slv_tx, cpu_rx);

        $display("[%s] CPU sent 0x%02h, slave got 0x%02h | slave sent 0x%02h, CPU got 0x%02h",
                 label, cpu_tx, slave_rx_byte, slv_tx, cpu_rx);

        if (slave_rx_byte !== cpu_tx) begin
            $display("  >> FAIL (MOSI mismatch)");
            errors++;
        end else if (cpu_rx !== slv_tx) begin
            $display("  >> FAIL (MISO mismatch)");
            errors++;
        end else begin
            $display("  >> PASS");
        end
    endtask

    // ============================================================
    // Test sequence
    // ============================================================
    initial begin
        // Init
        psel    = 0;
        penable = 0;
        pwrite  = 0;
        paddr   = 0;
        pwdata  = 0;
        presetn = 0;
        slave_tx_shift = 0;
        slave_rx_shift = 0;
        slave_bit_idx  = 0;
        repeat (5) @(posedge pclk);
        presetn = 1;
        repeat (3) @(posedge pclk);

        $display("\n=== APB to SPI Bridge integration tests ===\n");

        // Test 1: simple round-trip
        check_xfer(8'hA5, 8'h3C, "T1");

        // Test 2: all zeros
        check_xfer(8'h00, 8'hFF, "T2");

        // Test 3: all ones
        check_xfer(8'hFF, 8'h00, "T3");

        // Test 4: walking pattern
        check_xfer(8'h55, 8'hAA, "T4");

        // Test 5: random-looking values back-to-back
        check_xfer(8'h12, 8'h34, "T5");
        check_xfer(8'hDE, 8'hAD, "T6");
        check_xfer(8'hBE, 8'hEF, "T7");

        // -------------------- Summary --------------------
        $display("\n==========================================================");
        if (errors == 0) $display("        ***  ALL APB-SPI BRIDGE TESTS PASSED  ***");
        else             $display("        ***  %0d FAILURES  ***", errors);
        $display("==========================================================\n");
        $finish;
    end

    // Watchdog
    initial begin
        #500_000;
        $display("WATCHDOG: simulation timed out");
        $finish;
    end

    // Waveform
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb);
    end

endmodule
