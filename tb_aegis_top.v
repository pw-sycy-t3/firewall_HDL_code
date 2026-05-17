`timescale 1ns / 1ps

module tb_aegis_top;

    reg clk;
    reg rst;
    reg ena;
    
    // Zewnetrzny interfejs sieciowy
    reg [103:0] dp_tuple_in;
    reg         dp_valid_in;
    wire        decision_allow;
    wire        decision_drop;
    wire        decision_valid;
    
    // CPU Control Path
    reg         cp_l1_add_en;
    reg [103:0] cp_l1_tuple;
    reg         cp_l1_valid;
    reg         cp_l2_insert_req;
    reg [103:0] cp_l2_tuple;
    wire        cp_l2_ready;
    wire        cp_l2_fail;
    
    // Statystyki
    wire [31:0] stats_packets_in;
    wire [31:0] stats_l1_drops;
    wire [31:0] stats_l2_drops;
    wire [31:0] stats_allowed;

    aegis_zero_top #(
        .BLOOM_ADDR_WIDTH(9),
        .CUCKOO_ADDR_WIDTH(8)
    ) dut (
        .clk(clk), .rst(rst), .ena(ena),
        .dp_tuple_in(dp_tuple_in), .dp_valid_in(dp_valid_in),
        .decision_allow(decision_allow), .decision_drop(decision_drop), .decision_valid(decision_valid),
        .cp_l1_add_en(cp_l1_add_en), .cp_l1_tuple(cp_l1_tuple), .cp_l1_valid(cp_l1_valid),
        .cp_l2_insert_req(cp_l2_insert_req), .cp_l2_tuple(cp_l2_tuple),
        .cp_l2_ready(cp_l2_ready), .cp_l2_fail(cp_l2_fail),
        .stats_packets_in(stats_packets_in), .stats_l1_drops(stats_l1_drops),
        .stats_l2_drops(stats_l2_drops), .stats_allowed(stats_allowed)
    );

    always #1.55 clk = ~clk;

    localparam [103:0] TRUSTED = 104'hAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_11;
    localparam [103:0] HACKER  = 104'h9999_8888_7777_6666_5555_4444_22;

    initial begin
        $dumpfile("tb_aegis_top.vcd");
        $dumpvars(0, tb_aegis_top);

        clk = 0; rst = 1; ena = 1;
        dp_valid_in = 0; dp_tuple_in = 0;
        cp_l1_add_en = 0; cp_l1_valid = 0; cp_l1_tuple = 0;
        cp_l2_insert_req = 0; cp_l2_tuple = 0;

        #10 rst = 0;

     
        // KONFIGURACJA (Procesor dodaje regule do L1 i L2)

        #10;
        // Wpis do Blooma
        @(posedge clk);
        cp_l1_add_en <= 1; cp_l1_valid <= 1; cp_l1_tuple <= TRUSTED;
        @(posedge clk);
        cp_l1_add_en <= 0; cp_l1_valid <= 0;
        
        // Wpis do Cuckoo
        wait(cp_l2_ready);
        @(posedge clk);
        cp_l2_insert_req <= 1; cp_l2_tuple <= TRUSTED;
        @(posedge clk);
        cp_l2_insert_req <= 0;
        wait(cp_l2_ready); // Czekamy na koniec FSM

        // RUCH SIECIOWY 100 Gbps (Sprawdzamy przepustowosc)
        
        #20;
        // 1. Atak (Powinien zostac odrzucony od razu przez L1)
        @(posedge clk);
        dp_valid_in <= 1; dp_tuple_in <= HACKER;
        @(posedge clk);
        dp_valid_in <= 0;
        
        #20; // Czekamy, az pakiet przeplynie przez potok

        // 2. Autoryzowany (Powinien przejsc przez L1, FIFO i L2)
        @(posedge clk);
        dp_valid_in <= 1; dp_tuple_in <= TRUSTED;
        @(posedge clk);
        dp_valid_in <= 0;

        #50;
        
        // Szybki podglad statystyk na konsole
        $display("--- PODSUMOWANIE STATYSTYK SPRZETOWYCH ---");
        $display("Weszlo pakietow: %0d", stats_packets_in);
        $display("Odrzucone na L1: %0d", stats_l1_drops);
        $display("Odrzucone na L2: %0d", stats_l2_drops);
        $display("Wpuszczone (ALLOW): %0d", stats_allowed);
        
        $finish;
    end
endmodule