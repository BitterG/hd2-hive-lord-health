# 霸王虫血量内存扫描包 (Hive Lord HP MemScan) 1.1.0

只读诊断工具：在游戏进程内扫描内存，用来验证血量管理器/血量表的结构假设。
**它不显示任何东西**，平时用不到，只在排查问题时用。

## 安装

1. 需要 **Bingus Shared Loader v18**
2. 导入 `HiveLord-HP-MemScan-1.1.0.zip`，启用 Core
3. Purge → Deploy
4. 进游戏，把日志发回来

结果写在 `%APPDATA%\Arrowhead\Helldivers2\hivelord_memscan_STATUS.txt`。
