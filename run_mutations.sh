#!/bin/bash
cd /root/systemverilog-microarchitecture-challenge-for-ai-3

# Save current working solution
cp challenge.sv challenge_working.sv

PASS=0
FAIL=0
TOTAL=0
RESULTS=""

run_test() {
    local name="$1"
    local sed_cmd="$2"
    TOTAL=$((TOTAL + 1))

    cp challenge_working.sv challenge.sv
    eval "sed -i $sed_cmd challenge.sv"

    iverilog -g2012 \
        -I preprocessed_sources_from_openhwgroup_cvw \
        preprocessed_sources_from_openhwgroup_cvw/config.vh \
        preprocessed_sources_from_openhwgroup_cvw/*.sv \
        arithmetic_block_wrappers/*.sv \
        challenge.sv testbench.sv > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        RESULTS+="  DETECTED (compile error): $name\n"
        FAIL=$((FAIL + 1))
        return
    fi

    timeout 60 vvp a.out > mut_log.txt 2>&1
    rm -f a.out

    if grep -q 'PASS' mut_log.txt; then
        RESULTS+="  ESCAPED (still PASS!):    $name\n"
        PASS=$((PASS + 1))
    else
        RESULTS+="  DETECTED (FAIL/timeout):  $name\n"
        FAIL=$((FAIL + 1))
    fi
    rm -f mut_log.txt
}

echo "=== Mutation Testing (0.3/b division, FIFO=36, NUM_DIV=19) ==="
echo ""

# M1: f_add → f_sub (a5+quot → a5-quot)
run_test "M1: f_add → f_sub (a5+quot → a5-quot)" \
    "'s/f_add add1/f_sub add1/'"

# M2: f_sub → f_add (sum-c → sum+c)
run_test "M2: f_sub → f_add (sum-c → sum+c)" \
    "'s/f_sub sub1/f_add sub1/'"

# M3: Constant 0.3 → 0.4
run_test "M3: 0.3 → 0.4" \
    "'s/3FD3333333333333/3FD999999999999A/'"

# M4: a delay off by 1
run_test "M4: a delay off by 1 (a_delay[5] → a_delay[4])" \
    "'s/a_delay\[5\]/a_delay[4]/'"

# M5: c delay off by 1
run_test "M5: c delay off by 1 (c_delay[12] → c_delay[11])" \
    "'s/c_delay\[12\]/c_delay[11]/'"

# M6: Invert arg_rdy
run_test "M6: invert arg_rdy" \
    "'s/assign arg_rdy = !rst/assign arg_rdy = rst/'"

# M7: a^3 instead of a^5 (skip mult2, use a2 instead of a4)
run_test "M7: a^3 instead of a^5" \
    "'s/\.a         ( a4         )/\.a         ( a2         )/'"

# M8: Swap sub operands
run_test "M8: swap sub operands (c-sum instead of sum-c)" \
    "-e 's/\.a         ( sum_val      )/\.a         ( c_delay[12]  )/' -e 's/\.b         ( c_delay\[12\]  )/\.b         ( sum_val      )/'"

# M9: quot delay off by 1
run_test "M9: quot delay off by 1 (quot_delay[8] → quot_delay[7])" \
    "'s/quot_delay\[8\]/quot_delay[7]/'"

# M10: f_div → f_mult (division becomes multiplication)
run_test "M10: f_div → f_mult (0.3/b → 0.3*b)" \
    "'s/f_div u_div/f_mult u_div/'"

# M11: NUM_DIV 19 → 1 (expect timeout)
run_test "M11: NUM_DIV 19 → 1 (timeout)" \
    "'s/NUM_DIV    = 19/NUM_DIV    = 1/'"

# M12: Bypass FIFO
run_test "M12: bypass FIFO" \
    "-e \"s/assign res_vld = (fifo_count != '0);/assign res_vld = sub1_dv;/\" -e 's/assign res     = fifo_mem\[fifo_rd_idx\];/assign res     = final_result;/'"

# M13: FIFO_DEPTH too small (should break back-to-back or overflow)
run_test "M13: FIFO_DEPTH 36 → 2 (too small)" \
    "'s/FIFO_DEPTH = 36/FIFO_DEPTH = 2/'"

# M14: Wrong CONST (0.3 → 0.5)
run_test "M14: CONST 0.3 → 0.5" \
    "'s/3FD3333333333333/3FE0000000000000/'"

# Restore working solution
cp challenge_working.sv challenge.sv
rm -f challenge_working.sv

echo ""
echo "=== Results ==="
echo -e "$RESULTS"
echo "Detected: $FAIL / $TOTAL"
echo "Escaped:  $PASS / $TOTAL"
echo ""
if [ $PASS -eq 0 ]; then
    echo "ALL MUTATIONS DETECTED — testbench is robust"
else
    echo "WARNING: $PASS mutation(s) escaped — testbench has gaps"
fi
