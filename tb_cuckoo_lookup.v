`timescale 1ns / 1ps

module tb_cuckoo_lookup;

    reg         rst;
    reg         clk;
    reg         ena;
    
    // Data Path
    reg [103:0] dp_tuple_in;
    reg         dp_valid_in;
    wire        dp_match_out;
    wire        dp_valid_out;
    
    // Control Path
    reg         cp_insert_req;
    reg [103:0] cp_tuple_in;
    wire        cp_insert_ready;
    wire        cp_insert_fail;

    cuckoo_lookup_fsm #(
        .ADDR_WIDTH(8),
        .MAX_KICKS(16)
    ) dut (
        .rst(rst), .clk(clk), .ena(ena),
        .dp_tuple_in(dp_tuple_in), .dp_valid_in(dp_valid_in),
        .dp_match_out(dp_match_out), .dp_valid_out(dp_valid_out),
        .cp_insert_req(cp_insert_req), .cp_tuple_in(cp_tuple_in),
        .cp_insert_ready(cp_insert_ready), .cp_insert_fail(cp_insert_fail)
    );

    always #1.55 clk = ~clk;

    localparam [103:0] TRUSTED = 104'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_11;
    localparam [103:0] HACKER  = 104'h9999_8888_7777_6666_5555_4444_22;

    initial begin
        $dumpfile("tb_cuckoo_lookup.vcd");
        $dumpvars(0, tb_cuckoo_lookup);

        clk = 0; rst = 1; ena = 1;
        dp_valid_in = 0; dp_tuple_in = 0;
        cp_insert_req = 0; cp_tuple_in = 0;

        #10 rst = 0;

        // 1. Zlecenie do FSM: Wstaw regule
        wait(cp_insert_ready == 1'b1); // Czekamy na gotowosc FSM
        @(posedge clk);
        cp_insert_req <= 1;
        cp_tuple_in <= TRUSTED;
        @(posedge clk);
        cp_insert_req <= 0;
        
        wait(cp_insert_ready == 1'b1); // Czekamy, az maszyna stanow skonczy zapis

        // 2. Data Path test: Zaufany pakiet
        #10; @(posedge clk);
        dp_valid_in <= 1;
        dp_tuple_in <= TRUSTED;
        @(posedge clk);
        dp_valid_in <= 0;

        // 3. Data Path test: Obcy pakiet
        #10; @(posedge clk);
        dp_valid_in <= 1;
        dp_tuple_in <= HACKER;
        @(posedge clk);
        dp_valid_in <= 0;

        #40;
        $finish;
    end
endmodule