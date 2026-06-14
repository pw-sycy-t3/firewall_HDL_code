`timescale 1ns / 1ps

/**
 * @file
 * @brief Layer 1 probabilistic pre-filter (Bloom filter) for the AEGIS-ZERO pipeline.
 */

/**
 * @brief Layer 1 probabilistic pre-filter (Bloom filter).
 *
 * Implements a Bloom filter using three independent XOR-fold hash
 * functions over a 5-tuple and a single distributed-RAM bit array.
 * A negative result guarantees the tuple was never inserted, allowing
 * the pipeline to drop unknown traffic in a single clock cycle.
 *
 * @param ADDR_WIDTH Address width of the bit array (table size = 2^ADDR_WIDTH).
 *
 * @param rst       Asynchronous reset, active high.
 * @param clk       System clock.
 * @param ena       Clock enable.
 * @param tuple_in  5-tuple (104 bits) to check or insert.
 * @param valid_in  Valid flag for tuple_in.
 * @param add_en    1 = insert tuple_in into the filter, 0 = look up tuple_in.
 * @param match_out Lookup result: 1 if all three hashed bits are set.
 * @param valid_out Valid flag for match_out.
 */
module bloom_filter
#(
    parameter ADDR_WIDTH = 9 // 2^9 = 512 bitów
)
(
    input                    rst,       // Reset aktywny stanem wysokim
    input                    clk,
    input                    ena,       // Zegar aktywny (enable)
    input      [103:0]       tuple_in,  // 5-krotka
    input                    valid_in,  // Zastępuje "start" (ważność wejścia)
    input                    add_en,    // 1 = zapis, 0 = odczyt
    output reg               match_out, // Zastępuje "res"
    output reg               valid_out  // Zastępuje "rdy"
);

    // Tablica pamięci BRAM
    reg [0:0] bloom_ram [0:(1<<ADDR_WIDTH)-1];

    // Rejestry stanów następnych dla logiki mikrooperacji
    reg match_out_next;
    reg valid_out_next;

    // =========================================================================
    // Logika kombinacyjna: Funkcje haszujące XOR-Fold (Drzewo bramek)
    // =========================================================================
    wire [31:0] part1 = tuple_in[31:0];
    wire [31:0] part2 = tuple_in[63:32];
    wire [31:0] part3 = tuple_in[95:64];
    wire [31:0] part4 = {24'd0, tuple_in[103:96]};

    localparam SEED1 = 32'hDEADBEEF;
    localparam SEED2 = 32'hCAFEBABE;
    localparam SEED3 = 32'h12345678;

    wire [31:0] mix1 = (part1 ^ SEED1) ^ part2 ^ part3 ^ part4;
    wire [31:0] mix2 = (part1 ^ SEED2) ^ part2 ^ part3 ^ part4;
    wire [31:0] mix3 = (part1 ^ SEED3) ^ part2 ^ part3 ^ part4;

    wire [31:0] fold1 = mix1 ^ (mix1 >> 16);
    wire [31:0] fold2 = mix2 ^ (mix2 >> 16);
    wire [31:0] fold3 = mix3 ^ (mix3 >> 16);

    wire [ADDR_WIDTH-1:0] addr1 = fold1[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] addr2 = fold2[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] addr3 = fold3[ADDR_WIDTH-1:0];

    // =========================================================================
    // Registers (Logika sekwencyjna)
    // =========================================================================
    integer i;
    always@(posedge clk, posedge rst) begin
        if (rst) begin
            match_out <= 0;
            valid_out <= 0;
            
            // Zerowanie BRAM dla symulacji
            for (i = 0; i < (1<<ADDR_WIDTH); i = i + 1) begin
                bloom_ram[i] <= 0;
            end
        end
        else if (ena) begin
            match_out <= match_out_next;
            valid_out <= valid_out_next;
            
            // Zapis do pamięci RAM musi odbywać się synchronicznie
            if (valid_in && add_en) begin
                bloom_ram[addr1] <= 1;
                bloom_ram[addr2] <= 1;
                bloom_ram[addr3] <= 1;
            end
        end     
    end
    
    // =========================================================================
    // Microoperation logic (Logika wyznaczania stanu następnego)
    // =========================================================================
    always@(*) begin
        // Domyślne wartości zapobiegają powstawaniu Latchy (zatrzasków)
        match_out_next = 0;
        valid_out_next = 0;
        
        if (valid_in) begin
            valid_out_next = 1;
            
            if (!add_en) begin
                // Weryfikacja: Równoległy odczyt + bramka AND
                match_out_next = bloom_ram[addr1] & bloom_ram[addr2] & bloom_ram[addr3];
            end
        end
    end

endmodule