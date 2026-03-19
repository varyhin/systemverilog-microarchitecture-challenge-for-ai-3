/*

Put any submodules you need here.

You are not allowed to implement your own submodules or functions for the addition,
subtraction, multiplication, division, comparison or getting the square
root of floating-point numbers. For such operations you can only use the
modules from the arithmetic_block_wrappers directory.

*/

module challenge
(
    input  logic               clk,
    input  logic               rst,

    input  logic               arg_vld,
    output logic               arg_rdy,
    input  logic [FLEN - 1:0]  a,
    input  logic [FLEN - 1:0]  b,
    input  logic [FLEN - 1:0]  c,

    output logic               res_vld,
    input  logic               res_rdy,
    output logic [FLEN - 1:0]  res
);

    //----------------------------------------------------------------------
    // Constants
    //----------------------------------------------------------------------

    localparam logic [FLEN - 1:0] CONST_0_3 = 64'h3FD3333333333333;

    localparam int NUM_DIV    = 19;
    localparam int FIFO_DEPTH = 36;   // min for back-to-back: ceil(pipeline_depth) + 2
    localparam int FIFO_AW    = $clog2(FIFO_DEPTH);
    localparam int CNT_W      = $clog2(FIFO_DEPTH + 1);
    localparam int DIV_PTR_W  = $clog2(NUM_DIV);

    //----------------------------------------------------------------------
    // Front-end: round-robin dividers for 0.3 / b
    //----------------------------------------------------------------------

    logic [DIV_PTR_W - 1:0] slot_wr_ptr, slot_rd_ptr;

    logic [FLEN - 1:0] slot_a    [NUM_DIV];
    logic [FLEN - 1:0] slot_c    [NUM_DIV];
    logic [FLEN - 1:0] slot_quot [NUM_DIV];
    logic               slot_active [NUM_DIV];
    logic               slot_done   [NUM_DIV];

    logic [FLEN - 1:0] div_res   [NUM_DIV];
    logic               div_dv    [NUM_DIV];
    logic               div_busy  [NUM_DIV];
    logic               div_err   [NUM_DIV];
    logic               div_start [NUM_DIV];

    logic wr_slot_free, accepted, collect;

    assign wr_slot_free = !slot_active[slot_wr_ptr];
    assign accepted     = arg_vld & arg_rdy;
    assign collect      = slot_done[slot_rd_ptr];

    // Back-end feed
    logic [FLEN - 1:0] be_a, be_c, be_quot;
    logic               be_valid;

    assign be_a     = slot_a[slot_rd_ptr];
    assign be_c     = slot_c[slot_rd_ptr];
    assign be_quot  = slot_quot[slot_rd_ptr];
    assign be_valid = collect;

    // Divider start (combinational)
    always_comb begin
        foreach (div_start[k])
            div_start[k] = 1'b0;

        if (accepted)
            div_start[slot_wr_ptr] = 1'b1;
    end

    // Divider instances
    for (genvar g = 0; g < NUM_DIV; g++) begin : gen_div
        f_div u_div (
            .clk,  .rst,
            .a         ( CONST_0_3    ),
            .b         ( b            ),
            .up_valid  ( div_start[g] ),
            .res       ( div_res[g]   ),
            .down_valid( div_dv[g]    ),
            .busy      ( div_busy[g]  ),
            .error     ( div_err[g]   )
        );
    end

    // Modular pointer increment
    function automatic logic [DIV_PTR_W - 1:0] next_div_ptr(
        input logic [DIV_PTR_W - 1:0] ptr
    );
        return (ptr == DIV_PTR_W'(NUM_DIV - 1)) ? DIV_PTR_W'(0)
                                                 : ptr + DIV_PTR_W'(1);
    endfunction

    // Slot control
    always_ff @(posedge clk) begin
        if (rst) begin
            slot_wr_ptr <= '0;
            slot_rd_ptr <= '0;
            foreach (slot_active[j]) begin
                slot_active[j] <= 1'b0;
                slot_done[j]   <= 1'b0;
            end
        end else begin
            if (accepted) begin
                slot_a[slot_wr_ptr]      <= a;
                slot_c[slot_wr_ptr]      <= c;
                slot_active[slot_wr_ptr] <= 1'b1;
                slot_wr_ptr              <= next_div_ptr(slot_wr_ptr);
            end

            foreach (slot_active[j]) begin
                if (slot_active[j] && div_dv[j] && !slot_done[j]) begin
                    slot_quot[j] <= div_res[j];
                    slot_done[j] <= 1'b1;
                end
            end

            if (collect) begin
                slot_active[slot_rd_ptr] <= 1'b0;
                slot_done[slot_rd_ptr]   <= 1'b0;
                slot_rd_ptr              <= next_div_ptr(slot_rd_ptr);
            end
        end
    end

    //----------------------------------------------------------------------
    // Back-end: pipelined a^5 + quot - c
    //----------------------------------------------------------------------

    // Delay lines
    logic [FLEN - 1:0] a_delay    [6];
    logic [FLEN - 1:0] quot_delay [9];
    logic [FLEN - 1:0] c_delay    [13];

    always_ff @(posedge clk) begin
        a_delay[0] <= be_a;
        foreach (a_delay[i])
            if (i > 0) a_delay[i] <= a_delay[i - 1];

        quot_delay[0] <= be_quot;
        foreach (quot_delay[i])
            if (i > 0) quot_delay[i] <= quot_delay[i - 1];

        c_delay[0] <= be_c;
        foreach (c_delay[i])
            if (i > 0) c_delay[i] <= c_delay[i - 1];
    end

    // Arithmetic wires
    logic [FLEN - 1:0] a2, a4, a5, sum_val, final_result;
    logic mult1_dv, mult2_dv, mult3_dv, add1_dv, sub1_dv;
    logic mult1_busy, mult2_busy, mult3_busy, add1_busy, sub1_busy;
    logic mult1_err, mult2_err, mult3_err, sub1_err;
    wire  add1_err; // wire: f_add has dual-driver on error port internally

    // mult1: a * a -> a^2  (latency 3)
    f_mult mult1 (
        .clk,  .rst,
        .a         ( be_a     ),
        .b         ( be_a     ),
        .up_valid  ( be_valid ),
        .res       ( a2       ),
        .down_valid( mult1_dv ),
        .busy      ( mult1_busy ),
        .error     ( mult1_err  )
    );

    // mult2: a^2 * a^2 -> a^4  (latency 3)
    f_mult mult2 (
        .clk,  .rst,
        .a         ( a2        ),
        .b         ( a2        ),
        .up_valid  ( mult1_dv  ),
        .res       ( a4        ),
        .down_valid( mult2_dv  ),
        .busy      ( mult2_busy ),
        .error     ( mult2_err  )
    );

    // mult3: a^4 * a_delay[5] -> a^5  (latency 3)
    f_mult mult3 (
        .clk,  .rst,
        .a         ( a4         ),
        .b         ( a_delay[5] ),
        .up_valid  ( mult2_dv   ),
        .res       ( a5         ),
        .down_valid( mult3_dv   ),
        .busy      ( mult3_busy ),
        .error     ( mult3_err  )
    );

    // add1: a^5 + quot_delay[8] -> sum  (latency 4)
    f_add add1 (
        .clk,  .rst,
        .a         ( a5            ),
        .b         ( quot_delay[8] ),
        .up_valid  ( mult3_dv      ),
        .res       ( sum_val       ),
        .down_valid( add1_dv       ),
        .busy      ( add1_busy     ),
        .error     ( add1_err      )
    );

    // sub1: sum - c_delay[12] -> result  (latency 3)
    f_sub sub1 (
        .clk,  .rst,
        .a         ( sum_val      ),
        .b         ( c_delay[12]  ),
        .up_valid  ( add1_dv      ),
        .res       ( final_result ),
        .down_valid( sub1_dv      ),
        .busy      ( sub1_busy    ),
        .error     ( sub1_err     )
    );

    //----------------------------------------------------------------------
    // Output FIFO (non-power-of-2, explicit count)
    //----------------------------------------------------------------------

    logic [FLEN - 1:0]    fifo_mem [FIFO_DEPTH];
    logic [FIFO_AW - 1:0] fifo_wr_idx, fifo_rd_idx;
    logic [CNT_W - 1:0]   fifo_count;
    logic                  fifo_push, fifo_pop;

    assign fifo_push = sub1_dv;
    assign fifo_pop  = res_vld & res_rdy;

    function automatic logic [FIFO_AW - 1:0] next_fifo_idx(
        input logic [FIFO_AW - 1:0] idx
    );
        return (idx == FIFO_AW'(FIFO_DEPTH - 1)) ? FIFO_AW'(0)
                                                  : idx + FIFO_AW'(1);
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_wr_idx <= '0;
            fifo_rd_idx <= '0;
            fifo_count  <= '0;
        end else begin
            if (fifo_push) begin
                fifo_mem[fifo_wr_idx] <= final_result;
                fifo_wr_idx           <= next_fifo_idx(fifo_wr_idx);
            end
            if (fifo_pop)
                fifo_rd_idx <= next_fifo_idx(fifo_rd_idx);

            fifo_count <= fifo_count + CNT_W'(fifo_push) - CNT_W'(fifo_pop);
        end
    end

    //----------------------------------------------------------------------
    // In-flight counter
    //----------------------------------------------------------------------

    logic [6:0] in_flight;

    always_ff @(posedge clk) begin
        if (rst)
            in_flight <= '0;
        else
            in_flight <= in_flight + 7'(accepted) - 7'(sub1_dv);
    end

    //----------------------------------------------------------------------
    // Output handshake
    //----------------------------------------------------------------------

    assign res_vld = (fifo_count != '0);
    assign res     = fifo_mem[fifo_rd_idx];

    //----------------------------------------------------------------------
    // Input ready
    //----------------------------------------------------------------------

    assign arg_rdy = !rst & wr_slot_free
                   & (CNT_W'(fifo_count) + CNT_W'(in_flight) < CNT_W'(FIFO_DEPTH));

    //----------------------------------------------------------------------
    // Assertions (simulation only)
    //----------------------------------------------------------------------

    // synthesis translate_off
    always_ff @(posedge clk) begin
        if (!rst) begin
            assert (fifo_count <= CNT_W'(FIFO_DEPTH))
                else $error("FIFO overflow: count=%0d > depth=%0d", fifo_count, FIFO_DEPTH);

            assert (!(fifo_push && fifo_count == CNT_W'(FIFO_DEPTH)))
                else $error("FIFO push when full: count=%0d", fifo_count);

            assert (!(fifo_pop && fifo_count == '0))
                else $error("FIFO pop when empty");

            assert (in_flight <= 7'(FIFO_DEPTH))
                else $error("in_flight overflow: %0d > %0d", in_flight, FIFO_DEPTH);
        end
    end
    // synthesis translate_on

endmodule
