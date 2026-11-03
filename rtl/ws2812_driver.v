`timescale 1ns / 1ps

// WS2812 serializer driven by the existing 125 MHz PL clock.
// led_control layout:
//   [4:0]   LED index (0..23)
//   [5]     enable
//   [15:8]  red
//   [23:16] green
//   [31:24] blue
// The selected LED receives the requested RGB data; all other LEDs are off.
// The WS2812 wire order is GRB, MSB first.
module ws2812_driver #(
    parameter integer LED_COUNT = 24,
    parameter integer CLOCK_HZ = 125_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] led_control,
    output reg         led_data
);
    localparam integer BIT_TICKS   = CLOCK_HZ / 800_000;
    localparam integer T0H_TICKS   = (BIT_TICKS * 28) / 100;
    localparam integer T1H_TICKS   = (BIT_TICKS * 56) / 100;
    // Use 100 us low time between frames.  Some WS2812 rings do not
    // reliably latch a new frame at exactly the nominal 50 us minimum.
    localparam integer RESET_TICKS = CLOCK_HZ / 10_000;

    reg [31:0] control_latched;
    reg [12:0] tick_count;
    reg [15:0] reset_count;
    reg [4:0]  led_index;
    reg [4:0]  bit_in_led;
    reg        in_reset;

    wire selected = control_latched[5] &&
                    (control_latched[4:0] == led_index) &&
                    (control_latched[4:0] < LED_COUNT);

    reg current_bit;
    always @* begin
        current_bit = 1'b0;
        if (selected) begin
            // Control-word fields are RGB, but WS2812 receives GRB.
            if (bit_in_led < 16)
                current_bit = control_latched[23 - bit_in_led];
            else
                current_bit = control_latched[47 - bit_in_led];
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            control_latched <= 32'd0;
            tick_count      <= 13'd0;
            reset_count     <= 16'd0;
            led_index       <= 5'd0;
            bit_in_led      <= 5'd0;
            in_reset        <= 1'b1;
            led_data        <= 1'b0;
        end else if (in_reset) begin
            led_data <= 1'b0;
            if (reset_count == RESET_TICKS - 1) begin
                control_latched <= led_control;
                reset_count     <= 16'd0;
                tick_count      <= 13'd0;
                led_index       <= 5'd0;
                bit_in_led      <= 5'd0;
                in_reset        <= 1'b0;
            end else begin
                reset_count <= reset_count + 1'b1;
            end
        end else begin
            // Both 0 and 1 bits require a high pulse; only its width differs.
            led_data <= (tick_count <
                         (current_bit ? T1H_TICKS : T0H_TICKS));
            if (tick_count == BIT_TICKS - 1) begin
                tick_count <= 13'd0;
                if (bit_in_led == 5'd23) begin
                    bit_in_led <= 5'd0;
                    if (led_index == LED_COUNT - 1) begin
                        led_index   <= 5'd0;
                        reset_count <= 16'd0;
                        in_reset    <= 1'b1;
                    end else begin
                        led_index <= led_index + 1'b1;
                    end
                end else begin
                    bit_in_led <= bit_in_led + 1'b1;
                end
            end else begin
                tick_count <= tick_count + 1'b1;
            end
        end
    end
endmodule
