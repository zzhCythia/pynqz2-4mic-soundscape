# 四麦克风连续采集

## 当前数据路径

`INMP441 × 4 → I²S 接收 → 4 × 24-bit 样本 → 4096 帧 FIFO → AXI-Stream → AXI DMA S2MM → PS DDR`

采样率为 48 kHz。每帧 16 字节，按 `ch0, ch1, ch2, ch3` 四个有符号 32 位整数保存；每路原始样本为 24 位，向高 8 位符号扩展。通道顺序依次是 SD0 左、SD0 右、SD1 左、SD1 右。每 1920 帧（40 ms）产生一次 TLAST，DMA 接收一个包。3 秒录制共 75 包、144000 帧/通道。

GPIO2 bit0 是采集开关，GPIO1 是自启动以来累计的 FIFO 丢帧计数。采集开关关闭时 FIFO 清空，计数保留；下次录制通过读取前后计数差判断是否丢帧。4096 帧 FIFO 可以缓冲约 85 ms 的接收暂停。DMA 是简单模式，板端程序需要逐包重新启动接收；超过缓冲时间的暂停仍会丢样本。

## 生成并部署

在 Windows 工程目录运行 `realtime/upgrade_bd.tcl`（工程当前已升级）和 `realtime/build_bitstream.tcl`。生成成功后，将下列三个文件放到 PYNQ 板的**同一个目录**：

1. `realtime/overlay/4mic_realtime.bit`。
2. `realtime/overlay/4mic_realtime.hwh`。
3. `realtime/record_4mic.py`。

在 PYNQ 板上执行：

```bash
python3 record_4mic.py --overlay 4mic_realtime.bit --seconds 3 --output sample_3s
```

录制结束后得到 `.npy`（四路 int32 原样本）、`.csv`（MATLAB 可读）、`.wav`（16 位试听版）和 `.json`（采样率、通道顺序、丢帧计数）。重点看终端输出 `Dropped frames while recording: 0`。如果非零，本次录制中有样本间断。

在 MATLAB 中试听一路：

```matlab
x = readmatrix('sample_3s.csv');
fs = 48000;
soundsc(double(x(:,1)) / 2^23, fs);  % 第一只麦克风
```

注意：这是板端连续分包录制，录制完成后才写文件，不是边录边播放。此版本尚未在实际 PYNQ 板上验证，先从 3 秒和丢帧计数为 0 开始检查。若长时间录制出现丢帧，应改用 SG 环形 DMA 或进一步增加硬件缓冲，不应直接把有间断的数据当作连续音频。

## 实时声源方向输出

### 24 灯 WS2812 灯环

工程已经把 `led_data` 约束到 PYNQ-Z2 的 PMODB 物理 7 脚（V16）。
灯环使用外部 5V 供电并与 PYNQ 共地，数据线接灯环的 DI；长导线或
不稳定时建议加 3.3V 到 5V 的 74AHCT125 缓冲器。此 RTL 按 GRB 顺序
发送数据，AXI GPIO 的控制字格式为 `[31:24] B、[23:16] G、[15:8] R、
[5] 使能、[4:0] 灯珠编号（0～23）`。每帧只有指定的一颗灯亮。

修改 RTL 后必须重新运行 `realtime/build_bitstream.tcl`，并把新生成的
`realtime/overlay/4mic_realtime.bit` 与同名 `.hwh` 一起复制到板上的
`/home/xilinx/mic4`。仅用 JTAG 下载 bit 文件时，未运行 Python 控制程序，
灯环不会自动显示声源方向。板上先运行
`python3 test_led_ring.py --overlay 4mic_realtime.bit`，应看到低亮白光逐颗移动；
用 `--red 16 --green 0 --blue 0` 可单独检查红色。

RTL 脉宽及第 0、7、23 颗灯的 GRB 编码可用
`realtime/tb_ws2812_driver.v` 做 Vivado 仿真检查。灯环的 0 号位置与阵列
正前方的物理对应关系需上板观察，之后通过 `--led-offset 0..23` 调整。

将 `realtime_localize.py` 也放到板上的 `/home/xilinx/mic4`，与 BIT、HWH 和
`record_4mic.py` 保持在同一目录。默认按边长 8 cm 的正方形阵列计算，约每
160 ms 更新一次：

```bash
cd /home/xilinx/mic4
python3 realtime_localize.py --overlay 4mic_realtime.bit --side-cm 8
```

终端会持续打印平滑后的 `Angle`、本窗口原始角度、置信度及六组通道延迟。
角度约定为正前方 0°、右侧为正、左侧为负；按 `Ctrl+C` 停止并查看硬件及
软件丢帧统计。默认不加入通道时延校准。只有在多次同步敲击测试均稳定得到
同一个偏差时，才使用例如 `--calibration 0,0,2,0`。

实时显示还带有状态字段：`tracking` 表示正常跟踪，`holding` 表示检测到单次
大跳变并保持原角度，`switched` 表示新方向连续出现三个窗口后正式切换，
`low-confidence` 表示当前音乐片段相关性不足。默认置信度门限为 0.75，大于
25° 的突变需要连续三个 160 ms 窗口确认；这些值可通过
`--min-confidence`、`--jump-degrees` 和 `--confirm-windows` 调整。
