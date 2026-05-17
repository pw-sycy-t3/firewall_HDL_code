`timescale 1ns / 1ps

module tb_bloom_filter;

    reg         rst;
    reg         clk;
    reg         ena;
    reg [103:0] tuple_in;
    reg         valid_in;
    reg         add_en;
    
    wire        match_out;
    wire        valid_out;

    bloom_filter #(
        .ADDR_WIDTH(9)
    ) dut (
        .rst(rst),
        .clk(clk),
        .ena(ena),
        .tuple_in(tuple_in),
        .valid_in(valid_in),
        .add_en(add_en),
        .match_out(match_out),
        .valid_out(valid_out)
    );

    always #1.55 clk = ~clk;

    localparam [103:0] TRUSTED_TUPLE = 104'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_11;
    localparam [103:0] HACKER_TUPLE  = 104'h9999_8888_7777_6666_5555_4444_22;

    initial begin
        $dumpfile("tb_bloom_filter.vcd");
        $dumpvars(0, tb_bloom_filter);

        clk = 0; rst = 1; ena = 1;
        valid_in = 0; add_en = 0; tuple_in = 0;

        #10 rst = 0;

        // 1. Zapis zaufanej reguły
        #10; @(posedge clk);
        valid_in <= 1; add_en <= 1; tuple_in <= TRUSTED_TUPLE;
        @(posedge clk);
        valid_in <= 0; add_en <= 0;
        
        // 2. Odczyt zaufanej reguły (Oczekiwane match = 1)
        #10; @(posedge clk);
        valid_in <= 1; tuple_in <= TRUSTED_TUPLE;
        @(posedge clk);
        valid_in <= 0;
        
        // 3. Pakiet intruza (Oczekiwane match = 0)
        #10; @(posedge clk);
        valid_in <= 1; tuple_in <= HACKER_TUPLE;
        @(posedge clk);
        valid_in <= 0;

        #20;
        $finish;
    end
endmodule