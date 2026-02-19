# SoundStream for macOS

![SoundStream Logo](soundstreamlogo.jpg)

A replica of the classic **SoundStream** screensaver for modern macOS, built with Objective-C and OpenGL.

---

## About / 关于

**English:**

SoundStream was a beloved screensaver that visualized audio input as flowing particle streams. This project recreates that visual effect as a native macOS `.saver` bundle using OpenGL particle rendering.

However, due to macOS sandboxing restrictions on screen savers, **the new macOS screensaver cannot access the microphone**. Apple's ScreenSaver framework runs `.saver` bundles in a sandboxed process (`legacyScreenSaver`) that does not grant microphone permissions — and there is no way to request them. As a result, this version uses autonomous particle animation instead of reacting to audio input.

**中文：**

SoundStream 是一款经典的屏保程序，它能将音频输入可视化为流动的粒子流。本项目使用 Objective-C 和 OpenGL 粒子渲染，将这一视觉效果复刻为原生 macOS `.saver` 屏保包。

但由于 macOS 对屏保的沙盒限制，**新版 macOS 屏保无法访问麦克风**。Apple 的 ScreenSaver 框架在沙盒进程（`legacyScreenSaver`）中运行 `.saver` 包，不会授予麦克风权限，也无法主动申请。因此，本版本使用自主粒子动画，而非响应音频输入。

---

## Features / 功能特性

- Smooth 60fps particle stream animation / 流畅的 60fps 粒子流动画
- HSL color cycling with glow effects / HSL 色彩循环与辉光效果
- OpenGL hardware-accelerated rendering with multisampling / OpenGL 硬件加速渲染，支持多重采样
- Automatic Retina display support / 自动支持 Retina 显示屏
- Particle trail with fade-in/fade-out lifecycle / 粒子拖尾，带有淡入/淡出生命周期
- Stream head with edge-aware steering and braking / 流头具有边缘感知转向与制动

---

## Why No Microphone? / 为什么无法使用麦克风？

**English:**

Starting from macOS Catalina (10.15), screen savers run inside a heavily sandboxed host process. The sandbox profile does not include microphone (`com.apple.security.device.audio-input`) entitlements. Even if you add `NSMicrophoneUsageDescription` to `Info.plist`, the system will never prompt the user for permission — the audio session simply fails silently.

This is a known limitation that affects all third-party `.saver` bundles. The original SoundStream used Quartz Composer (`.qtz`), which had broader system access in older macOS versions.

**中文：**

从 macOS Catalina (10.15) 开始，屏保在严格沙盒化的宿主进程中运行。沙盒配置不包含麦克风（`com.apple.security.device.audio-input`）权限。即使在 `Info.plist` 中添加了 `NSMicrophoneUsageDescription`，系统也不会弹出权限请求对话框——音频会话会静默失败。

这是影响所有第三方 `.saver` 包的已知限制。原版 SoundStream 使用 Quartz Composer（`.qtz`），在旧版 macOS 中拥有更广泛的系统访问权限。

---

## Installation / 安装

**English:**

1. Build the project in Xcode (or use the pre-built `soundstream.saver`)
2. Double-click `soundstream.saver` to install
3. Open **System Settings → Screen Saver** and select **soundstream**

**中文：**

1. 在 Xcode 中构建项目（或使用预编译的 `soundstream.saver`）
2. 双击 `soundstream.saver` 进行安装
3. 打开 **系统设置 → 屏幕保护程序**，选择 **soundstream**

---

## Project Structure / 项目结构

```
soundstream/
├── soundstreamView.h       # ScreenSaverView header / 屏保视图头文件
├── soundstreamView.m       # Main implementation / 主要实现
├── Info.plist              # Bundle configuration / 包配置
├── Soundstream.qtz         # Original Quartz Composer file / 原始 Quartz Composer 文件
├── soundstream.saver/      # Pre-built screensaver bundle / 预编译屏保包
└── soundstreamlogo.jpg     # Project logo / 项目图标
```

---

## Technical Details / 技术细节

| | |
|---|---|
| **Language / 语言** | Objective-C |
| **Rendering / 渲染** | OpenGL (deprecated but functional) |
| **Framework / 框架** | ScreenSaver.framework |
| **Particles / 粒子数** | 900 per stream |
| **Target FPS / 目标帧率** | 60 fps |
| **Min macOS / 最低系统** | macOS 10.13+ |

---

## License / 许可

Copyright © 2026 Henry. All rights reserved.
