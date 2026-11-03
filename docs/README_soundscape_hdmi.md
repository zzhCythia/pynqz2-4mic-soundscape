# 四麦克风定位 HDMI 动画

这份改动沿用已能显示彩条的 720p HDMI 通路。FPGA 直接生成每个像素，视频不经过 DDR。PS 仍负责四麦克风采集、方向与频率估计，并通过两路 GPIO 寄存器把结果送入 FPGA；WS2812 灯环继续由原来的 `axi_gpio_led` 控制。低频偏蓝、中频偏绿、高频偏红，颜色映射和亮度算法来自原来的实时定位脚本。画面是深色网格、呼吸中心、频段纹理、声响扩散环和方向光点。当前版本是几何动画，没有文字或频谱柱。

## 文件

- `soundscape_axis_video.v`：1280×720 AXI4-Stream 像素源。
- `add_soundscape_video.tcl`：在 Vivado 工程里替换彩条发生器并接好控制寄存器。
- `test_soundscape_visual.py`：先单独测试 HDMI 动画，不需要接麦克风。
- `realtime_localize_visual.py`：四麦克风定位、灯环和 HDMI 动画同时运行。板上运行时还要有原工程的 `record_4mic.py`。
- `tb_soundscape_axis_video.v`：视频流握手、行尾和帧首的仿真检查。

## 在队友电脑的 Vivado 中生成新 bit

1. 先备份已验证的工程。在 Vivado 打开 `pynqz2_4mic_display` 中的 `pynqz2_4mic_features.xpr`，确认 Block Design 名为 `system`，并且彩条发生器名为 `v_tpg_0`。
2. 将本目录的 `soundscape_axis_video.v` 和 `add_soundscape_video.tcl` 放在队友电脑的同一文件夹。例如 `E:/AMDFPGA/soundscape_visual/`。在 **Vivado Tcl Console** 输入：

   ```tcl
   source {E:/AMDFPGA/soundscape_visual/add_soundscape_video.tcl}
   ```

   脚本会备份 `system.bd` 为 `system.bd.before_soundscape`，然后替换 TPG、增加双路 AXI GPIO，验证并保存设计。若报错，应停在当前工程检查报错处；不要直接拿旧 bit 继续测试。

3. 打开 Block Design，确认 `soundscape_video_0/M_AXIS_VIDEO` 连至 `v_axi4s_vid_out_0/video_in`，`v_axi4s_vid_out_0/vtg_ce` 连至 `v_tc_0/gen_clken`。在 Address Editor 中确认 `axi_gpio_visual` 有地址。然后运行 **Generate Bitstream**，等待完成，检查实现后的 timing summary 没有失败。
4. 将新生成的 `pynqz2_4mic_features.runs/impl_1/system_wrapper.bit` 复制并改名为 `4mic_soundscape.bit`。将对应的 `pynqz2_4mic_features.gen/sources_1/bd/system/hw_handoff/system.hwh` 复制并改名为 `4mic_soundscape.hwh`。两者必须来自同一次新设计。

## 在 PYNQ-Z2 上测试

把 `4mic_soundscape.bit`、`4mic_soundscape.hwh`、`test_soundscape_visual.py`、`realtime_localize_visual.py` 和原来的 `record_4mic.py` 上传到板子的**同一目录**，例如 `/home/xilinx/jupyter_notebooks/`。HDMI 线接板子的 **HDMI OUT**。板上终端输入：

```sh
cd /home/xilinx/jupyter_notebooks
python3 test_soundscape_visual.py --overlay 4mic_soundscape.bit
```

应看到方向光点移动、纹理在蓝绿红之间变化。这个独立测试通过后，再运行：

```sh
python3 realtime_localize_visual.py --overlay 4mic_soundscape.bit --calibration 0,0,2,0 --side-cm 8
```

该命令会重新加载 bit 并同时运行麦克风、灯环和 HDMI。直接在 Vivado Hardware Manager 下载 bit 只会启动 FPGA 的静态画面；随声音变化需要运行这个板上脚本。停止时在该终端按 `Ctrl+C`。

## 控制字和验证范围

`axi_gpio_visual` 的通道 1 包含有符号方向坐标、亮度和置信度；通道 2 包含 RGB、频段、静音标志、瞬态标志与更新位。软件先写通道 1，最后写通道 2；FPGA 在下一帧起点接收，避免画到一半换色。视频源在 AXI `TREADY=0` 时保持像素、帧首和行尾信号不变。

在本地只有工程副本，没有队友电脑上的 Vivado、FPGA 板或 HDL 仿真器，因此这里未运行综合、实现、仿真或上板测试。生成 bit 后重点检查 74.25 MHz 视频时钟时序，以及方向/颜色与灯环是否一致。若 FPGA 资源或时序不够，先去掉高频星点效果，再评估流水线处理。
