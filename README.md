# PYNQ-Z2 四麦克风声源定位与声景可视化

基于 Xilinx Zynq-7020（PYNQ-Z2）的实时声源方位估计系统：4 只 INMP441 数字麦克风组成边长 8 cm 的方阵，
PL 完成 I2S 采集、四通道打包、WS2812 驱动与 720p HDMI 逐像素图形生成，
PS 运行 Python 完成 GCC-PHAT 时延估计与最小二乘方位解算，
结果同时驱动 24 颗 WS2812 灯环和 HDMI 屏幕上的角度、音量、频率信息、方向环与声源节点。

```
声音 → INMP441 ×4 → I2S 接收 → 128 bit AXI4-Stream → DMA → DDR
                                                          ↓
                        ┌─────────────── PS (ARM Cortex-A9, Python) ───────────────┐
                        │  GCC-PHAT 六基线时延 → 最小二乘 → 角度 + 置信度           │
                        │  四通道 RMS → 亮度；频谱质心 → 色相                      │
                        └───────────────┬───────────────────────┬──────────────────┘
                                        │ AXI GPIO              │ AXI GPIO
                                        ↓                       ↓
                            WS2812 灯环（方位点）      HDMI 动画（1280×720 像素源）
```

## 主要指标

| 项目 | 数值 |
|---|---|
| 采样率 / 位深 | 48 kHz / 24 bit（32 bit 符号扩展存放） |
| 麦克风阵列 | 4 × INMP441，方阵，默认边长 8 cm |
| 通道间最大时延 | ±15.8 采样点（8 cm 对角线），对应 ±0.33 ms |
| DMA 包长 | 1920 帧/通道 = 40 ms，一次 TLAST |
| 定位更新率 | 默认 4 包/窗 = 160 ms，可通过 `--packets-per-estimate` 调整 |
| 方位分辨率 | 仿真条件下 ±0.3°（SNR 10 dB），实测受混响限制 |
| HDMI 输出 | 1280×720@60，工程实际像素时钟约 74.255952 MHz，PL 直出不经 DDR |
| PL 时钟 | 125 MHz（`sys_clk`），HDMI 像素时钟由 `clk_wiz` 倍频 |

## 目录结构

```
rtl/            核心 RTL（评委/评审重点看这里）
  i2s_clock_gen.v        由 125 MHz 产生 3.072 MHz SCK 与 48 kHz WS
  i2s_rx_4ch.v           双 SD 线、四通道 I2S 接收与 24 bit 对齐
  audio_axis_4ch.v       四通道打包 128 bit、4096 深 FIFO、TLAST 成帧、丢帧计数
  mic4_top.v             采集子系统顶层（时钟 + 接收）
  mic4_axis_top.v        BD 中的封装顶层，带 AXI4-Stream 与 WS2812 输出
  ws2812_driver.v        24 灯 WS2812 单线串行驱动
  soundscape_axis_video.v 1280×720 AXI4-Stream 像素源，帧同步锁存控制字
sim/            testbench（6 个，均可在 Vivado Simulator 直接跑）
constraints/    pynqz2_4mic.xdc，麦克风与灯环引脚约束
vivado/         system.bd 块设计 + 三个 Tcl 脚本（构建位流、挂接视频源、升级 BD）
software/       PYNQ 板端 Python（DMA 采集、定位、灯环、HDMI 控制）
docs/           原始设计说明（中文）
artifacts/      最终验证过的板端文件（`4mic_hdmi_fix.bit/.hwh`，必须成对使用）
```

## RTL 模块要点

- **`i2s_clock_gen`**：用 32 位相位累加器从 125 MHz 生成平均 3.072 MHz 的 SCK（分数分频，避免整数分频误差），
  每 32 个下降沿翻转 WS，得到准确的 48 kHz 帧率。
- **`audio_axis_4ch`**：每帧拼成 128 bit（4 × 32 bit），每 1920 帧置一次 TLAST；
  内部 4096 帧 FIFO 可吸收约 85 ms 的 PS 暂停；FIFO 满时丢帧并累加 `dropped_frames`，供软件判断是否丢样。
- **`soundscape_axis_video`**：自带行列计数器逐像素生成图形，`TREADY=0` 时保持 TVALID/TDATA/TUSER/TLAST 不变；
  控制字在**帧结束**才锁存，保证画面不会画到一半换色。
- **`ws2812_driver`**：把角度、亮度、RGB 打包进一个 32 bit 寄存器，由 PL 串行移位输出，PS 无需参与时序。

## 板端软件

| 文件 | 作用 |
|---|---|
| `record_4mic.py` | DMA 循环采集与录制（npy/csv/wav + 元数据 json），含丢帧统计 |
| `realtime_localize_visual.py` | 最终主程序：定位 + 灯环 + HDMI 同步刷新 |
| `test_soundscape_visual.py` | 只测 HDMI 动画，不接麦克风 |
| `test_led_ring.py` | 只测灯环流水灯 |
| `hdmi_colorbars.py` | 彩条测试，确认 HDMI 通路正常 |

算法链路（`realtime_localize_visual.py`）：

1. 每 4 个 DMA 包（160 ms）拼成一个分析窗；
2. 加 Hann 窗后做 FFT，六条基线各自算互谱并做 PHAT 白化（幅度归一化，只保留相位差）；
3. 逆变换得到互相关曲线，在物理时延范围内（±18 采样）找峰，三点抛物线插值得到亚采样时延；
4. 以置信度为权做最小二乘，解出平面波方向向量，取 `atan2` 得到方位角；
5. `AngleTracker` 用环形中值 + 突变确认抑制房间反射，再输出给灯环与 HDMI。

## 复现步骤

环境：Vivado 2025.2 + PYNQ-Z2 官方镜像（带 `pynq` Python 包与 numpy 即可，无需额外安装）。

1. 新建工程或打开原始工程，确认 Block Design 名为 `system`；
2. 在 Vivado Tcl Console 依次执行：

   ```tcl
   source vivado/add_soundscape_video.tcl   ;# 挂接 soundscape_axis_video 与两路 AXI GPIO
   ```

3. Generate Bitstream，导出成对的 `.bit` / `.hwh`（两者必须来自同一次实现）。若只想直接上板，可使用 `artifacts/4mic_hdmi_fix.bit` 和 `artifacts/4mic_hdmi_fix.hwh`；
4. 把 `.bit`、`.hwh` 和 `software/` 下的脚本拷到板子同一目录，然后：

   ```bash
   python3 test_soundscape_visual.py --overlay xxx.bit     # 先验证 HDMI
   python3 realtime_localize_visual.py --overlay xxx.bit --calibration 0,0,2,0 --side-cm 8
   ```

## 最终成品界面

- 左上角显示 `ANGLE`、`LEVEL`、`PITCH`；
- 中心区域显示方向环、角度刻度和实心声源节点；
- 频率由低到高映射为蓝、绿、红，屏幕与灯环使用同一套 RGB 结果；
- 灯环沿用原有 WS2812 控制逻辑，界面修改不改变灯环时序和数据格式；
- 最终压缩包中的 `soundscape_visual` 与 `soundscape_transfer` 是重复版本；本仓库已固定采用最终 `soundscape_transfer` 对应的 RTL/Python 版本，避免两套文件混用。

## 说明

- 仓库**不包含** Vivado 生成目录（`.cache/`、`.runs/`、`.gen/`、`.ip_user_files/`）；最终验证过的 `.bit/.hwh` 仅保留在 `artifacts/`，便于直接上板，其他生成位流仍由 `vivado/system.bd` 与上述脚本重新生成。
- `docs/` 下保留原始中文说明，其中 `README_led_ring.md` 是仅有灯环版本的设计说明，
  `README_soundscape_hdmi.md` 是加入 HDMI 动画后的说明。
- 硬件平台：PYNQ-Z2（XC7Z020-1CLG400C），外设：4 × INMP441、24 颗 WS2812、HDMI OUT。
