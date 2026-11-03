`timescale 1ns / 1ps


    // 125 MHz 时钟，同时作为 AXI-Stream m_axis 的时钟
   module mic4_axis_top (

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 sys_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME sys_clk, ASSOCIATED_BUSIF m_axis, FREQ_HZ 125000000, PHASE 0.0" *)
    input wire sys_clk,
    input wire capture_en,
    output wire [31:0] dropped_frames,
    input wire [31:0] led_control,
    output wire        led_data,

    // 两路 PDM/I2S 数据输入
    input wire [1:0] mic_sd,

    // I2S 时钟输出
    output wire mic_sck,
    output wire mic_ws,

    // AXI-Stream 输出接口
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [127:0] m_axis_tdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire m_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output wire m_axis_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input wire m_axis_tready
);

    // 上电启动复位
    reg [7:0] startup_count = 8'd0;
    reg       rst_n = 1'b0;
    reg [1:0] capture_en_sync = 2'b00;

    // 四路 24 位音频采样
    wire signed [23:0] sample_ch0;
    wire signed [23:0] sample_ch1;
    wire signed [23:0] sample_ch2;
    wire signed [23:0] sample_ch3;
    wire               sample_valid;

    // 上电后延时释放复位
    always @(posedge sys_clk) begin
        capture_en_sync <= {capture_en_sync[0], capture_en};
        if (!rst_n) begin
            if (&startup_count)
                rst_n <= 1'b1;
            else
                startup_count <= startup_count + 1'b1;
        end
    end

    // I2S 时钟发生器
    i2s_clock_gen u_clock_gen (
        .sys_clk (sys_clk),
        .rst_n   (rst_n),
        .mic_sck (mic_sck),
        .mic_ws  (mic_ws)
    );

    // 四通道 I2S 接收器
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

    // 四通道音频打包为 128 位 AXI-Stream
    audio_axis_4ch u_audio_axis (
        .clk           (sys_clk),
        .rst_n         (rst_n),
        .capture_en    (capture_en_sync[1]),
        .sample_valid  (sample_valid),
        .sample_ch0    (sample_ch0),
        .sample_ch1    (sample_ch1),
        .sample_ch2    (sample_ch2),
        .sample_ch3    (sample_ch3),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tlast  (m_axis_tlast),
        .m_axis_tready (m_axis_tready),
        .dropped_frames (dropped_frames)
    );

    // WS2812 output. The serializer is clocked by the same 125 MHz PL clock.
    ws2812_driver u_ws2812 (
        .clk         (sys_clk),
        .rst_n       (rst_n),
        .led_control (led_control),
        .led_data    (led_data)
    );

endmodule
