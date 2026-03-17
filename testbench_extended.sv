//----------------------------------------------------------------------------
// Extended testbench for deeper IEEE 754 boundary testing
//----------------------------------------------------------------------------

module testbench_extended;

    logic               clk;
    logic               rst;
    logic               arg_vld;
    wire                arg_rdy;
    logic  [FLEN - 1:0] a, b, c;
    wire                res_vld;
    logic               res_rdy;
    wire   [FLEN - 1:0] res;

    challenge dut (.*);

    // Clock
    initial begin clk = 1; forever #5 clk = ~clk; end

    // Reset
    task reset();
        rst <= 'x; repeat(3) @(posedge clk);
        rst <= '1; repeat(3) @(posedge clk);
        rst <= '0;
    endtask

    // Drive one set of inputs
    task automatic drive(input [FLEN-1:0] ai, bi, ci);
        a <= ai; b <= bi; c <= ci;
        arg_vld <= 1;
        @(posedge clk);
        while (!arg_rdy) @(posedge clk);
        arg_vld <= 0;
    endtask

    task wait_drain();
        repeat(200) @(posedge clk);
    endtask

    //------------------------------------------------------------------------
    // IEEE 754 special constants
    //------------------------------------------------------------------------

    localparam [FLEN-1:0] POS_ZERO    = 64'h0000_0000_0000_0000;
    localparam [FLEN-1:0] NEG_ZERO    = 64'h8000_0000_0000_0000;
    localparam [FLEN-1:0] POS_INF     = 64'h7FF0_0000_0000_0000;
    localparam [FLEN-1:0] NEG_INF     = 64'hFFF0_0000_0000_0000;
    localparam [FLEN-1:0] QNAN        = 64'h7FF8_0000_0000_0001; // quiet NaN
    localparam [FLEN-1:0] SNAN        = 64'h7FF0_0000_0000_0001; // signaling NaN
    localparam [FLEN-1:0] MIN_SUBNORM = 64'h0000_0000_0000_0001; // smallest subnormal
    localparam [FLEN-1:0] MAX_SUBNORM = 64'h000F_FFFF_FFFF_FFFF; // largest subnormal
    localparam [FLEN-1:0] MIN_NORMAL  = 64'h0010_0000_0000_0000; // smallest normal
    localparam [FLEN-1:0] MAX_NORMAL  = 64'h7FEF_FFFF_FFFF_FFFF; // largest normal
    localparam [FLEN-1:0] ONE         = 64'h3FF0_0000_0000_0000; // 1.0
    localparam [FLEN-1:0] NEG_ONE     = 64'hBFF0_0000_0000_0000; // -1.0
    localparam [FLEN-1:0] SMALL       = 64'h3E70_0000_0000_0000; // ~1e-8

    //------------------------------------------------------------------------
    // Checking infrastructure
    //------------------------------------------------------------------------

    logic [FLEN-1:0] expected_queue [$];
    int unsigned pass_cnt = 0;
    int unsigned fail_cnt = 0;
    int unsigned check_cnt = 0;
    bit done = 0;

    function bit is_nan(logic [FLEN-1:0] v);
        return (v[62:52] == 11'h7FF) && (v[51:0] != 0);
    endfunction

    function bit is_inf_or_nan(logic [FLEN-1:0] v);
        return v[62:52] == 11'h7FF;
    endfunction

    function bit loose_match(logic [FLEN-1:0] a_val, b_val);
        real ar, br, delta, maxv;
        if (a_val === b_val) return 1;
        if (is_nan(a_val) && is_nan(b_val)) return 1;
        if (is_inf_or_nan(a_val) || is_inf_or_nan(b_val)) return a_val[63:52] === b_val[63:52];
        ar = $bitstoreal(a_val);
        br = $bitstoreal(b_val);
        delta = (ar - br); if (delta < 0) delta = -delta;
        maxv = (ar >= 0 ? ar : -ar);
        if ((br >= 0 ? br : -br) > maxv) maxv = (br >= 0 ? br : -br);
        if (maxv == 0) return delta == 0;
        return (delta * 1000.0) < maxv;
    endfunction

    // Check results
    always @(posedge clk) begin
        if (!rst && res_vld && res_rdy) begin
            if (expected_queue.size() == 0) begin
                $display("FAIL: unexpected output res=%h", res);
                fail_cnt++;
            end else begin
                logic [FLEN-1:0] exp;
                check_cnt++;
                exp = expected_queue.pop_front();
                if (is_inf_or_nan(exp) || loose_match(res, exp)) begin
                    pass_cnt++;
                end else begin
                    $display("FAIL check #%0d: expected %h (%g), got %h (%g)",
                        check_cnt, exp, $bitstoreal(exp), res, $bitstoreal(res));
                    fail_cnt++;
                end
            end
        end
    end

    // Push expected
    task automatic push_expected(input [FLEN-1:0] ai, bi, ci);
        automatic logic [FLEN-1:0] exp;
        exp = $realtobits($bitstoreal(ai)**5 + 0.3/$bitstoreal(bi) - $bitstoreal(ci));
        expected_queue.push_back(exp);
    endtask

    // Combined: drive + push expected
    task automatic send(input [FLEN-1:0] ai, bi, ci);
        push_expected(ai, bi, ci);
        drive(ai, bi, ci);
    endtask

    task automatic send_real(input real ar, br, cr);
        send($realtobits(ar), $realtobits(br), $realtobits(cr));
    endtask

    //------------------------------------------------------------------------
    // Test groups
    //------------------------------------------------------------------------

    task test_zeros();
        $display("=== Test: Zeros ===");
        send(POS_ZERO, ONE, POS_ZERO);        // 0^5 + 0.3/1 - 0 = 0.3
        send(NEG_ZERO, ONE, POS_ZERO);        // (-0)^5 + 0.3/1 - 0
        send(POS_ZERO, NEG_ONE, POS_ZERO);    // 0 + 0.3/(-1) - 0 = -0.3
        send(POS_ZERO, ONE, NEG_ZERO);        // 0 + 0.3/1 - (-0) = 0.3
        send(POS_ZERO, POS_ZERO, POS_ZERO);   // 0 + 0.3/0 - 0 = +inf (div by zero)
        send(POS_ZERO, NEG_ZERO, POS_ZERO);   // 0 + 0.3/(-0) - 0 = -inf
        wait_drain();
    endtask

    task test_ones();
        $display("=== Test: Ones ===");
        send_real(1.0, 1.0, 0.0);    // 1 + 0.3/1 - 0 = 1.3
        send_real(-1.0, 1.0, 0.0);   // -1 + 0.3/1 - 0 = -0.7
        send_real(1.0, 1.0, 1.0);    // 1 + 0.3/1 - 1 = 0.3
        send_real(-1.0, 1.0, 1.0);   // -1 + 0.3/1 - 1 = -1.7
        send_real(2.0, 1.0, 0.0);    // 32 + 0.3 - 0 = 32.3
        send_real(-2.0, 1.0, 0.0);   // -32 + 0.3 - 0 = -31.7
        send_real(0.0, 10.0, 0.0);   // 0 + 0.3/10 - 0 = 0.03
        send_real(0.0, 1.0, 7.0);    // 0 + 0.3/1 - 7 = -6.7
        wait_drain();
    endtask

    task test_infinities();
        $display("=== Test: Infinities ===");
        send(POS_INF, ONE, POS_ZERO);         // inf^5 + 0.3/1 - 0 = inf
        send(NEG_INF, ONE, POS_ZERO);         // (-inf)^5 + 0.3/1 - 0 = -inf
        send(POS_ZERO, POS_INF, POS_ZERO);    // 0 + 0.3/inf - 0 = 0
        send(POS_ZERO, NEG_INF, POS_ZERO);    // 0 + 0.3/(-inf) - 0 = -0
        send(POS_ZERO, ONE, POS_INF);         // 0 + 0.3/1 - inf = -inf
        send(POS_ZERO, ONE, NEG_INF);         // 0 + 0.3/1 - (-inf) = inf
        send(POS_INF, ONE, POS_INF);          // inf + 0.3 - inf = NaN
        send(POS_ZERO, POS_ZERO, POS_ZERO);   // 0 + 0.3/0 - 0 = +inf (div by zero)
        wait_drain();
    endtask

    task test_nans();
        $display("=== Test: NaN propagation ===");
        send(QNAN,     ONE, ONE);     // NaN in a
        send(ONE,      QNAN, ONE);    // NaN in b
        send(ONE,      ONE, QNAN);    // NaN in c
        send(QNAN,     QNAN, QNAN);  // NaN everywhere
        send(SNAN,     ONE, ONE);     // Signaling NaN in a
        send(ONE,      SNAN, ONE);    // Signaling NaN in b
        send(ONE,      ONE, SNAN);    // Signaling NaN in c
        wait_drain();
    endtask

    task test_subnormals();
        $display("=== Test: Subnormals ===");
        send(MIN_SUBNORM, ONE, POS_ZERO);         // tiny^5 + 0.3/1 ≈ 0.3
        send(MAX_SUBNORM, ONE, POS_ZERO);         // small^5 + 0.3/1 ≈ 0.3
        send(MIN_NORMAL,  ONE, POS_ZERO);         // smallest normal^5 + 0.3
        send(POS_ZERO, MIN_SUBNORM, POS_ZERO);    // 0.3 / tiny = huge
        send(POS_ZERO, MAX_NORMAL, POS_ZERO);     // 0.3 / huge ≈ 0
        send(POS_ZERO, ONE, MIN_SUBNORM);         // 0 + 0.3 - tiny ≈ 0.3
        send(SMALL, SMALL, SMALL);                 // all small values
        wait_drain();
    endtask

    task test_overflow();
        $display("=== Test: Overflow (large a) ===");
        // a = 100 → a^5 = 1e10 (ok)
        send_real(100.0, 1.0, 0.0);
        // a = 1000 → a^5 = 1e15 (ok)
        send_real(1000.0, 1.0, 0.0);
        // a = 1e60 → a^5 = 1e300 (near max)
        send_real(1.0e60, 1.0, 0.0);
        // a = 1e62 → a^5 = 1e310 → overflow → inf
        send_real(1.0e62, 1.0, 0.0);
        // a just big enough to overflow
        send(MAX_NORMAL, ONE, POS_ZERO);
        wait_drain();
    endtask

    task test_cancellation();
        $display("=== Test: Catastrophic cancellation ===");
        // a^5 ≈ c, so result ≈ 0.3/b (cancellation in subtraction)
        send_real(1.0, 1.0, 1.0);         // 1 + 0.3 - 1 = 0.3
        send_real(2.0, 1.0, 32.0);        // 32 + 0.3 - 32 = 0.3
        send_real(3.0, 1.0, 243.0);       // 243 + 0.3 - 243 = 0.3
        // Near-cancellation with large b (small 0.3/b)
        send_real(1.0, 1e10, 1.0);        // 1 + 3e-11 - 1 ≈ 3e-11
        wait_drain();
    endtask

    task test_backpressure_patterns();
        $display("=== Test: Alternating backpressure ===");
        // Send 50 values with res_rdy toggling every cycle
        fork
            begin
                for (int i = 0; i < 50; i++)
                    send_real(real'(i) * 0.1, real'(i) * 0.2, real'(i) * 0.3);
            end
            begin
                for (int i = 0; i < 500; i++) begin
                    res_rdy <= (i % 2 == 0);
                    @(posedge clk);
                end
            end
        join_any
        res_rdy <= 1;
        wait_drain();
    endtask

    task test_burst_backpressure();
        $display("=== Test: Burst backpressure (1 on, 50 off) ===");
        fork
            begin
                for (int i = 0; i < 30; i++)
                    send_real(real'(i+1), real'(i+10), real'(i+100));
            end
            begin
                for (int j = 0; j < 20; j++) begin
                    res_rdy <= 1; @(posedge clk);
                    res_rdy <= 0; repeat(50) @(posedge clk);
                end
            end
        join_any
        res_rdy <= 1;
        wait_drain();
    endtask

    task test_reset_during_operation();
        $display("=== Test: Reset during pipeline active ===");
        // Fill pipeline
        for (int i = 0; i < 20; i++)
            send_real(real'(i+1), real'(i+1), real'(i+1));

        // Wait a bit then reset mid-pipeline
        repeat(8) @(posedge clk);
        expected_queue = {};  // Clear expected since reset discards
        reset();

        // Verify clean state after reset
        if (res_vld !== 0)
            $display("FAIL: res_vld not 0 after reset");
        if (arg_rdy !== 1)
            $display("FAIL: arg_rdy not 1 after reset (got %b)", arg_rdy);

        // Send new data — should work normally
        send_real(1.0, 4.0, 3.0);   // expect -0.8
        send_real(2.0, 0.0, 0.0);   // expect 32
        wait_drain();
    endtask

    task test_long_random(int count);
        $display("=== Test: Long random (%0d inputs) ===", count);
        fork
            begin
                for (int i = 0; i < count; i++) begin
                    logic [FLEN-1:0] ra, rb, rc;
                    ra = $realtobits($urandom() / 10000.0);
                    rb = $realtobits($urandom() / 10000.0);
                    rc = $realtobits($urandom() / 10000.0);
                    send(ra, rb, rc);
                end
            end
            begin
                for (int i = 0; i < count * 10; i++) begin
                    res_rdy <= ($urandom_range(0,3) != 0); // 75% ready
                    @(posedge clk);
                end
            end
        join_any
        res_rdy <= 1;
        wait_drain();
    endtask

    //------------------------------------------------------------------------
    // Main
    //------------------------------------------------------------------------

    initial begin
        `ifdef __ICARUS__
            $dumpvars;
        `endif

        arg_vld <= 0;
        res_rdy <= 1;
        reset();

        test_zeros();
        test_ones();
        test_infinities();
        test_nans();
        test_subnormals();
        test_overflow();
        test_cancellation();
        test_backpressure_patterns();
        test_burst_backpressure();
        test_reset_during_operation();
        test_long_random(500);

        // Final drain
        res_rdy <= 1;
        repeat(500) @(posedge clk);

        $display("");
        $display("============================================");
        $display("Extended Test Results:");
        $display("  Checks: %0d", check_cnt);
        $display("  Pass:   %0d", pass_cnt);
        $display("  Fail:   %0d", fail_cnt);
        $display("  Queue remaining: %0d", expected_queue.size());
        if (fail_cnt == 0 && expected_queue.size() == 0)
            $display("  PASS extended tests");
        else
            $display("  FAIL extended tests");
        $display("============================================");
        $finish;
    end

    // Timeout
    initial begin
        repeat(50000) @(posedge clk);
        $display("FAIL: extended testbench timeout");
        $finish;
    end

endmodule
