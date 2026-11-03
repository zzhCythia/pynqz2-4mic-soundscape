# 四麦克风采集与 WS2812 灯环

## 数据路径

`INMP441 × 4 → I²S 接收 → 4 × 24-bit 样本 → FIFO → AXI-Stream → AXI DMA → PS DDR`

采样率为 48 kHz，通道顺序为 `ch0, ch1, ch2, ch3`。每帧保存四路有符号 32 位整数，原始麦克风样本为 24 位并进行符号扩展。录制程序会同时生成 `.npy`、`.csv`、`.wav` 和 `.json`，其中 `.csv` 可直接由 MATLAB 读取。

## 仓库中对应文件

- `rtl/ws2812_driver.v`：WS2812 单线时序与灯珠数据发送。
- `rtl/mic4_axis_top.v`、`rtl/audio_axis_4ch.v`：四路音频采集及 AXI-Stream。
- `constraints/pynqz2_4mic.xdc`：PYNQ-Z2 引脚约束，灯环数据线为 PMODB 物理 7 脚。
- `software/record_4mic.py`：连续采集并保存音频。
- `software/test_led_ring.py`：逐颗点亮测试灯环。
- `software/realtime_localize_visual.py`：实时采集、声源定位、HDMI 显示和灯环联动。
- `vivado/upgrade_bd.tcl`、`vivado/build_bitstream.tcl`：更新并生成 Vivado 工程。

## 硬件连接

灯环建议使用独立稳定的 5 V 电源，PYNQ-Z2 与灯环必须共地；数据线接灯环 `DI`，不要接 `DO`。PMODB 物理 7 脚对应 FPGA 输出 `V16`。数据线较长或灯环不稳定时，建议在数据线上加入 74AHCT125/74HCT14 等 3.3 V-to-5 V 电平缓冲器。

灯环的供电、地线、数据方向和电平转换属于硬件连接问题；不要通过修改 HDMI 渲染代码来解决灯环故障。更新屏幕显示时，灯环的 RTL 和软件控制逻辑应保持不变。

## 板端部署

最终成品必须使用同一次 Vivado 实现生成、且同名配对的 `.bit` 与 `.hwh`。把它们和需要运行的 Python 文件放在 PYNQ 的同一目录，例如：

```text
/home/xilinx/jupyter_notebooks/
├── 4mic_hdmi_fix.bit
├── 4mic_hdmi_fix.hwh
├── realtime_localize_visual.py
├── record_4mic.py
└── test_led_ring.py
```

文件名可以不同，但 `.bit` 和 `.hwh` 必须严格匹配，不能把旧版 `.hwh` 与新版 `.bit` 混用。GitHub 仓库只保存 RTL、约束、脚本和文档；实际生成的 bit/hwh 文件按提交要求另行复制或发布。

## 基础测试

进入文件所在目录后运行：

```bash
cd /home/xilinx/jupyter_notebooks
python3 test_led_ring.py --overlay 4mic_hdmi_fix.bit
```

测试脚本打印 `LED 0` 到 `LED 23` 只说明软件遍历了 24 个编号，是否点亮还要结合灯环供电、共地、DI 方向和电平检查。测试结束后按 `Ctrl+C`（若程序自动结束则无需操作）。

## 采集与实时定位

先验证采集无丢帧：

```bash
python3 record_4mic.py --overlay 4mic_hdmi_fix.bit --seconds 3 --output sample_3s
```

确认输出 `Dropped frames while recording: 0`，再运行最终联动程序：

```bash
python3 realtime_localize_visual.py \
  --overlay 4mic_hdmi_fix.bit \
  --calibration 0,0,2,0 \
  --side-cm 8
```

程序输出的角度、音量和频率同时用于屏幕与灯环。角度约定为正前方 `0°`，右侧为正、左侧为负。停止实时程序使用 `Ctrl+C`；如果浏览器终端拦截快捷键，直接关闭该终端标签或在板端另开终端执行 `pkill -f realtime_localize_visual.py`。

## 采样文件说明

`sample_3s.csv` 每行对应一个采样时刻，四列依次对应四个麦克风。MATLAB 示例：

```matlab
x = readmatrix('sample_3s.csv');
fs = 48000;
soundsc(double(x(:,1)) / 2^23, fs);
```

如果录制过程中出现丢帧，应先排查 DMA、网络或板端负载，不要直接把有间断的数据用于定位精度结论。
