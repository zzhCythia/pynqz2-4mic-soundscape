`timescale 1ns / 1ps

module tb_mic4_top;

    reg sys_clk = 1'b0;
    reg [1:0] mic_sd = 2'b00;

    wire mic_sck;
    wire mic_ws;

    integer bit_index;
    reg ws_seen;

    reg [23:0] sd0_word;
    reg [23:0] sd1_word;

    always #4 sys_clk = ~sys_clk;

    mic4_top dut (
        .sys_clk (sys_clk),
        .mic_sd  (mic_sd),
        .mic_sck (mic_sck),
        .mic_ws  (mic_ws)
    );

    // 等待顶层内部复位结束
    initial begin
        mic_sd    = 2'b00;
        bit_index = 0;
        ws_seen   = 1'b0;

        wait (dut.rst_n === 1'b1);

        ws_seen   = mic_ws;
        bit_index = 0;
    end

    // 在 SCK 下降沿准备下一位数据
    always @(negedge mic_sck) begin
        #1;

        if (!dut.rst_n) begin
            mic_sd    = 2'b00;
            bit_index = 0;
            ws_seen   = mic_ws;
        end else begin

            // WS 变化后，第一个 SCK 周期是 I²S 对齐间隔
            if (mic_ws != ws_seen) begin
                ws_seen   = mic_ws;
                bit_index = 0;
            end else begin
                bit_index = bit_index + 1;
            end

            if (!mic_ws) begin
                // 左声道
                sd0_word = 24'h812345;
                sd1_word = 24'hFEDCBA;
            end else begin
                // 右声道
                sd0_word = 24'h7ABCDE;
                sd1_word = 24'h123456;
            end

            if ((bit_index >= 1) && (bit_index <= 24)) begin
                mic_sd = {
                    sd1_word[24-bit_index],
                    sd0_word[24-bit_index]
                };
            end else begin
                mic_sd = 2'b00;
            end
        end
    end

    initial begin
        // 等待至少一个完整的左右声道周期
        #30000;

        $display("ch0 = %h", dut.sample_ch0);
        $display("ch1 = %h", dut.sample_ch1);
        $display("ch2 = %h", dut.sample_ch2);
        $display("ch3 = %h", dut.sample_ch3);

        if (dut.sample_ch0 === 24'h812345)
            $display("PASS ch0");
        else
            $display("FAIL ch0");

        if (dut.sample_ch1 === 24'h7ABCDE)
            $display("PASS ch1");
        else
            $display("FAIL ch1");

        if (dut.sample_ch2 === 24'hFEDCBA)
            $display("PASS ch2");
        else
            $display("FAIL ch2");

        if (dut.sample_ch3 === 24'h123456)
            $display("PASS ch3");
        else
            $display("FAIL ch3");

       $finish;
    end

endmodule