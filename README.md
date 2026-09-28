# 霸王虫精确血量 (Hive Lord Health) 1.10.0

在屏幕上显示霸王虫的**精确血量**：随伤害实时下降，死亡时归零。

```
HIVE LORD  139593 / 150000
exact, from the health manager (entry 88 of 95)
```

## 安装

1. 需要 **Bingus Shared Loader v18**
2. 导入 `HiveLord-HP-Health-1.10.0.zip`，启用 Core
3. Purge → Deploy
4. 进游戏，找到霸王虫开打；血量出现在屏幕上方中间

## 设置（可选）

配置文件在第一次运行时自动生成：

```
%APPDATA%\Arrowhead\Helldivers2\hivelord_health.cfg
```

| 改什么 | 作用 |
| --- | --- |
| `hud = false` | 不显示血条，只记日志 |
| `hud_offset_y = 120` | 血条距屏幕顶部的距离 |
| `hud_scale = 1.0` | 血条整体大小 |

日志也在同一个目录：`hivelord_health.log`、`hivelord_health_STATUS.txt`。
