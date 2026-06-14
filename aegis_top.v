`timescale 1ns / 1ps

/**
 * @file
 * @brief Top-level AEGIS-ZERO pipeline and the sync_fifo buffer module it uses.
 *
 * Contains two modules: sync_fifo, a synchronous FIFO buffer used between
 * pipeline layers, and aegis_top, the top-level pipeline that integrates
 * the Layer 1 Bloom filter and Layer 2 Cuckoo hash lookup engine into the
 * AEGIS-ZERO hardware firewall.
 */

/**
 * @brief Simple synchronous FIFO buffer used between pipeline layers.
 *
 * Decouples the Layer 1 Bloom filter pre-screening stage from the
 * Layer 2 Cuckoo hash lookup stage, absorbing timing differences
 * between the two layers.
 *
 * @param DATA_WIDTH Width of each stored data word, in bits.
 * @param DEPTH_LOG  Log2 of the FIFO depth (number of storage slots).
 *
 * @param clk    System clock.
 * @param rst    Asynchronous reset, active high.
 * @param wr_en  Write enable.
 * @param din    Data word to write.
 * @param rd_en  Read enable.
 * @param dout   Data word at the head of the FIFO.
 * @param empty  Asserted when the FIFO holds no data.
 * @param full   Asserted when the FIFO cannot accept further writes.
 */
// Prosta kolejka synchroniczna FIFO miedzy warstwami
module sync_fifo #(
    parameter DATA_WIDTH = 104,
    parameter DEPTH_LOG = 4
)(
    input clk,
    input rst,
    input wr_en,
    input [DATA_WIDTH-1:0] din,
    input rd_en,
    output [DATA_WIDTH-1:0] dout,
    output empty,
    output full
);
    reg [DATA_WIDTH-1:0] mem [0:(1<<DEPTH_LOG)-1];
    reg [DEPTH_LOG-1:0] wr_ptr;
    reg [DEPTH_LOG-1:0] rd_ptr;
    reg [DEPTH_LOG:0] count;

    assign full = (count == (1<<DEPTH_LOG));
    assign empty = (count == 0);
    assign dout = mem[rd_ptr];

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
            for(i=0; i<(1<<DEPTH_LOG); i=i+1) mem[i] <= 0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr] <= din;
                wr_ptr <= wr_ptr + 1;
            end
            if (rd_en && !empty) begin
                rd_ptr <= rd_ptr + 1;
            end
            
            if (wr_en && !full && (!rd_en || empty))
                count <= count + 1;
            else if (rd_en && !empty && (!wr_en || full))
                count <= count - 1;
        end
    end
endmodule


/**
 * @brief Top-level pipeline of the AEGIS-ZERO hardware firewall.
 *
 * Integrates the Layer 1 Bloom filter pre-screening stage
 * (bloom_filter) with the Layer 2 Cuckoo hash lookup engine
 * (cuckoo_lookup_fsm) through a sync_fifo buffer, and produces the
 * final accept/drop decision together with hardware traffic counters.
 *
 * @param BLOOM_ADDR_WIDTH  Address width of the Layer 1 Bloom filter table.
 * @param CUCKOO_ADDR_WIDTH Address width of each Layer 2 Cuckoo hash bank.
 *
 * @param clk              System clock.
 * @param rst              Synchronous reset, active high.
 * @param ena              Global pipeline enable.
 * @param dp_tuple_in      Incoming 5-tuple (104 bits) from the data path.
 * @param dp_valid_in      Valid flag for dp_tuple_in.
 * @param decision_allow   Final verdict: packet is allowed.
 * @param decision_drop    Final verdict: packet is dropped.
 * @param decision_valid   Valid flag for the decision outputs.
 * @param cp_l1_add_en     Control path: enable adding a tuple to the Bloom filter.
 * @param cp_l1_tuple      Control path: 5-tuple to add to the Bloom filter.
 * @param cp_l1_valid      Control path: valid flag for cp_l1_tuple.
 * @param cp_l2_insert_req Control path: request to insert a tuple into the Cuckoo tables.
 * @param cp_l2_tuple      Control path: 5-tuple to insert into the Cuckoo tables.
 * @param cp_l2_ready      Control path: Cuckoo insertion engine ready for a new request.
 * @param cp_l2_fail       Control path: Cuckoo insertion failed (table full).
 * @param stats_packets_in Hardware counter: total packets received.
 * @param stats_l1_drops   Hardware counter: packets dropped by Layer 1.
 * @param stats_l2_drops   Hardware counter: packets dropped by Layer 2.
 * @param stats_allowed    Hardware counter: packets allowed through.
 */
// Glowny modul systemu AEGIS-ZERO
module aegis_top #(
    parameter BLOOM_ADDR_WIDTH = 9,
    parameter CUCKOO_ADDR_WIDTH = 8
)(
    input clk,
    input rst,
    input ena,
    
    // Data path wejscie
    input [103:0] dp_tuple_in,
    input dp_valid_in,
    
    // Data path wyjscie (decyzja)
    output reg decision_allow,
    output reg decision_drop,
    output reg decision_valid,
    
    // Control path L1 (Bloom)
    input cp_l1_add_en,
    input [103:0] cp_l1_tuple,
    input cp_l1_valid,
    
    // Control path L2 (Cuckoo)
    input cp_l2_insert_req,
    input [103:0] cp_l2_tuple,
    output cp_l2_ready,
    output cp_l2_fail,
    
    // Statystyki sprzetowe
    output reg [31:0] stats_packets_in,
    output reg [31:0] stats_l1_drops,
    output reg [31:0] stats_l2_drops,
    output reg [31:0] stats_allowed
);

    // Rejestr opozniajacy klucz, aby zrownac sie z 1-cyklowym czasem L1
    reg [103:0] dp_tuple_q;
    always @(posedge clk) begin
        if (ena) dp_tuple_q <= dp_tuple_in;
    end

    // Sygnaly z Layer 1
    wire l1_match;
    wire l1_valid;

    bloom_filter #(
        .ADDR_WIDTH(BLOOM_ADDR_WIDTH)
    ) layer1_bloom (
        .rst(rst),
        .clk(clk),
        .ena(ena),
        // Wybor wejscia miedzy ruchem a interfejsem sterujacym
        .tuple_in(cp_l1_add_en ? cp_l1_tuple : dp_tuple_in),
        .valid_in(cp_l1_add_en ? cp_l1_valid : dp_valid_in),
        .add_en(cp_l1_add_en),
        .match_out(l1_match),
        .valid_out(l1_valid)
    );

    // Sygnaly kolejki FIFO
    wire fifo_full;
    wire fifo_empty;
    wire [103:0] fifo_dout;
    
    wire l1_drop_condition = l1_valid && !l1_match;
    wire l1_pass_condition = l1_valid && l1_match;
    wire fifo_wr_en = l1_pass_condition && !fifo_full;
    wire fifo_rd_en = !fifo_empty; 

    sync_fifo #(
        .DATA_WIDTH(104),
        .DEPTH_LOG(4) // 16 elementow bufora
    ) l1_to_l2_fifo (
        .clk(clk),
        .rst(rst),
        .wr_en(fifo_wr_en),
        .din(dp_tuple_q),
        .rd_en(fifo_rd_en),
        .dout(fifo_dout),
        .empty(fifo_empty),
        .full(fifo_full)
    );

    // Sygnaly z Layer 2
    wire l2_match;
    wire l2_valid;
    wire [103:0] l2_tuple_in = fifo_dout;

    cuckoo_lookup_fsm #(
        .ADDR_WIDTH(CUCKOO_ADDR_WIDTH),
        .MAX_KICKS(16)
    ) layer2_cuckoo (
        .rst(rst),
        .clk(clk),
        .ena(ena),
        .dp_tuple_in(l2_tuple_in),
        .dp_valid_in(fifo_rd_en), // Czytamy z FIFO tylko jesli nie jest puste
        .dp_match_out(l2_match),
        .dp_valid_out(l2_valid),
        .cp_insert_req(cp_l2_insert_req),
        .cp_tuple_in(cp_l2_tuple),
        .cp_insert_ready(cp_l2_ready),
        .cp_insert_fail(cp_l2_fail)
    );

    // Logika decyzyjna i liczniki statystyk
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            decision_allow <= 0;
            decision_drop <= 0;
            decision_valid <= 0;
            stats_packets_in <= 0;
            stats_l1_drops <= 0;
            stats_l2_drops <= 0;
            stats_allowed <= 0;
        end else if (ena) begin
            // Domyslnie brak decyzji
            decision_valid <= 0;
            decision_allow <= 0;
            decision_drop <= 0;

            // Zliczanie wszystkich pakietow wejsciowych
            if (dp_valid_in) begin
                stats_packets_in <= stats_packets_in + 1;
            end

            // Pakiet odrzucony natychmiast w Layer 1
            if (l1_drop_condition) begin
                decision_valid <= 1;
                decision_drop <= 1;
                decision_allow <= 0;
                stats_l1_drops <= stats_l1_drops + 1;
            end
            
            // Wynik weryfikacji z Layer 2
            if (l2_valid) begin
                decision_valid <= 1;
                if (l2_match) begin
                    decision_allow <= 1;
                    decision_drop <= 0;
                    stats_allowed <= stats_allowed + 1;
                end else begin
                    decision_allow <= 0;
                    decision_drop <= 1;
                    stats_l2_drops <= stats_l2_drops + 1;
                end
            end
        end
    end

endmodule