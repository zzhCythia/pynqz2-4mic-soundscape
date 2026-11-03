`timescale 1ns / 1ps

module tb_soundscape_axis_video;
    reg clk = 0;
    always #5 clk = ~clk;
    reg resetn = 0;
    reg [31:0] ctrl0 = 0;
    reg [31:0] ctrl1 = 0;
    reg ready = 0;
    wire [23:0] data;
    wire valid, user, last;
    integer accepted = 0;
    integer expected_x = 0;
    integer expected_y = 0;
    integer cycles = 0;
    reg stalled = 0;
    reg [25:0] held;

    soundscape_axis_video dut (
        .aclk(clk), .aresetn(resetn), .ctrl0(ctrl0), .ctrl1(ctrl1),
        .m_axis_video_tdata(data), .m_axis_video_tvalid(valid),
        .m_axis_video_tready(ready), .m_axis_video_tuser(user),
        .m_axis_video_tlast(last)
    );

    initial begin
        repeat (8) @(negedge clk);
        resetn = 1;
        ctrl0 = (8'd150 << 20) | (4'd14 << 28);
        ctrl1 = (1 << 31) | (1 << 26) | 8'hff;
    end

    always @(posedge clk) begin
        if (resetn) begin
            cycles = cycles + 1;
            if (stalled && (!valid || {data,user,last} !== held))
                $fatal(1, "AXI video changed while TREADY was low");
            stalled = valid && !ready;
            held = {data,user,last};
            if (valid && ready) begin
                if (user !== ((expected_x == 0) && (expected_y == 0)))
                    $fatal(1, "TUSER at pixel %0d,%0d", expected_x, expected_y);
                if (last !== (expected_x == 1279))
                    $fatal(1, "TLAST at pixel %0d,%0d", expected_x, expected_y);
                accepted = accepted + 1;
                if (expected_x == 1279) begin
                    expected_x = 0;
                    expected_y = expected_y == 719 ? 0 : expected_y + 1;
                end else expected_x = expected_x + 1;
                if (accepted == 1280*720 + 100) begin
                    $display("PASS: complete frame, SOF, line ends, and stalls");
                    $finish;
                end
            end
            if (cycles > 2000000) $fatal(1, "video source timed out");
        end
    end

    always @(negedge clk) begin
        if (resetn) ready = (cycles % 11 != 0);
    end
endmodule
