`timescale 1ns / 1ps

module board_display_ctrl (
    input clk,
    input rst,
    input [1:0] sw_select,
    
    // Podlaczenie do statystyk z modułu Top-Level
    input [31:0] stat_packets_in,
    input [31:0] stat_l1_drops,
    input [31:0] stat_l2_drops,
    input [31:0] stat_allowed,
    
    // Fizyczne piny na płytce
    output reg [6:0] seg, // Segmenty A-G (aktywne zerem)
    output reg [7:0] an   // Anody wyswietlacza (aktywne zerem)
);

    // Wybor wyswietlanej statystyki na podstawie przelacznikow
    reg [31:0] current_stat;
    always @(*) begin
        case(sw_select)
            2'b00: current_stat = stat_packets_in;
            2'b01: current_stat = stat_l1_drops;
            2'b10: current_stat = stat_l2_drops;
            2'b11: current_stat = stat_allowed;
        endcase
    end

    // Dzielnik zegara do odswiezania wyswietlacza (okolo 1 kHz)
    // Zakladajac zegar np. 100MHz z plytki (nie 322MHz z rdzenia Ethernet)
    reg [16:0] refresh_counter;
    always @(posedge clk or posedge rst) begin
        if (rst) refresh_counter <= 0;
        else refresh_counter <= refresh_counter + 1;
    end
    
    // 3 najstarsze bity licznika wybieraja aktywna cyfre (0-7)
    wire [2:0] digit_select = refresh_counter[16:14];
    
    // Wyodrebnienie 4 bitow do wyswietlenia na aktywnej cyfrze
    reg [3:0] hex_digit;
    always @(*) begin
        case(digit_select)
            3'd0: hex_digit = current_stat[3:0];
            3'd1: hex_digit = current_stat[7:4];
            3'd2: hex_digit = current_stat[11:8];
            3'd3: hex_digit = current_stat[15:12];
            3'd4: hex_digit = current_stat[19:16];
            3'd5: hex_digit = current_stat[23:20];
            3'd6: hex_digit = current_stat[27:24];
            3'd7: hex_digit = current_stat[31:28];
        endcase
    end

    // Dekoder Hex na 7-segmentowy (Wspolna anoda, czyli 0 wlacza segment)
    always @(*) begin
        case(hex_digit)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            4'hF: seg = 7'b0001110;
            default: seg = 7'b1111111;
        endcase
    end

    // Sterowanie anodami - wlaczamy tylko jedna cyfre w danym momencie
    always @(*) begin
        an = 8'b11111111; 
        an[digit_select] = 1'b0; 
    end

endmodule