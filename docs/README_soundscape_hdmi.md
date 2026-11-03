# 四麦克风定位与 HDMI 最终界面

本项目使用 PYNQ-Z2 完成四麦克风实时声源定位，并将结果同时输出到 24 颗 WS2812 灯环和 HDMI 显示器。

最终 HDMI 界面以最终成品压缩包中的 `soundscape_visual/realtime_localize_visual.py` 和对应 RTL 为准：左上角显示 `ANGLE`、`LEVEL`、`PITCH`；中心区域显示方向环、角度刻度和实心声源节点。声源角度决定节点位置，音量影响显示强度，频率由低到高映射为蓝、绿、红。屏幕和 WS2812 灯环使用同一套角度、亮度和 RGB 结果。灯环控制逻辑保持原有实现，不因修改 HDMI 样式而改变。

## 相关文件

- `rtl/soundscape_axis_video.v`：1280×720 AXI4-Stream 视频源和最终方向环界面。
- `vivado/add_soundscape_video.tcl`：在 Vivado 中挂接视频源和控制 GPIO。
- `software/realtime_localize_visual.py`：实时采集、定位、灯环和 HDMI 同步控制。
- `software/test_soundscape_visual.py`：不接麦克风时测试 HDMI 控制字和动画。
- `software/hdmi_colorbars.py`：验证 HDMI 物理通路和彩条输出。
- `software/record_4mic.py`：四通道 DMA 采集及录音。

## 生成 bit/hwh

1. 在 Vivado 打开最终 `pynqz2_4mic_display` 工程，确认 Block Design 名为 `system`。
2. 确认 `soundscape_axis_video_0/M_AXIS_VIDEO` 连接到 `v_axi4s_vid_out_0/video_in`。
3. 确认 `v_axi4s_vid_out_0/vtg_ce` 连接到 `v_tc_0/gen_clken`。
4. 确认 `axi_gpio_visual` 已分配地址。
5. 若 `validate_bd_design` 报视频频率不匹配，使用工程实际像素时钟 `74255952 Hz`，不要继续使用旧的 `74250000 Hz` 参数。
6. 重新运行综合、实现和 Generate Bitstream。
7. 必须从同一次实现中取得配对的 `.bit` 和 `.hwh`，不能混用旧文件。

## PYNQ-Z2 上板测试

将以下文件上传到板上的同一目录，例如 `/home/xilinx/jupyter_notebooks/`：

```text
4mic_hdmi_fix.bit
4mic_hdmi_fix.hwh
realtime_localize_visual.py
test_soundscape_visual.py
record_4mic.py
```

HDMI 线接 PYNQ-Z2 的 **HDMI OUT**，然后执行：

```bash
cd /home/xilinx/jupyter_notebooks
python3 test_soundscape_visual.py --overlay 4mic_hdmi_fix.bit
```

确认屏幕能显示方向环后，再运行实时定位：

```bash
python3 realtime_localize_visual.py --overlay 4mic_hdmi_fix.bit --calibration 0,0,2,0 --side-cm 8
```

停止程序：`Ctrl+C`。直接在 Vivado Hardware Manager 下载 bit 只能验证 FPGA 视频静态输出；角度、频率、音量和灯环同步变化必须运行板端 Python 程序。

## 注意

- `soundscape_visual` 和 `soundscape_transfer` 在最终压缩包中存在重复版本；提交 GitHub 时应明确最终采用的版本，避免两套脚本混用。
- 只修改 Python 不会改变 FPGA 中的画面布局；修改 `soundscape_axis_video.v` 后必须重新生成 bit/hwh。
- 修改 HDMI 画面时不要改动 WS2812 的 GPIO 打包、灯珠编号和时序。
