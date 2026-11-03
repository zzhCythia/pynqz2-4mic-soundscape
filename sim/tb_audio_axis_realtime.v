`timescale 1ns / 1ps

module tb_audio_axis_realtime;
    reg clk = 0;
    always #4 clk = ~clk;
    reg rst_n = 0;
    reg capture_en = 0;
    reg sample_valid = 0;
    reg signed [23:0] ch0 = 0, ch1 = 0, ch2 = 0, ch3 = 0;
    reg ready = 1;
    wire [127:0] data;
    wire valid, last;
    wire [31:0] dropped;
    integer sent, received, timeout_cycles;

    audio_axis_4ch #(.FIFO_DEPTH(8)) dut (
        .clk(clk), .rst_n(rst_n), .capture_en(capture_en),
        .sample_valid(sample_valid),
        .sample_ch0(ch0), .sample_ch1(ch1),
        .sample_ch2(ch2), .sample_ch3(ch3),
        .m_axis_tdata(data), .m_axis_tvalid(valid),
        .m_axis_tlast(last), .m_axis_tready(ready),
        .dropped_frames(dropped)
    );

    always @(posedge clk) begin
        if (valid && ready && received < 1920) begin
            if ($signed(data[31:0]) !== received ||
                $signed(data[63:32]) !== -received ||
                $signed(data[95:64]) !== 2*received ||
                $signed(data[127:96]) !== -2*received ||
                last !== (received == 1919)) begin
                $display("FAIL beat=%0d data=%h last=%b", received, data, last);
                $finish;
            end
            received = received + 1;
        end
    end

    initial begin
        received = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        capture_en = 1;
        for (sent = 0; sent < 1920; sent = sent + 1) begin
            @(negedge clk);
            sample_valid = 1;
            ch0 = sent;
            ch1 = -sent;
            ch2 = 2*sent;
            ch3 = -2*sent;
        end
        @(negedge clk);
        sample_valid = 0;
        timeout_cycles = 0;
        while (received < 1920 && timeout_cycles < 100) begin
            @(negedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        if (received != 1920 || dropped != 0) begin
            $display("FAIL received=%0d dropped=%0d", received, dropped);
            $finish;
        end

        capture_en = 0;
        ready = 0;
        repeat (3) @(negedge clk);
        if (valid) begin
            $display("FAIL stream active while capture disabled");
            $finish;
        end
        capture_en = 1;
        for (sent = 0; sent < 12; sent = sent + 1) begin
            @(negedge clk);
            sample_valid = 1;
            ch0 = sent;
        end
        @(negedge clk);
        sample_valid = 0;
        repeat (3) @(negedge clk);
        if (dropped != 3) begin
            $display("FAIL overflow count=%0d", dropped);
            $finish;
        end
        capture_en = 0;
        repeat (2) @(negedge clk);
        if (valid || dropped != 3) begin
            $display("FAIL capture stop valid=%b dropped=%0d", valid, dropped);
            $finish;
        end
        $display("PASS: 1920 ordered frames, TLAST, capture reset, overflow count");
        $finish;
    end
endmodule
