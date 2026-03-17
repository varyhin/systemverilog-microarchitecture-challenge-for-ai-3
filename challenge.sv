/*

Put any submodules you need here.

You are not allowed to implement your own submodules or functions for the addition,
subtraction, multiplication, division, comparison or getting the square
root of floating-point numbers. For such operations you can only use the
modules from the arithmetic_block_wrappers directory.

*/

module challenge
(
    input                     clk,
    input                     rst,

    input                     arg_vld,
    output                    arg_rdy,
    input        [FLEN - 1:0] a,
    input        [FLEN - 1:0] b,
    input        [FLEN - 1:0] c,

    output logic              res_vld,
    input  logic              res_rdy,
    output logic [FLEN - 1:0] res
);

    //----------------------------------------------------------------------
    // Constants and parameters
    //----------------------------------------------------------------------

    localparam [FLEN - 1:0] CONST_0_3 = 64'h3FD3333333333333; // 0.3 double

    localparam NUM_DIV    = 5;
    localparam FIFO_DEPTH = 32;
    localparam PTR_W      = $clog2(FIFO_DEPTH);

    //----------------------------------------------------------------------
    // Front-end: 5 round-robin dividers for 0.3 / b
    //----------------------------------------------------------------------

    // Divider slot pointers
    reg [2:0] slot_wr_ptr;
    reg [2:0] slot_rd_ptr;

    // Per-slot storage
    reg [FLEN - 1:0] slot_a [0:NUM_DIV - 1];
    reg [FLEN - 1:0] slot_c [0:NUM_DIV - 1];
    reg [FLEN - 1:0] slot_quot [0:NUM_DIV - 1];
    reg               slot_active [0:NUM_DIV - 1];
    reg               slot_done   [0:NUM_DIV - 1];

    // Divider interface wires
    wire [FLEN - 1:0] div_res  [0:NUM_DIV - 1];
    wire               div_dv   [0:NUM_DIV - 1];
    wire               div_busy [0:NUM_DIV - 1];
    wire               div_err  [0:NUM_DIV - 1];
    logic              div_start [0:NUM_DIV - 1];

    // Input handshake
    wire wr_slot_free = ~slot_active[slot_wr_ptr];
    wire accepted     = arg_vld & arg_rdy;

    // Collection: feed back-end when oldest slot has result
    wire collect  = slot_done[slot_rd_ptr];
    wire [FLEN - 1:0] be_a     = slot_a[slot_rd_ptr];
    wire [FLEN - 1:0] be_c     = slot_c[slot_rd_ptr];
    wire [FLEN - 1:0] be_quot  = slot_quot[slot_rd_ptr];
    wire               be_valid = collect;

    // div_start: combinational (must present b on same cycle)
    integer idx;
    always @(*) begin
        for (idx = 0; idx < NUM_DIV; idx = idx + 1)
            div_start[idx] = 0;
        if (accepted)
            div_start[slot_wr_ptr] = 1;
    end

    // Divider instantiation (5 instances)
    genvar g;
    generate
        for (g = 0; g < NUM_DIV; g = g + 1) begin : div_inst
            f_div u_div (
                .clk       ( clk           ),
                .rst       ( rst           ),
                .a         ( CONST_0_3     ),
                .b         ( b             ),
                .up_valid  ( div_start[g]  ),
                .res       ( div_res[g]    ),
                .down_valid( div_dv[g]     ),
                .busy      ( div_busy[g]   ),
                .error     ( div_err[g]    )
            );
        end
    endgenerate

    // Slot control logic
    integer j;
    always @(posedge clk) begin
        if (rst) begin
            slot_wr_ptr <= 3'd0;
            slot_rd_ptr <= 3'd0;
            for (j = 0; j < NUM_DIV; j = j + 1) begin
                slot_active[j] <= 1'b0;
                slot_done[j]   <= 1'b0;
            end
        end else begin
            // Dispatch: save (a, c), mark active, advance wr pointer
            if (accepted) begin
                slot_a[slot_wr_ptr] <= a;
                slot_c[slot_wr_ptr] <= c;
                slot_active[slot_wr_ptr] <= 1'b1;
                slot_wr_ptr <= (slot_wr_ptr == NUM_DIV - 1) ? 3'd0
                                                            : slot_wr_ptr + 3'd1;
            end

            // Capture divider results
            for (j = 0; j < NUM_DIV; j = j + 1) begin
                if (slot_active[j] && div_dv[j] && !slot_done[j]) begin
                    slot_quot[j] <= div_res[j];
                    slot_done[j] <= 1'b1;
                end
            end

            // Collect: release slot, advance rd pointer
            if (collect) begin
                slot_active[slot_rd_ptr] <= 1'b0;
                slot_done[slot_rd_ptr]   <= 1'b0;
                slot_rd_ptr <= (slot_rd_ptr == NUM_DIV - 1) ? 3'd0
                                                            : slot_rd_ptr + 3'd1;
            end
        end
    end

    //----------------------------------------------------------------------
    // Back-end: pipelined a^5 + quot - c
    //----------------------------------------------------------------------

    // Delay lines
    reg [FLEN - 1:0] a_delay    [0:5];   // 6 stages (be_a needed at cycle 6)
    reg [FLEN - 1:0] quot_delay [0:8];   // 9 stages (be_quot needed at cycle 9)
    reg [FLEN - 1:0] c_delay    [0:12];  // 13 stages (be_c needed at cycle 13)

    integer i;
    always @(posedge clk) begin
        a_delay[0] <= be_a;
        for (i = 1; i < 6; i = i + 1)
            a_delay[i] <= a_delay[i - 1];

        quot_delay[0] <= be_quot;
        for (i = 1; i < 9; i = i + 1)
            quot_delay[i] <= quot_delay[i - 1];

        c_delay[0] <= be_c;
        for (i = 1; i < 13; i = i + 1)
            c_delay[i] <= c_delay[i - 1];
    end

    // Arithmetic block wires
    wire [FLEN - 1:0] a2, a4, a5, sum_val, final_result;
    wire mult1_dv, mult2_dv, mult3_dv, add1_dv, sub1_dv;
    wire mult1_busy, mult2_busy, mult3_busy, add1_busy, sub1_busy;
    wire mult1_err, mult2_err, mult3_err, add1_err, sub1_err;

    // mult1: a * a -> a2 (latency 3)
    f_mult mult1 (
        .clk       ( clk       ),
        .rst       ( rst       ),
        .a         ( be_a      ),
        .b         ( be_a      ),
        .up_valid  ( be_valid  ),
        .res       ( a2        ),
        .down_valid( mult1_dv  ),
        .busy      ( mult1_busy),
        .error     ( mult1_err )
    );

    // mult2: a2 * a2 -> a4 (latency 3)
    f_mult mult2 (
        .clk       ( clk       ),
        .rst       ( rst       ),
        .a         ( a2        ),
        .b         ( a2        ),
        .up_valid  ( mult1_dv  ),
        .res       ( a4        ),
        .down_valid( mult2_dv  ),
        .busy      ( mult2_busy),
        .error     ( mult2_err )
    );

    // mult3: a4 * a_delay[5] -> a5 (latency 3)
    f_mult mult3 (
        .clk       ( clk          ),
        .rst       ( rst          ),
        .a         ( a4           ),
        .b         ( a_delay[5]   ),
        .up_valid  ( mult2_dv     ),
        .res       ( a5           ),
        .down_valid( mult3_dv     ),
        .busy      ( mult3_busy   ),
        .error     ( mult3_err    )
    );

    // add1: a5 + quot_delay[8] -> sum (latency 4)
    f_add add1 (
        .clk       ( clk           ),
        .rst       ( rst           ),
        .a         ( a5            ),
        .b         ( quot_delay[8] ),
        .up_valid  ( mult3_dv      ),
        .res       ( sum_val       ),
        .down_valid( add1_dv       ),
        .busy      ( add1_busy     ),
        .error     ( add1_err      )
    );

    // sub1: sum - c_delay[12] -> final_result (latency 3)
    f_sub sub1 (
        .clk       ( clk          ),
        .rst       ( rst          ),
        .a         ( sum_val      ),
        .b         ( c_delay[12]  ),
        .up_valid  ( add1_dv      ),
        .res       ( final_result ),
        .down_valid( sub1_dv      ),
        .busy      ( sub1_busy    ),
        .error     ( sub1_err     )
    );

    //----------------------------------------------------------------------
    // Output FIFO
    //----------------------------------------------------------------------

    reg [FLEN - 1:0] fifo_mem [0:FIFO_DEPTH - 1];
    reg [PTR_W:0]    fifo_wr_ptr;
    reg [PTR_W:0]    fifo_rd_ptr;

    wire [PTR_W:0] fifo_count = fifo_wr_ptr - fifo_rd_ptr;
    wire fifo_push = sub1_dv;
    wire fifo_pop  = res_vld & res_rdy;

    always @(posedge clk) begin
        if (rst) begin
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
        end else begin
            if (fifo_push) begin
                fifo_mem[fifo_wr_ptr[PTR_W - 1:0]] <= final_result;
                fifo_wr_ptr <= fifo_wr_ptr + 1'd1;
            end
            if (fifo_pop)
                fifo_rd_ptr <= fifo_rd_ptr + 1'd1;
        end
    end

    //----------------------------------------------------------------------
    // In-flight counter
    //----------------------------------------------------------------------

    reg [6:0] in_flight;

    always @(posedge clk) begin
        if (rst)
            in_flight <= '0;
        else
            in_flight <= in_flight + {6'd0, accepted} - {6'd0, sub1_dv};
    end

    //----------------------------------------------------------------------
    // Output handshake
    //----------------------------------------------------------------------

    assign res_vld = (fifo_count != 0);
    assign res     = fifo_mem[fifo_rd_ptr[PTR_W - 1:0]];

    //----------------------------------------------------------------------
    // Input ready
    //----------------------------------------------------------------------

    assign arg_rdy = ~rst & wr_slot_free
                   & (fifo_count + {1'b0, in_flight} < FIFO_DEPTH);

endmodule
