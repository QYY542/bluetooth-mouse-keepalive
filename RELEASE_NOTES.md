# Bluetooth Mouse Keepalive 1.1.2

去掉菜单栏左侧的小鼠标图标，只显示可自定义的文字和状态圆点。应用本身的 Logo 保留。

下载 `Bluetooth-Mouse-Keepalive-1.1.2-macOS.zip`，完整解压后运行 `Install.command`，或放入 Applications。支持 macOS 13+，含 Apple Silicon 和 Intel 架构、中文 README 和构建源码。

保活通信方式、5 / 10 / 15 秒间隔、自动重连和登录启动功能均沿用上一版。旧设置保存在本机。临时签名应用更新后，macOS 可能要求重新开启输入监控并退出重开。

已通过构建、签名、离线检查与通信小进程故障恢复测试。其他 BLE 鼠标仍属于兼容尝试，读取成功不保证能阻止休眠；Intel 尚未实机验证。
