//==============================================================================
// design.sv  -  APB to SPI Bridge
//
// CPU side: APB3 slave with three byte-wide registers
//
//   Addr 0x00  CTRL    [0]=start (write 1 -> kick off SPI transfer; auto-clears)
//   Addr 0x04  STATUS  [0]=busy  (read-only; 1 while SPI transfer in progress)
//   Addr 0x08  TX_DATA byte to be sent on MOSI when CTRL.start is written
//   Addr 0x0C  RX_DATA byte captured from MISO during the last transfer
//
// SPI side: Mode 0 master (CPOL=0, CPHA=0)
//   - cs_n asserted (low) for the duration of the transfer
//   - sclk idles low; data driven on MOSI on the falling edge of sclk,
//     MISO sampled on the rising edge of sclk
//   - 8 bits, MSB first
//
// SCLK = clk / (2 * CLK_DIV).  With clk=100 MHz, CLK_DIV=4 -> SCLK=12.5 MHz.
//==============================================================================

module apb_spi_bridge #(
    parameter int CLK_DIV = 4
)(
    // ----- APB slave -----
    input  logic        pclk,
    input  logic        presetn,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [7:0]  paddr,
    input  logic [7:0]  pwdata,
    output logic [7:0]  prdata,
    output logic        pready,

    // ----- SPI master -----
    output logic        sclk,
    output logic        cs_n,
    output logic        mosi,
    input  logic        miso
);

    // -------------------------------------------------------------------------
    // Register file
    // -------------------------------------------------------------------------
    logic [7:0] tx_data_reg;
    logic [7:0] rx_data_reg;
    logic       start_pulse;        // 1-cycle pulse from CTRL[0]
    logic       busy;

    // ---------------- APB write/read ----------------
    // APB transfer is "ready" in the access phase (psel & penable).
    assign pready = 1'b1;

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            tx_data_reg <= 8'h00;
            start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;     // default: clear pulse
            if (psel && penable && pwrite) begin
                case (paddr)
                    8'h00: if (pwdata[0]) start_pulse <= 1'b1;
                    8'h08: tx_data_reg <= pwdata;
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        prdata = 8'h00;
        if (psel && !pwrite) begin
            case (paddr)
                8'h00: prdata = 8'h00;            // CTRL reads as 0
                8'h04: prdata = {7'h0, busy};
                8'h08: prdata = tx_data_reg;
                8'h0C: prdata = rx_data_reg;
                default: prdata = 8'h00;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // SPI master FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} sstate_t;
    sstate_t                       sstate;

    logic [$clog2(CLK_DIV+1)-1:0]  div_cnt;
    logic                          tick;        // 1 pulse per half-bit
    logic [3:0]                    bit_cnt;     // 0..15 (8 bits * 2 half-cycles)
    logic [7:0]                    tx_shift;
    logic [7:0]                    rx_shift;
    logic                          sclk_r;
    logic                          cs_n_r;
    logic                          mosi_r;

    assign sclk = sclk_r;
    assign cs_n = cs_n_r;
    assign mosi = mosi_r;

    // Half-bit tick generator: tick fires every CLK_DIV pclk cycles when running
    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            div_cnt <= '0;
            tick    <= 1'b0;
        end else if (sstate == S_RUN) begin
            if (div_cnt == CLK_DIV - 1) begin
                div_cnt <= '0;
                tick    <= 1'b1;
            end else begin
                div_cnt <= div_cnt + 1'b1;
                tick    <= 1'b0;
            end
        end else begin
            div_cnt <= '0;
            tick    <= 1'b0;
        end
    end

    // FSM + shifters
    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            sstate      <= S_IDLE;
            bit_cnt     <= 4'd0;
            tx_shift    <= 8'h00;
            rx_shift    <= 8'h00;
            rx_data_reg <= 8'h00;
            sclk_r      <= 1'b0;
            cs_n_r      <= 1'b1;
            mosi_r      <= 1'b0;
            busy        <= 1'b0;
        end else begin
            case (sstate)

                // ---------------- IDLE ----------------
                S_IDLE: begin
                    sclk_r <= 1'b0;
                    cs_n_r <= 1'b1;
                    mosi_r <= 1'b0;
                    busy   <= 1'b0;
                    if (start_pulse) begin
                        // Mode 0: drive MSB on MOSI before first rising edge
                        tx_shift <= tx_data_reg;
                        rx_shift <= 8'h00;
                        bit_cnt  <= 4'd0;
                        cs_n_r   <= 1'b0;
                        mosi_r   <= tx_data_reg[7];
                        busy     <= 1'b1;
                        sstate   <= S_RUN;
                    end
                end

                // ---------------- RUN ----------------
                // Each tick is half a SCLK period:
                //   bit_cnt even  -> rising edge: sample MISO (slave just drove it)
                //   bit_cnt odd   -> falling edge: shift, drive next MOSI bit
                S_RUN: if (tick) begin
                    if (bit_cnt[0] == 1'b0) begin
                        // Rising edge of SCLK
                        sclk_r   <= 1'b1;
                        rx_shift <= {rx_shift[6:0], miso};
                        bit_cnt  <= bit_cnt + 4'd1;
                    end else begin
                        // Falling edge of SCLK
                        sclk_r <= 1'b0;
                        if (bit_cnt == 4'd15) begin
                            // Final falling edge - transfer complete
                            rx_data_reg <= {rx_shift[6:0], 1'b0} | (rx_shift << 0);
                            // simpler: rx_data_reg already updated via rx_shift assign above
                            rx_data_reg <= rx_shift;
                            cs_n_r      <= 1'b1;
                            busy        <= 1'b0;
                            sstate      <= S_DONE;
                        end else begin
                            tx_shift <= {tx_shift[6:0], 1'b0};
                            mosi_r   <= tx_shift[6];   // next MSB
                            bit_cnt  <= bit_cnt + 4'd1;
                        end
                    end
                end

                // ---------------- DONE (one settle cycle) ----------------
                S_DONE: begin
                    sstate <= S_IDLE;
                end

                default: sstate <= S_IDLE;
            endcase
        end
    end

endmodule
