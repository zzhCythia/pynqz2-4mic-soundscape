`timescale 1ns / 1ps

module tb_i2s_clock_gen;

    reg sys_clk;
    reg rst_n;

    wire mic_sck;
    wire mic_ws;

    integer sck_rise_count;
    integer ws_change_count;
    integer error_count;

    time last_sck_rise;
    time last_ws_change;
    time sck_period;
    time ws_period;

    // 125 MHz 系统时钟，周期 8 ns
    always #4 sys_clk = ~sys_clk;

    i2s_clock_gen dut (
        .sys_clk (sys_clk),
        .rst_n   (rst_n),
        .mic_sck (mic_sck),
        .mic_ws  (mic_ws)
    );

    // 检查 SCK 上升沿间隔
    always @(posedge mic_sck) begin
        if (rst_n) begin
            sck_rise_count = sck_rise_count + 1;

            if (last_sck_rise != 0) begin
                sck_period = $time - last_sck_rise;

                $display(
                    "SCK rising edge %0d: period = %0t ns",
                    sck_rise_count,
                    sck_period
                );

                // 目标 SCK 频率约为 3.072 MHz，
                // 周期约为 325.5 ns。
                // 分数分频后允许出现 320、328 或 336 ns。
                if ((sck_period < 320) || (sck_period > 336)) begin
                    $display(
                        "FAIL: invalid SCK period = %0t ns",
                        sck_period
                    );
                    error_count = error_count + 1;
                end
            end

            last_sck_rise = $time;
        end
    end

    // 检查 WS 翻转间隔
    always @(mic_ws) begin
        if (rst_n) begin
            ws_change_count = ws_change_count + 1;

            if (last_ws_change != 0) begin
                ws_period = $time - last_ws_change;

                $display(
                    "WS change %0d: interval = %0t ns",
                    ws_change_count,
                    ws_period
                );

                // 32 个 SCK 周期：
                // 32 / 48000 Hz = 666.67 us？
                //
                // 注意：WS 每 32 个 SCK 下降沿翻转一次，
                // 因此 WS 半周期约为 10.416 us。
                if ((ws_period < 10300) || (ws_period > 10550)) begin
                    $display(
                        "FAIL: invalid WS interval = %0t ns",
                        ws_period
                    );
                    error_count = error_count + 1;
                end
            end

            last_ws_change = $time;
        end
    end

    initial begin
        sys_clk = 1'b0;
        rst_n = 1'b0;

        sck_rise_count = 0;
        ws_change_count = 0;
        error_count = 0;

        last_sck_rise = 0;
        last_ws_change = 0;
        sck_period = 0;
        ws_period = 0;

        // 保持复位 100 ns
        #100;
        rst_n = 1'b1;

        // 运行 30 us，足够观察多次 WS 翻转
        #30000;

        $display("----------------------------------------");
        $display("SCK rising edges  = %0d", sck_rise_count);
        $display("WS changes        = %0d", ws_change_count);
        $display("Error count       = %0d", error_count);

        if ((ws_change_count >= 2) && (error_count == 0))
            $display("PASS: i2s_clock_gen timing");
        else
            $display("FAIL: i2s_clock_gen timing");

        $finish;
    end

endmodule