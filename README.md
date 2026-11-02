# 霸王虫精确血量显示 (Hive Lord Health) v2.0.0

适配 **MDL3** 与 **HD2 Data Hub (0.3.0+)** 的《绝地潜兵 2》霸王虫实时精确 Boss 血量条模组（纯只读、零内存写入、跨版本自动适配）。

```text
          霸王虫 HIVE LORD   92,400 / 150,000  (61.6%)
  [████████████████████████████░░░░░░░░░░░░░░░░░]
            实时追踪 LIVE   |   -57,600 DMG
```

## 功能特性

- **实时精确血量与缓冲血条**：通过 `HD2Data` (API 1) 订阅霸王虫生成、受伤与死亡事件，实时绘制战术金/橙/红三段变色进度条、受击残影缓冲条、精确数值与百分比。
- **潜地保留与破土继承**：霸王虫钻入地下潜行时保留最后已知血量并标记 `潜地 SUBMERGED`；重新破土（即使引擎分配新实体 ID）自动继承剩余血量，不会误跳回满血。
- **击杀归零保持**：最后一击触发 `entity_died` 时立即归零显示 `0 / 150,000 (0.0%)` 与 `已击杀 SLAIN`，保持指定秒数后自动淡出。
- **游戏原生中文字体 + 自动回退**：优先绑定 `MDL3.ui.fonts` 游戏原生 UI 字体渲染中英双语标题（若当前游戏文本语言字库不含中文字符，自动切换英文 `HIVE LORD` 防止方块/问号乱码；无原生字体时自动回退至 `core/performance_hud/debug`）。
- **ESC 菜单实时预览调参**：支持在舰桥或任务中按 `ESC -> MDL 设置 -> 霸王虫血量显示 (Hive Lord HP)` 拖动滑块，血条将自动置顶显示实时预览效果。

## 前置依赖与安装步骤

1. **安装前置（必需）**：
   - **MDL3**（`MDL3-3.0.0-dev.21-preview` 或更高版本，在模组管理器中同时勾选 `MDL3 Loader` 与 `HD2 Data Hub`）。
2. **导入本模组**：
   - 在 Arsenal / HD2 Mod Manager 中导入 `HiveLord-HP-Health-2.0.0.zip`，勾选启用 **霸王虫血量显示模组本体 (Hive Lord Health)**。
   - 加载顺序要求：**MDL3 Loader** -> **HD2 Data Hub** -> **霸王虫血量显示**（MDL3 会自动按脚本类型加载插件，无需严格手动排序，只需确保三者均已启用并部署）。
3. **部署并启动游戏**：
   - 点击 **Purge（清理） -> Deploy（部署）**，启动游戏即可。

## 游戏内设置与配置文件

- **游戏内实时调节（推荐）**：
  进入游戏后按 `ESC` 打开 **MDL 设置**，找到 **霸王虫血量显示 (Hive Lord HP)**，可实时调整：
  - 显示开关、舰桥预览开关
  - 血条位置（顶部居中 / 底部居中）
  - 界面缩放 (`0.50x` – `2.50x`)、垂直边距 (`20` – `500 px`)、不透明度 (`0.20` – `1.00`)
  - 实心进度条开关、击杀后保留秒数 (`0` – `15 s`)

- **本地配置文件（可选）**：
  首次运行会在以下目录自动生成（**已有配置文件绝不会被覆盖**，删除后重进游戏可恢复默认）：
  ```text
  %APPDATA%\Arrowhead\Helldivers2\hivelord_health.cfg
  ```

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `hud` | `true` | 是否在屏幕绘制血量条（设为 `false` 时仅记录日志） |
| `hud_position` | `top` | 血条锚点位置：`top`（屏幕上方罗盘下）或 `bottom`（屏幕下方） |
| `hud_scale` | `1.00` | 在 1080p 自适应基础上的额外缩放倍率 |
| `hud_offset_y` | `135` | 距离顶部或底部边缘的基准像素边距 |
| `hud_alpha` | `0.90` | 整体不透明度 (`0.20` – `1.00`) |
| `hud_bar` | `true` | 是否绘制实心进度条与受击残影槽 |
| `burrow_hold_seconds` | `60.0` | 霸王虫潜地后保留血条显示的秒数 |
| `death_hold_seconds` | `5.0` | 霸王虫被击杀归零后保留显示的秒数 |
| `debug` | `false` | 是否将每次细微受击写入详细日志 |

## 状态自检与故障排查

运行状态与日志位于 `%APPDATA%\Arrowhead\Helldivers2\`（若受限则回退至 `%LOCALAPPDATA%\MDL3\`）：
- `hivelord_health_STATUS.txt`：一行式当前诊断结论（如 `READY (ready) - waiting for Hive Lord in mission` 或 `WAITING - HD2Data global not found yet`）。
- `hivelord_health.log`：完整运行日志。若提示 `HD2Data global not found yet`，请检查模组管理器中是否勾选启用了 **HD2 Data Hub**。
