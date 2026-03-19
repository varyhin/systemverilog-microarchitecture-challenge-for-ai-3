// Coverage monitor for challenge.sv — bind into DUT hierarchy
// Usage: add to iverilog command line alongside testbench.sv
// Reports functional coverage at end of simulation

module coverage_monitor;

    // Bind to DUT signals via hierarchical references
    wire               clk       = testbench.dut.clk;
    wire               rst       = testbench.dut.rst;
    wire               arg_vld   = testbench.dut.arg_vld;
    wire               arg_rdy   = testbench.dut.arg_rdy;
    wire               res_vld   = testbench.dut.res_vld;
    wire               res_rdy   = testbench.dut.res_rdy;
    wire               accepted  = testbench.dut.accepted;
    wire               collect   = testbench.dut.collect;
    wire               sub1_dv   = testbench.dut.sub1_dv;
    wire               fifo_push = testbench.dut.fifo_push;
    wire               fifo_pop  = testbench.dut.fifo_pop;
    wire [5:0]         fifo_count= testbench.dut.fifo_count;
    wire [6:0]         in_flight = testbench.dut.in_flight;
    wire               wr_slot_free = testbench.dut.wr_slot_free;

    //----------------------------------------------------------------------
    // Counters
    //----------------------------------------------------------------------

    int unsigned cycles_total;
    int unsigned cycles_in_reset;

    // Handshake coverage
    int unsigned accepted_count;
    int unsigned result_count;
    int unsigned arg_vld_no_rdy;         // arg_vld=1 & arg_rdy=0 (backpressure to input)
    int unsigned res_vld_no_rdy;         // res_vld=1 & res_rdy=0 (backpressure from output)
    int unsigned back_to_back_accepted;  // consecutive accepted cycles
    int unsigned max_back_to_back;

    // Pipeline coverage
    int unsigned max_in_flight;
    int unsigned max_fifo_count;
    int unsigned fifo_simultaneous_push_pop;
    int unsigned slot_not_free_count;     // wr_slot_free=0

    // Edge cases
    int unsigned fifo_was_empty;         // fifo_count went to 0
    int unsigned fifo_was_full;          // fifo_count reached max
    int unsigned in_flight_was_zero;     // pipeline fully drained

    //----------------------------------------------------------------------
    // Track state
    //----------------------------------------------------------------------

    logic prev_accepted;

    always @(posedge clk) begin
        if (rst) begin
            cycles_in_reset++;
        end else begin
            // Handshake events
            if (arg_vld && arg_rdy)  accepted_count++;
            if (res_vld && res_rdy)  result_count++;
            if (arg_vld && !arg_rdy) arg_vld_no_rdy++;
            if (res_vld && !res_rdy) res_vld_no_rdy++;

            // Back-to-back tracking
            if (accepted && prev_accepted) begin
                back_to_back_accepted++;
                if (back_to_back_accepted > max_back_to_back)
                    max_back_to_back = back_to_back_accepted;
            end else if (!accepted) begin
                back_to_back_accepted = 0;
            end
            prev_accepted <= accepted;

            // Pipeline peaks
            if (in_flight > max_in_flight[6:0])
                max_in_flight = in_flight;
            if (fifo_count > max_fifo_count[5:0])
                max_fifo_count = fifo_count;

            // Simultaneous push+pop
            if (fifo_push && fifo_pop)
                fifo_simultaneous_push_pop++;

            // Slot pressure
            if (!wr_slot_free)
                slot_not_free_count++;

            // Edge cases
            if (fifo_count == 0)     fifo_was_empty++;
            if (fifo_count >= 34)    fifo_was_full++;  // near-full threshold
            if (in_flight == 0 && !rst) in_flight_was_zero++;
        end

        cycles_total++;
    end

    //----------------------------------------------------------------------
    // Coverage report
    //----------------------------------------------------------------------

    real utilization, throughput;

    final begin
        utilization = 100.0 * real'(accepted_count) / real'(cycles_total - cycles_in_reset);
        throughput  = real'(result_count) / real'(cycles_total - cycles_in_reset);

        $display("\n");
        $display("========== COVERAGE REPORT ==========");
        $display("");
        $display("--- Simulation ---");
        $display("  Total cycles:          %0d", cycles_total);
        $display("  Reset cycles:          %0d", cycles_in_reset);
        $display("  Active cycles:         %0d", cycles_total - cycles_in_reset);
        $display("");
        $display("--- Handshake Coverage ---");
        $display("  Accepted (arg_vld&rdy): %0d", accepted_count);
        $display("  Results  (res_vld&rdy): %0d", result_count);
        $display("  Input  stalls (vld&!rdy): %0d", arg_vld_no_rdy);
        $display("  Output stalls (vld&!rdy): %0d", res_vld_no_rdy);
        $display("  Input utilization:      %0.1f%%", utilization);
        $display("  Throughput:             %0.3f res/cycle", throughput);
        $display("");
        $display("--- Back-to-Back ---");
        $display("  Max consecutive accepted: %0d", max_back_to_back);
        $display("  Back-to-back achieved:  %s", max_back_to_back > 10 ? "YES" : "NO");
        $display("");
        $display("--- Pipeline Utilization ---");
        $display("  Max in_flight:          %0d / 36 (FIFO_DEPTH)", max_in_flight);
        $display("  Max fifo_count:         %0d / 36", max_fifo_count);
        $display("  Simultaneous push+pop:  %0d", fifo_simultaneous_push_pop);
        $display("  Slot-not-free cycles:   %0d", slot_not_free_count);
        $display("");
        $display("--- Edge Cases ---");
        $display("  FIFO empty cycles:      %0d  %s", fifo_was_empty,
            fifo_was_empty > 0 ? "[COVERED]" : "[NOT COVERED]");
        $display("  FIFO near-full cycles:  %0d  %s", fifo_was_full,
            fifo_was_full > 0 ? "[COVERED]" : "[NOT COVERED]");
        $display("  Pipeline drained:       %0d  %s", in_flight_was_zero,
            in_flight_was_zero > 0 ? "[COVERED]" : "[NOT COVERED]");
        $display("  Input backpressure:     %0d  %s", arg_vld_no_rdy,
            arg_vld_no_rdy > 0 ? "[COVERED]" : "[NOT COVERED]");
        $display("  Output backpressure:    %0d  %s", res_vld_no_rdy,
            res_vld_no_rdy > 0 ? "[COVERED]" : "[NOT COVERED]");
        $display("");

        // Coverage score
        begin
            integer covered;
            integer total;
            covered = 0;
            total = 5;

            if (fifo_was_empty > 0)    covered++;
            if (fifo_was_full > 0)     covered++;
            if (in_flight_was_zero > 0) covered++;
            if (arg_vld_no_rdy > 0)    covered++;
            if (res_vld_no_rdy > 0)    covered++;

            $display("--- Functional Coverage Score ---");
            $display("  Edge cases covered:     %0d / %0d (%0.0f%%)",
                covered, total, 100.0 * real'(covered) / real'(total));
        end

        $display("=====================================\n");
    end

endmodule
