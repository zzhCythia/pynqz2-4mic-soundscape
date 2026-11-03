`timescale 1ns / 1ps

// 1280x720 active-video source. AXI4-Stream advances only when the current
// pixel can be accepted; TVALID, TDATA, TUSER and TLAST hold during stalls.
//
// 2026-11-04 修改（端口完全没变，Block Design 不用动）：
//   1) 环的形状改成"正八边形"：8 个顶点全部落在同一个圆上
//        原来的 radius = max(|x|,|y|) + min(|x|,|y|)/2
//        其实是不规则八边形：4 个顶点在 r=R，另外 4 个只有 0.943R。
//        现在改成
//            oct = max(a + k*b, k*a + b),  a=|x|, b=|y|, k = √2-1
//        这样 8 顶点都在 r=R 的圆周上、边长相等 —— 真正的正八边形。
//   2) 背景改为纯黑（原来是深蓝渐变 + 网格）
//
// 内部所有"圆"（呼吸中心、方向光点、扩散环）也用同一个八边形度量，
// 保持和原来一致的风格；它们在 r 较小时看起来和圆几乎一样。
module soundscape_axis_video (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF M_AXIS_VIDEO, ASSOCIATED_RESET aresetn, FREQ_HZ 74255952" *)
    input  wire        aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input  wire        aresetn,
    input  wire [31:0] ctrl0,
    input  wire [31:0] ctrl1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TDATA" *)
    output reg  [23:0] m_axis_video_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TVALID" *)
    output reg         m_axis_video_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TREADY" *)
    input  wire        m_axis_video_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TUSER" *)
    output reg         m_axis_video_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_VIDEO TLAST" *)
    output reg         m_axis_video_tlast
);
    localparam integer WIDTH = 1280;
    localparam integer HEIGHT = 720;

    // ctrl1[31] is written last by software. The words then remain stable for
    // many pixel clocks. Delay both buses and accept one packet per frame.
    (* ASYNC_REG = "TRUE" *) reg [31:0] ctrl0_meta, ctrl0_sync;
    (* ASYNC_REG = "TRUE" *) reg [31:0] ctrl1_meta, ctrl1_sync;
    reg commit_seen;
    reg pulse_seen;
    reg signed [9:0] direction_x, direction_y;
    reg [7:0] brightness, accent_r, accent_g, accent_b;
    reg [3:0] confidence;
    reg [1:0] band;
    reg has_direction, silence;
    reg [5:0] pulse_age;
    reg [15:0] frame;
    reg [10:0] x;
    reg [9:0] y;

    wire signed [12:0] cx = $signed({2'b00, x}) - 13'sd640;
    wire signed [12:0] cy = $signed({3'b000, y}) - 13'sd360;
    wire signed [12:0] dx = cx - {{3{direction_x[9]}}, direction_x};
    wire signed [12:0] dy = cy - {{3{direction_y[9]}}, direction_y};
    wire [12:0] ax = cx[12] ? -cx : cx;
    wire [12:0] ay = cy[12] ? -cy : cy;
    wire [12:0] mx = dx[12] ? -dx : dx;
    wire [12:0] my = dy[12] ? -dy : dy;

    // ------------------------------------------------------------------
    //  正八边形"距离"，单位 1/128 像素：
    //      k = √2 - 1 = 0.41421 ≈ 53/128 = 0.4140625
    //      oct = max(a + k*b, k*a + b)
    //  oct = R*128 的等值线就是"顶点落在半径 R 圆周上"的正八边形。
    // ------------------------------------------------------------------
    function [19:0] oct128;
        input [12:0] a;
        input [12:0] b;
        reg [19:0] p, q;
        begin
            p = ({7'd0, a} << 7) + ({7'd0, b} << 5) + ({7'd0, b} << 4)
                                 + ({7'd0, b} << 2) + {7'd0, b};
            q = ({7'd0, b} << 7) + ({7'd0, a} << 5) + ({7'd0, a} << 4)
                                 + ({7'd0, a} << 2) + {7'd0, a};
            oct128 = (p > q) ? p : q;
        end
    endfunction

    function within_band20;
        input [19:0] value;
        input [19:0] centre;
        input [19:0] tolerance;
        begin
            within_band20 = (value + tolerance >= centre) &&
                            (value <= centre + tolerance);
        end
    endfunction

    wire [19:0] radius   = oct128(ax, ay);   // 到画面中心的八边形距离 (x128)
    wire [19:0] mradius  = oct128(mx, my);   // 到方向光点的八边形距离 (x128)

    wire [5:0] breath = frame[5] ? {1'b0, ~frame[4:0]} : {1'b0, frame[4:0]};
    // Audio-reactive radius: brightness 0..255 -> about 28..170 pixels.
    // The breath term adds a small animation without hiding level changes.
    wire [8:0] core_radius = 9'd28 + ({1'b0, brightness} >> 1) + {3'b000, breath[5:1]};
    wire [8:0] marker_core_radius = 9'd12 + ({1'b0, brightness} >> 2);
    wire [8:0] ripple_radius = 9'd90 + ({3'b000, frame[5:0]} * 9'd3);
    wire [8:0] shock_radius = 9'd20 + ({3'b000, pulse_age} * 9'd7);
    wire [7:0] spark = x[7:0] ^ {y[5:0], 2'b00} ^ frame[7:0];

    // 各动态半径换算成 x128
    wire [19:0] c_core   = {4'd0, core_radius,        7'd0};
    wire [19:0] c_mark   = {4'd0, marker_core_radius, 7'd0};
    wire [19:0] c_mark16 = {4'd0, (marker_core_radius + 9'd16), 7'd0};
    wire [19:0] c_rip    = {4'd0, ripple_radius,      7'd0};
    wire [19:0] c_shock  = {4'd0, shock_radius,       7'd0};

    // 固定圆环：半径 220 -> 220*128 = 28160
    wire ring_ref = within_band20(radius, 20'd28160, 20'd256);    // 220±2
    wire ring_hue = within_band20(radius, 20'd28160, 20'd2560);   // 220±20

    reg [7:0] pixel_r, pixel_g, pixel_b;
    always @* begin
        // 纯白背景（2026-11-04：由纯黑改为纯白，屏幕文字同步改黑色）
        pixel_r = 8'd255;
        pixel_g = 8'd255;
        pixel_b = 8'd255;

        // 固定的暗色参考八边形
        if (ring_ref) begin
            pixel_r = 8'd15;
            pixel_g = 8'd30;
            pixel_b = 8'd48;
        end
        // Bright hue ring: display hue is independent of LED power scaling.
        if (!silence && ring_hue) begin
            pixel_r = accent_r; pixel_g = accent_g; pixel_b = accent_b;
        end
        // Low frequencies spread as broad ripples; the high band has sparks.
        if (!silence && band == 2'd0 &&
            within_band20(radius, c_rip, 20'd512)) begin          // ±4
            pixel_r = accent_r >> 2;
            pixel_g = accent_g >> 2;
            pixel_b = accent_b >> 1;
        end
        if (!silence && band == 2'd1 &&
            within_band20(radius, c_rip, 20'd256)) begin          // ±2
            pixel_r = accent_r >> 1;
            pixel_g = accent_g >> 1;
            pixel_b = accent_b >> 1;
        end
        if (!silence && band == 2'd2 && spark[5:0] == 6'd0 &&
            radius > 20'd9600 && radius < 20'd46080) begin        // 75 .. 360
            pixel_r = accent_r >> 1;
            pixel_g = accent_g >> 1;
            pixel_b = accent_b >> 1;
        end
        // A sound transient expands from the measured direction.
        if (pulse_age < 6'd29 && has_direction &&
            within_band20(mradius, c_shock, 20'd384)) begin       // ±3
            pixel_r = accent_r;
            pixel_g = accent_g;
            pixel_b = accent_b;
        end
        // Centre breathes even when no microphone input has arrived.
        if (radius < c_core) begin
            pixel_r = silence ? 8'd8 : (accent_r >> 2) + 8'd7;
            pixel_g = silence ? 8'd24 : (accent_g >> 2) + 8'd16;
            pixel_b = silence ? 8'd52 : (accent_b >> 2) + 8'd28;
        end
        if (radius < 20'd2560) begin                              // 半径 20
            pixel_r = silence ? 8'd24 : accent_r;
            pixel_g = silence ? 8'd67 : accent_g;
            pixel_b = silence ? 8'd112 : accent_b;
        end
        // Pointer stays at the last accepted angle during low confidence.
        if (has_direction && !silence && mradius < c_mark16) begin
            pixel_r = accent_r >> 1;
            pixel_g = accent_g >> 1;
            pixel_b = accent_b >> 1;
        end
        if (has_direction && !silence && mradius < c_mark) begin
            pixel_r = accent_r;
            pixel_g = accent_g;
            pixel_b = accent_b;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            ctrl0_meta <= 0;
            ctrl0_sync <= 0;
            ctrl1_meta <= 0;
            ctrl1_sync <= 0;
            commit_seen <= 0;
            pulse_seen <= 0;
            direction_x <= 0;
            direction_y <= -10'sd205;
            brightness <= 8'd4;
            accent_r <= 0;
            accent_g <= 0;
            accent_b <= 8'd28;
            confidence <= 0;
            band <= 0;
            has_direction <= 0;
            silence <= 1;
            pulse_age <= 6'd63;
            frame <= 0;
            x <= 0;
            y <= 0;
            m_axis_video_tvalid <= 0;
            m_axis_video_tdata <= 0;
            m_axis_video_tuser <= 0;
            m_axis_video_tlast <= 0;
        end else begin
            ctrl0_meta <= ctrl0;
            ctrl0_sync <= ctrl0_meta;
            ctrl1_meta <= ctrl1;
            ctrl1_sync <= ctrl1_meta;
            if (!m_axis_video_tvalid || m_axis_video_tready) begin
                m_axis_video_tvalid <= 1;
                m_axis_video_tdata <= {pixel_r, pixel_g, pixel_b};
                m_axis_video_tuser <= (x == 0 && y == 0);
                m_axis_video_tlast <= (x == WIDTH - 1);
                if (x == WIDTH - 1) begin
                    x <= 0;
                    if (y == HEIGHT - 1) begin
                        y <= 0;
                        frame <= frame + 1'b1;
                        if (pulse_age < 6'd63)
                            pulse_age <= pulse_age + 1'b1;
                        if (ctrl1_sync[31] != commit_seen) begin
                            commit_seen <= ctrl1_sync[31];
                            direction_x <= ctrl0_sync[9:0];
                            direction_y <= ctrl0_sync[19:10];
                            brightness <= ctrl0_sync[27:20];
                            confidence <= ctrl0_sync[31:28];
                            accent_r <= ctrl1_sync[7:0];
                            accent_g <= ctrl1_sync[15:8];
                            accent_b <= ctrl1_sync[23:16];
                            band <= ctrl1_sync[25:24];
                            has_direction <= ctrl1_sync[26];
                            silence <= ctrl1_sync[27];
                            if (ctrl1_sync[28] != pulse_seen) begin
                                pulse_seen <= ctrl1_sync[28];
                                pulse_age <= 0;
                            end
                        end
                    end else begin
                        y <= y + 1'b1;
                    end
                end else begin
                    x <= x + 1'b1;
                end
            end
        end
    end
endmodule
