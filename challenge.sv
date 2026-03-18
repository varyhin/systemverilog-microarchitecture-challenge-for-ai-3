/*

Put any submodules you need here.

You are not allowed to implement your own submodules or functions for the addition,
subtraction, multiplication, division, comparison or getting the square
root of floating-point numbers. For such operations you can only use the
modules from the arithmetic_block_wrappers directory.

*/

module challenge
(
    input  logic                clk,
    input  logic                rst,

    input  logic                arg_vld,
    output logic                arg_rdy,
    input  logic [FLEN - 1:0]  a,
    input  logic [FLEN - 1:0]  b,
    input  logic [FLEN - 1:0]  c,

    output logic                res_vld,
    input  logic                res_rdy,
    output logic [FLEN - 1:0]  res
);

    //----------------------------------------------------------------------
    // Constants and parameters
    //----------------------------------------------------------------------

    localparam logic [FLEN - 1:0] CONST_0_3 = 64'h3FD3333333333333;

    localparam int NUM_DIV    = 19;
    localparam int FIFO_DEPTH = 64;
    localparam int PTR_W      = $clog2(FIFO_DEPTH);
    localparam int DIV_PTR_W  = 5;

    //----------------------------------------------------------------------
    // Front-end: 19 round-robin dividers for 0.3 / b
    //----------------------------------------------------------------------

    logic [DIV_PTR_W - 1:0] slot_wr_ptr;
    logic [DIV_PTR_W - 1:0] slot_rd_ptr;

    logic [FLEN - 1:0] slot_a      [NUM_DIV];
    logic [FLEN - 1:0] slot_c      [NUM_DIV];
    logic [FLEN - 1:0] slot_quot   [NUM_DIV];
    logic               slot_active [NUM_DIV];
    logic               slot_done   [NUM_DIV];

    logic [FLEN - 1:0] div_res  [NUM_DIV];
    logic               div_dv   [NUM_DIV];
    logic               div_busy [NUM_DIV];
    logic               div_err  [NUM_DIV];
    logic               div_start [NUM_DIV];

    logic wr_slot_free;
    logic accepted;
    logic collect;

    assign wr_slot_free = !slot_active[slot_wr_ptr];
    assign accepted     = arg_vld & arg_rdy;
    assign collect      = slot_done[slot_rd_ptr];

    // Back-end feed signals
    logic [FLEN - 1:0] be_a;
    logic [FLEN - 1:0] be_c;
    logic [FLEN - 1:0] be_quot;
    logic               be_valid;

    assign be_a     = slot_a[slot_rd_ptr];
    assign be_c     = slot_c[slot_rd_ptr];
    assign be_quot  = slot_quot[slot_rd_ptr];
    assign be_valid = collect;

    // Divider start signals (combinational)
    always_comb begin
        for (int k = 0; k < NUM_DIV; k++)
            div_start[k] = 1'b0;

        if (accepted)
            div_start[slot_wr_ptr] = 1'b1;
    end

    // Divider instantiation
    for (genvar g = 0; g < NUM_DIV; g++) begin : div_inst
        f_div u_div (
            .clk       ( clk          ),
            .rst       ( rst          ),
            .a         ( CONST_0_3    ),
            .b         ( b            ),
            .up_valid  ( div_start[g] ),
            .res       ( div_res[g]   ),
            .down_valid( div_dv[g]    ),
            .busy      ( div_busy[g]  ),
            .error     ( div_err[g]   )
        );
    end

    // Pointer increment: modular wrap at NUM_DIV
    function automatic logic [DIV_PTR_W - 1:0] next_ptr(
        input logic [DIV_PTR_W - 1:0] ptr
    );
        return (ptr == DIV_PTR_W'(NUM_DIV - 1))
             ? DIV_PTR_W'(0)
             : ptr + DIV_PTR_W'(1);
    endfunction

    // Slot control logic
    always_ff @(posedge clk) begin
        if (rst) begin
            slot_wr_ptr <= '0;
            slot_rd_ptr <= '0;
            for (int j = 0; j < NUM_DIV; j++) begin
                slot_active[j] <= 1'b0;
                slot_done[j]   <= 1'b0;
            end
        end else begin
            if (accepted) begin
                slot_a[slot_wr_ptr]      <= a;
                slot_c[slot_wr_ptr]      <= c;
                slot_active[slot_wr_ptr] <= 1'b1;
                slot_wr_ptr              <= next_ptr(slot_wr_ptr);
            end

            for (int j = 0; j < NUM_DIV; j++) begin
                if (slot_active[j] && div_dv[j] && !slot_done[j]) begin
                    slot_quot[j] <= div_res[j];
                    slot_done[j] <= 1'b1;
                end
            end

            if (collect) begin
                slot_active[slot_rd_ptr] <= 1'b0;
                slot_done[slot_rd_ptr]   <= 1'b0;
                slot_rd_ptr              <= next_ptr(slot_rd_ptr);
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
        for (int i = 1; i < 6; i++)
            a_delay[i] <= a_delay[i - 1];

        quot_delay[0] <= be_quot;
        for (int i = 1; i < 9; i++)
            quot_delay[i] <= quot_delay[i - 1];

        c_delay[0] <= be_c;
        for (int i = 1; i < 13; i++)
            c_delay[i] <= c_delay[i - 1];
    end

    // Arithmetic block wires
    logic [FLEN - 1:0] a2, a4, a5, sum_val, final_result;
    logic mult1_dv, mult2_dv, mult3_dv, add1_dv, sub1_dv;
    logic mult1_busy, mult2_busy, mult3_busy, add1_busy, sub1_busy;
    logic mult1_err, mult2_err, mult3_err, sub1_err;
    wire  add1_err; // wire: f_add has dual-driver on error port internally

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
        .clk       ( clk        ),
        .rst       ( rst        ),
        .a         ( a4         ),
        .b         ( a_delay[5] ),
        .up_valid  ( mult2_dv   ),
        .res       ( a5         ),
        .down_valid( mult3_dv   ),
        .busy      ( mult3_busy ),
        .error     ( mult3_err  )
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

    logic [FLEN - 1:0] fifo_mem [FIFO_DEPTH];
    logic [PTR_W:0]    fifo_wr_ptr;
    logic [PTR_W:0]    fifo_rd_ptr;

    logic [PTR_W:0] fifo_count;
    logic            fifo_push;
    logic            fifo_pop;

    assign fifo_count = fifo_wr_ptr - fifo_rd_ptr;
    assign fifo_push  = sub1_dv;
    assign fifo_pop   = res_vld & res_rdy;

    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
        end else begin
            if (fifo_push) begin
                fifo_mem[fifo_wr_ptr[PTR_W - 1:0]] <= final_result;
                fifo_wr_ptr <= fifo_wr_ptr + (PTR_W + 1)'(1);
            end
            if (fifo_pop)
                fifo_rd_ptr <= fifo_rd_ptr + (PTR_W + 1)'(1);
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
            in_flight <= in_flight + {6'd0, accepted} - {6'd0, sub1_dv};
    end

    //----------------------------------------------------------------------
    // Output handshake
    //----------------------------------------------------------------------

    assign res_vld = (fifo_count != '0);
    assign res     = fifo_mem[fifo_rd_ptr[PTR_W - 1:0]];

    //----------------------------------------------------------------------
    // Input ready
    //----------------------------------------------------------------------

    assign arg_rdy = !rst & wr_slot_free
                   & (fifo_count + {1'b0, in_flight} < FIFO_DEPTH);

endmodule
