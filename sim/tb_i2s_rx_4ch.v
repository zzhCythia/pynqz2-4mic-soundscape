`timescale 1ns / 1ps

module tb_i2s_rx_4ch;
    reg sys_clk = 1'b0;
    reg rst_n   = 1'b0;
    reg mic_sck = 1'b0;
    reg mic_ws  = 1'b0;
    reg [1:0] mic_sd = 2'b00;

    wire signed [23:0] sample_ch0;
    wire signed [23:0] sample_ch1;
    wire signed [23:0] sample_ch2;
    wire signed [23:0] sample_ch3;
    wire sample_valid;

    always #5 sys_clk = ~sys_clk;

    i2s_rx_4ch dut (
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

    // 一个 32 位时隙：第一个周期是 I2S 对齐间隔，
    // 后续发送 24 位数据。sample_sd0 对应 mic_sd[0]，
    // sample_sd1 对应 mic_sd[1]。
    task send_slot;
        input        ws_value;
        input [23:0] sample_sd0;
        input [23:0] sample_sd1;
        integer bit_index;
        begin
            mic_ws = ws_value;

            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1) begin
                if ((bit_index >= 1) && (bit_index <= 24)) begin
                    mic_sd = {
                        sample_sd1[24-bit_index],
                        sample_sd0[24-bit_index]
                    };
                end else begin
                    mic_sd = 2'b00;
                end

                #100 mic_sck = 1'b1;
                #100 mic_sck = 1'b0;
            end
        end
    endtask

    initial begin
        #100;
        rst_n = 1'b1;
        #100;

        // 左声道：mic_sd[0] -> ch0，mic_sd[1] -> ch2
        send_slot(1'b0, 24'h812345, 24'hFEDCBA);

        // 右声道：mic_sd[0] -> ch1，mic_sd[1] -> ch3
        send_slot(1'b1, 24'h7ABCDE, 24'h123456);

        // sample_valid 在发送右声道期间已经脉冲，
        // 所以这里等待固定时间后检查样本。
        #20;

        if (sample_ch0 !== 24'h812345)
            $display("FAIL ch0: got %h expected 812345", sample_ch0);
        else
            $display("PASS ch0: %h", sample_ch0);

        if (sample_ch1 !== 24'h7ABCDE)
            $display("FAIL ch1: got %h expected 7ABCDE", sample_ch1);
        else
            $display("PASS ch1: %h", sample_ch1);

        if (sample_ch2 !== 24'hFEDCBA)
            $display("FAIL ch2: got %h expected FEDCBA", sample_ch2);
        else
            $display("PASS ch2: %h", sample_ch2);

        if (sample_ch3 !== 24'h123456)
            $display("FAIL ch3: got %h expected 123456", sample_ch3);
        else
            $display("PASS ch3: %h", sample_ch3);

        $finish;
    end
endmodule