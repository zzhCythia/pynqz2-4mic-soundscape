`timescale 1ns / 1ps

module i2s_clock_gen (
    input  wire sys_clk,
    input  wire rst_n,
    output reg  mic_sck,
    output reg  mic_ws
);
    // 从 125 MHz 生成平均 3.072 MHz 的 SCK。
    // 相位累加器用相邻的 sys_clk 间隔实现分数频率。
    // WS 每 32 个 SCK 下降沿切换一次。
    localparam integer CLK_HZ         = 125_000_000;
    localparam integer SCK_TOGGLE_HZ  = 6_144_000;

    reg [31:0] phase_acc;
    reg [5:0]  bit_count;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            phase_acc <= 32'd0;
            bit_count <= 6'd0;
            mic_sck   <= 1'b0;
            mic_ws    <= 1'b0;
        end else if (phase_acc >= (CLK_HZ - SCK_TOGGLE_HZ)) begin
            phase_acc <= phase_acc + SCK_TOGGLE_HZ - CLK_HZ;
            mic_sck   <= ~mic_sck;

            // 翻转前 mic_sck 为高，因此这里对应 SCK 下降沿。
            if (mic_sck) begin
                if (bit_count == 6'd63) begin
                    bit_count <= 6'd0;
                    mic_ws    <= 1'b0;
                end else begin
                    bit_count <= bit_count + 1'b1;

                    if (bit_count == 6'd31)
                        mic_ws <= 1'b1;
                end
            end
        end else begin
            phase_acc <= phase_acc + SCK_TOGGLE_HZ;
        end
    end
endmodule