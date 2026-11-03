`timescale 1ns / 1ps

module mic4_top (
    input  wire       sys_clk,
    input  wire [1:0] mic_sd,
    output wire       mic_sck,
    output wire       mic_ws
);
    // 配置完成后短暂等待，再启动时钟和接收逻辑。
    reg [7:0] startup_count = 8'd0;
    reg       rst_n = 1'b0;

    // 标记为调试信号，后续可在 Vivado 中接入 ILA。
    (* MARK_DEBUG = "TRUE" *) wire signed [23:0] sample_ch0;
    (* MARK_DEBUG = "TRUE" *) wire signed [23:0] sample_ch1;
    (* MARK_DEBUG = "TRUE" *) wire signed [23:0] sample_ch2;
    (* MARK_DEBUG = "TRUE" *) wire signed [23:0] sample_ch3;
    (* MARK_DEBUG = "TRUE" *) wire               sample_valid;

    always @(posedge sys_clk) begin
        if (!rst_n) begin
            if (&startup_count)
                rst_n <= 1'b1;
            else
                startup_count <= startup_count + 1'b1;
        end
    end

    i2s_clock_gen u_clock_gen (
        .sys_clk (sys_clk),
        .rst_n   (rst_n),
        .mic_sck (mic_sck),
        .mic_ws  (mic_ws)
    );

    i2s_rx_4ch u_rx (
        .sys_clk      (sys_clk),
        .rst_n        (rst_n),
        .mic_sck      (mic_sck),
        .mic_ws       (mic_ws),
        .mic_sd       (mic_sd),
        .sample_ch0   (sample_ch0),
        .sample_ch1   (sample_ch1),
        .sample_ch2   (sample_ch2),
        .sample_ch3   (sample_ch3),
        .sample_valid (sample_valid)
    );
endmodule