`timescale 1ns / 1ps

/**
 * @file
 * @brief Layer 2 exact-match lookup engine (3-ary Cuckoo hashing) for the AEGIS-ZERO pipeline.
 */

/**
 * @brief Layer 2 exact-match lookup engine (3-ary Cuckoo hashing).
 *
 * Stores 5-tuples in three independent hash table banks and performs
 * O(1) exact-match lookups on the data path. The control path FSM
 * inserts new entries, evicting ("kicking") existing entries between
 * banks when all three candidate slots are occupied, up to MAX_KICKS
 * attempts.
 *
 * @param ADDR_WIDTH Address width of each hash table bank (entries per bank = 2^ADDR_WIDTH).
 * @param MAX_KICKS  Maximum number of evictions attempted during insertion before reporting failure.
 *
 * @param rst             Asynchronous reset, active high.
 * @param clk             System clock.
 * @param ena             Clock enable.
 * @param dp_tuple_in     Data path: 5-tuple to look up.
 * @param dp_valid_in     Data path: valid flag for dp_tuple_in.
 * @param dp_match_out    Data path: 1 if dp_tuple_in was found in any bank.
 * @param dp_valid_out    Data path: valid flag for dp_match_out.
 * @param cp_insert_req   Control path: request to insert cp_tuple_in.
 * @param cp_tuple_in     Control path: 5-tuple to insert.
 * @param cp_insert_ready Control path: engine ready to accept a new insert request.
 * @param cp_insert_fail  Control path: insertion failed after MAX_KICKS evictions.
 */
module cuckoo_lookup_fsm
#(
    parameter ADDR_WIDTH = 8,
    parameter MAX_KICKS = 16 // Zabezpieczenie przed nieskończoną pętlą wypchnięć
)
(
    input                    rst,
    input                    clk,
    input                    ena,
    
    // DATA PATH
    input      [103:0]       dp_tuple_in,  
    input                    dp_valid_in,  
    output reg               dp_match_out, 
    output reg               dp_valid_out, 
    

    // CONTROL PATH
    input                    cp_insert_req,   
    input      [103:0]       cp_tuple_in,    
    output reg               cp_insert_ready,
    output reg               cp_insert_fail
);

    
    // Pamięci (3 niezależne banki True Dual-Port)
    
    reg [104:0] bank0 [0:(1<<ADDR_WIDTH)-1];
    reg [104:0] bank1 [0:(1<<ADDR_WIDTH)-1];
    reg [104:0] bank2 [0:(1<<ADDR_WIDTH)-1];

    // 
    // FUNKCJE HASZUJĄCE
    // 
    function [ADDR_WIDTH-1:0] calc_hash;
        input [103:0] tuple;
        input [31:0] seed;
        reg [31:0] p1, p2, p3, p4, mix;
        begin
            p1 = tuple[31:0];
            p2 = tuple[63:32];
            p3 = tuple[95:64];
            p4 = {24'd0, tuple[103:96]};
            mix = (p1 ^ seed) ^ (p2 << 1) ^ (p3 >> 1) ^ p4;
            calc_hash = mix[ADDR_WIDTH-1:0];
        end
    endfunction

    // Adresy dla ścieżki danych
    wire [ADDR_WIDTH-1:0] dp_addr0 = calc_hash(dp_tuple_in, 32'hAAAA_AAAA);
    wire [ADDR_WIDTH-1:0] dp_addr1 = calc_hash(dp_tuple_in, 32'h5555_5555);
    wire [ADDR_WIDTH-1:0] dp_addr2 = calc_hash(dp_tuple_in, 32'h9999_9999);

    // Adresy dla maszyny stanów
    reg  [103:0] cp_current_tuple; 
    wire [ADDR_WIDTH-1:0] cp_addr0 = calc_hash(cp_current_tuple, 32'hAAAA_AAAA);
    wire [ADDR_WIDTH-1:0] cp_addr1 = calc_hash(cp_current_tuple, 32'h5555_5555);
    wire [ADDR_WIDTH-1:0] cp_addr2 = calc_hash(cp_current_tuple, 32'h9999_9999);

    
    // DATA PATH: Logika Sekwencyjna i Kombinacyjna (Niezależna od FSM)
    reg [104:0] dp_rdata0, dp_rdata1, dp_rdata2;
    reg [103:0] dp_tuple_q;
    reg         dp_valid_q;
    
    always @(posedge clk) begin
        if (ena) begin
            // PORT A: Odczyt
            dp_rdata0  <= bank0[dp_addr0];
            dp_rdata1  <= bank1[dp_addr1];
            dp_rdata2  <= bank2[dp_addr2];
            dp_tuple_q <= dp_tuple_in;
            dp_valid_q <= dp_valid_in;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dp_match_out <= 0;
            dp_valid_out <= 0;
        end else if (ena) begin
            dp_valid_out <= dp_valid_q;
            if (dp_valid_q) begin
                if ((dp_rdata0[104] && dp_rdata0[103:0] == dp_tuple_q) ||
                    (dp_rdata1[104] && dp_rdata1[103:0] == dp_tuple_q) ||
                    (dp_rdata2[104] && dp_rdata2[103:0] == dp_tuple_q))
                    dp_match_out <= 1; // MATCH!
                else
                    dp_match_out <= 0; // MISS
            end else begin
                dp_match_out <= 0;
            end
        end
    end


    // CONTROL PATH
    localparam STATE_IDLE       = 3'd0;
    localparam STATE_READ_BANKS = 3'd1;
    localparam STATE_EVAL_KICK  = 3'd2;

    reg [2:0]  state, next_state;
    reg [7:0]  kick_counter, next_kick_counter;
    reg [103:0] next_cp_current_tuple;
    
    reg [104:0] cp_rdata0, cp_rdata1, cp_rdata2;
    reg [1:0]   lfsr_bank; // Prosty licznik decydujący, kogo wypchnąć

    // Rejestry FSM (Sekwencyjne)
    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= STATE_IDLE;
            kick_counter <= 0;
            cp_current_tuple <= 0;
            lfsr_bank <= 0;
            cp_insert_ready <= 1;
            cp_insert_fail <= 0;
            
            for(i=0; i<(1<<ADDR_WIDTH); i=i+1) begin
                bank0[i] <= 0; bank1[i] <= 0; bank2[i] <= 0;
            end
        end else if (ena) begin
            state <= next_state;
            kick_counter <= next_kick_counter;
            cp_current_tuple <= next_cp_current_tuple;
            lfsr_bank <= lfsr_bank + 1; // Zmienia się co cykl (pseudo-random dla kicka)
            if (lfsr_bank == 3) lfsr_bank <= 0;

            // Wykonanie stanów maszyny (Odczyty i Zapisy na Porcie B)
            case (state)
                STATE_IDLE: begin
                    cp_insert_fail <= 0;
                    if (cp_insert_req) begin
                        cp_insert_ready <= 0;
                    end else begin
                        cp_insert_ready <= 1;
                    end
                end
                
                STATE_READ_BANKS: begin
                    // PORT B: Odczyt zawartości komórek, by sprawdzić czy są puste
                    cp_rdata0 <= bank0[cp_addr0];
                    cp_rdata1 <= bank1[cp_addr1];
                    cp_rdata2 <= bank2[cp_addr2];
                end
                
                STATE_EVAL_KICK: begin
                    // PORT B: Decyzja i Zapis
                    if (!cp_rdata0[104]) begin // Bit [104] to VALID. 0 = puste!
                        bank0[cp_addr0] <= {1'b1, cp_current_tuple};
                    end 
                    else if (!cp_rdata1[104]) begin
                        bank1[cp_addr1] <= {1'b1, cp_current_tuple};
                    end 
                    else if (!cp_rdata2[104]) begin
                        bank2[cp_addr2] <= {1'b1, cp_current_tuple};
                    end 
                    else begin
                        // Wszystkie pełne, trzeba wypchnąć jeden element i wstawić nowy
            
                        if (lfsr_bank == 0)      bank0[cp_addr0] <= {1'b1, cp_current_tuple};
                        else if (lfsr_bank == 1) bank1[cp_addr1] <= {1'b1, cp_current_tuple};
                        else                     bank2[cp_addr2] <= {1'b1, cp_current_tuple};
                    end
                    
                    // Raportowanie ewentualnej awarii (Tablica pełna)
                    if (kick_counter == MAX_KICKS) begin
                        cp_insert_fail <= 1;
                        cp_insert_ready <= 1;
                    end
                end
            endcase
        end
    end

    // Logika wyznaczania stanu następnego (Kombinacyjna)
    always @* begin
        next_state = state;
        next_kick_counter = kick_counter;
        next_cp_current_tuple = cp_current_tuple;

        case (state)
            STATE_IDLE: begin
                if (cp_insert_req && cp_insert_ready) begin
                    next_cp_current_tuple = cp_tuple_in;
                    next_kick_counter = 0;
                    next_state = STATE_READ_BANKS;
                end
            end
            
            STATE_READ_BANKS: begin
                next_state = STATE_EVAL_KICK;
            end
            
            STATE_EVAL_KICK: begin
                // brak wypchnięcia - sukces
                if (!cp_rdata0[104] || !cp_rdata1[104] || !cp_rdata2[104]) begin
                    next_state = STATE_IDLE; 
                end else begin
                    // Wszystkie pełne - wypchnięcie
                    if (kick_counter == MAX_KICKS) begin
                        next_state = STATE_IDLE; // Fail
                    end else begin
                        next_kick_counter = kick_counter + 1;
                        next_state = STATE_READ_BANKS; // Szukanie miejsca dla kolejnego wypchniętego elementu
                        
                        // wypchnięty element jako nowy "current"
                        if (lfsr_bank == 0)      next_cp_current_tuple = cp_rdata0[103:0];
                        else if (lfsr_bank == 1) next_cp_current_tuple = cp_rdata1[103:0];
                        else                     next_cp_current_tuple = cp_rdata2[103:0];
                    end
                end
            end
        endcase
    end

endmodule