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
    // Constants
    //----------------------------------------------------------------------

    localparam [FLEN - 1:0] CONST_0_3 = 64'h3FD3333333333333; // 0.3 in double

    localparam PIPELINE_DEPTH = 16;
    localparam FIFO_DEPTH     = 32;
    localparam PTR_W          = $clog2(FIFO_DEPTH);

    //----------------------------------------------------------------------
    // Input handshake
    //----------------------------------------------------------------------

    wire accepted = arg_vld & arg_rdy;

    //----------------------------------------------------------------------
    // Arithmetic block wires
    //----------------------------------------------------------------------

    // mult1: a * a -> a2
    wire [FLEN - 1:0] a2;
    wire               mult1_down_valid;
    wire               mult1_busy;
    wire               mult1_error;

    // mult2: 0.3 * b -> p
    wire [FLEN - 1:0] p;
    wire               mult2_down_valid;
    wire               mult2_busy;
    wire               mult2_error;

    // mult3: a2 * a2 -> a4
    wire [FLEN - 1:0] a4;
    wire               mult3_down_valid;
    wire               mult3_busy;
    wire               mult3_error;

    // mult4: a4 * a_delayed -> a5
    wire [FLEN - 1:0] a5;
    wire               mult4_down_valid;
    wire               mult4_busy;
    wire               mult4_error;

    // add1: a5 + p_delayed -> sum
    wire [FLEN - 1:0] sum;
    wire               add1_down_valid;
    wire               add1_busy;
    wire               add1_error;

    // sub1: sum - c_delayed -> final_result
    wire [FLEN - 1:0] final_result;
    wire               sub1_down_valid;
    wire               sub1_busy;
    wire               sub1_error;

    //----------------------------------------------------------------------
    // Delay lines
    //----------------------------------------------------------------------

    // Delay 'a' by 6 cycles (need at cycle 6 for mult4)
    reg [FLEN - 1:0] a_delay [0:5];

    // Delay 'c' by 13 cycles (need at cycle 13 for sub1)
    reg [FLEN - 1:0] c_delay [0:12];

    // Delay 'p' (0.3*b) by 6 cycles (available cycle 3, need at cycle 9)
    reg [FLEN - 1:0] p_delay [0:5];

    integer i;

    always @(posedge clk) begin
        // a delay line
        a_delay[0] <= a;
        for (i = 1; i < 6; i = i + 1)
            a_delay[i] <= a_delay[i - 1];

        // c delay line
        c_delay[0] <= c;
        for (i = 1; i < 13; i = i + 1)
            c_delay[i] <= c_delay[i - 1];

        // p delay line (from mult2 output)
        p_delay[0] <= p;
        for (i = 1; i < 6; i = i + 1)
            p_delay[i] <= p_delay[i - 1];
    end

    //----------------------------------------------------------------------
    // Arithmetic block instantiations
    //----------------------------------------------------------------------

    // Stage 1a: a * a -> a2 (latency 3)
    f_mult mult1 (
        .clk      ( clk       ),
        .rst      ( rst       ),
        .a        ( a         ),
        .b        ( a         ),
        .up_valid ( accepted  ),
        .res      ( a2        ),
        .down_valid ( mult1_down_valid ),
        .busy     ( mult1_busy  ),
        .error    ( mult1_error )
    );

    // Stage 1b: 0.3 * b -> p (latency 3, parallel with mult1)
    f_mult mult2 (
        .clk      ( clk        ),
        .rst      ( rst        ),
        .a        ( CONST_0_3  ),
        .b        ( b          ),
        .up_valid ( accepted   ),
        .res      ( p          ),
        .down_valid ( mult2_down_valid ),
        .busy     ( mult2_busy  ),
        .error    ( mult2_error )
    );

    // Stage 2: a2 * a2 -> a4 (latency 3, starts at cycle 3)
    f_mult mult3 (
        .clk      ( clk              ),
        .rst      ( rst              ),
        .a        ( a2               ),
        .b        ( a2               ),
        .up_valid ( mult1_down_valid ),
        .res      ( a4               ),
        .down_valid ( mult3_down_valid ),
        .busy     ( mult3_busy  ),
        .error    ( mult3_error )
    );

    // Stage 3: a4 * a_delayed -> a5 (latency 3, starts at cycle 6)
    f_mult mult4 (
        .clk      ( clk              ),
        .rst      ( rst              ),
        .a        ( a4               ),
        .b        ( a_delay[5]       ),
        .up_valid ( mult3_down_valid ),
        .res      ( a5               ),
        .down_valid ( mult4_down_valid ),
        .busy     ( mult4_busy  ),
        .error    ( mult4_error )
    );

    // Stage 4: a5 + p_delayed -> sum (latency 4, starts at cycle 9)
    f_add add1 (
        .clk      ( clk              ),
        .rst      ( rst              ),
        .a        ( a5               ),
        .b        ( p_delay[5]       ),
        .up_valid ( mult4_down_valid ),
        .res      ( sum              ),
        .down_valid ( add1_down_valid ),
        .busy     ( add1_busy  ),
        .error    ( add1_error )
    );

    // Stage 5: sum - c_delayed -> final_result (latency 3, starts at cycle 13)
    f_sub sub1 (
        .clk      ( clk             ),
        .rst      ( rst             ),
        .a        ( sum             ),
        .b        ( c_delay[12]     ),
        .up_valid ( add1_down_valid ),
        .res      ( final_result    ),
        .down_valid ( sub1_down_valid ),
        .busy     ( sub1_busy  ),
        .error    ( sub1_error )
    );

    //----------------------------------------------------------------------
    // Output FIFO
    //----------------------------------------------------------------------

    reg [FLEN - 1:0] fifo_mem [0:FIFO_DEPTH - 1];
    reg [PTR_W:0]    fifo_wr_ptr;
    reg [PTR_W:0]    fifo_rd_ptr;

    wire [PTR_W:0] fifo_count = fifo_wr_ptr - fifo_rd_ptr;

    wire fifo_push = sub1_down_valid;
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
            if (fifo_pop) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1'd1;
            end
        end
    end

    //----------------------------------------------------------------------
    // In-flight counter (number of valid ops in pipeline, not yet in FIFO)
    //----------------------------------------------------------------------

    reg [5:0] in_flight;

    wire in_flight_inc = accepted;
    wire in_flight_dec = sub1_down_valid;

    always @(posedge clk) begin
        if (rst)
            in_flight <= '0;
        else
            in_flight <= in_flight + {5'd0, in_flight_inc} - {5'd0, in_flight_dec};
    end

    //----------------------------------------------------------------------
    // Output handshake
    //----------------------------------------------------------------------

    assign res_vld = (fifo_count != 0);
    assign res     = fifo_mem[fifo_rd_ptr[PTR_W - 1:0]];

    //----------------------------------------------------------------------
    // Input ready: accept if FIFO has room for all in-flight + 1 new
    //----------------------------------------------------------------------

    assign arg_rdy = ~rst & (fifo_count + {1'b0, in_flight} < FIFO_DEPTH);

endmodule
