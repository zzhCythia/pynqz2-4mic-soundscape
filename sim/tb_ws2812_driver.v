`timescale 1ns / 1ps

module tb_ws2812_driver;
    reg clk = 0;
    reg rst_n = 0;
    reg [31:0] led_control = 0;
    wire led_data;
    integer led, bit_no, tick, high_ticks;
    reg [23:0] expected_grb;
    reg expected_bit;

    always #4 clk = ~clk; // 125 MHz

    ws2812_driver dut (
        .clk(clk), .rst_n(rst_n),
        .led_control(led_control), .led_data(led_data)
    );

    task check_frame;
        input [4:0] index;
        input [7:0] red;
        input [7:0] green;
        input [7:0] blue;
        input enable;
        begin
            // Update software control during the 100 us inter-frame reset.
            led_control = {blue, green, red, 2'b00, enable, index};
            wait (dut.in_reset == 1'b0);
            @(posedge clk); // transmitter processes the first bit at tick zero
            for (led = 0; led < 24; led = led + 1) begin
                expected_grb = (enable && led == index) ? {green, red, blue} : 24'd0;
                for (bit_no = 23; bit_no >= 0; bit_no = bit_no - 1) begin
                    expected_bit = expected_grb[bit_no];
                    high_ticks = expected_bit ? 87 : 43;
                    for (tick = 0; tick < 156; tick = tick + 1) begin
                        @(negedge clk);
                        if (led_data !== (tick < high_ticks)) begin
                            $display("FAIL led=%0d bit=%0d tick=%0d expected=%0b got=%0b",
                                     led, bit_no, tick, tick < high_ticks, led_data);
                            $fatal(1);
                        end
                        @(posedge clk);
                    end
                end
            end
            if (!dut.in_reset) $fatal(1, "Frame length wrong");
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        check_frame(0, 8'h10, 0, 0, 1);
        check_frame(7, 0, 8'h20, 0, 1);
        check_frame(23, 0, 0, 8'h40, 1);
        check_frame(5, 8'hff, 8'hff, 8'hff, 0);
        $display("PASS: all 24 LED positions, GRB order, 0/1 pulse widths, disabled frame");
        $finish;
    end
endmodule
