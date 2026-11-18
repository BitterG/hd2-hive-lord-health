# 霸王虫精确血量与定位 (Hive Lord Health & Locator) v2.3.0 —— 技术说明

> 纯 PUC Lua 5.1 · 基于 MDL3 (`MDL3.gui` API 1) + HD2 Data Hub (`HD2Data` API 1) · 纯只读零 FFI

## 1. 失效根因分析（v1.10.0 -> v2.0.0+）

旧版 v1.10.0 基于旧加载器 Bingus Shared Loader v18 编写，在新版游戏与 **MDL3 (`3.0.0-dev.21-preview` 及更高版本)** 下失效有两个直接原因：

1. **游戏内 Lua VM 已切换为纯 PUC Lua 5.1（无 LuaJIT `ffi`）**：
   旧版第一阶段强依赖 `require('ffi')` 调用 Win32 `GetModuleHandleA` 与 `ReadProcessMemory`。在 MDL3 的游戏内 Lua 5.1 虚拟机中，`require('ffi')` 会直接抛出异常拒绝加载。
2. **硬编码 PE 校验与 RVA 已随游戏更新彻底过期**：
   旧版锁死了旧游戏构建 `25480438` 的 PE 头特征与固定偏移（`game.dll+0x3326688` / `0x346BF98`）。当前游戏版本不仅内存布局已变，且代码页按需解密，直接在 Lua 里裸读固定 RVA 既不兼容也不安全。

## 2. v2.3.0 数据、定位与配置架构：`HD2Data` (API 1) + `MDL3.gui` (API 1)

新版完全移除了 `ffi`、Win32 API 与硬编码偏移，通过 **HD2 Data Hub (`>= 0.3.0`)** 提供的公开只读全局接口 `_G.HD2Data` (`api == 1`) 实时追踪霸王虫精确主生命值与空间位置：

- **实体识别双重校验**：
  - 优先匹配语义目录标识：`e.semantic_id == 'enemy/v1/terminids/hive_lord'`（以及 `e.entity:is('enemy/v1/terminids/hive_lord')`）。
  - 兼容回退匹配 64 位类型哈希：`e.type:upper() == 'D465D9C7F77A07CB'`（默认最大生命值 `150,000`）。
- **关键事件闭环与坐标采集**：
  - `entity_spawned`：霸王虫生成时立即建档显示 `150,000 / 150,000 (100.0%)` 并记录 `e.entity:position()`；若检测到刚潜地的残血霸王虫记录，则触发破土继承（`HIVE_LORD_RESURFACE`），完整保留剩余血量并立即刷新新坐标。
  - `entity_damaged`：实时同步精确 `e.health`、`e.max_health`、单次伤害 `e.damage` 与受击位置 `e.entity:position()`；若玩家中途加入战局错过了 `entity_spawned`，首次命中即刻建档（`mid-fight attach`）。
  - `entity_died`（**致命一击必订事件**）：保证最后一击准确归零为 `0 / 150,000 (SLAIN)` 并记录 `e.position`。
  - **约 30 Hz `GameSession` 实时坐标追踪（防出土点冻结）**：针对霸王虫在引擎中根骨架节点可能停留在出土穴导致 `entity:position()` 冻结的问题，模组在 `HD2Data` 获取 `network_id` 与初始参考坐标后，在安全只读白名单内（`Network.game_session`、`GameSession.in_session` / `game_object_exists` / `game_object_field_batched`，配合 `^Vector3%(` 字符串校验）按 ~30 Hz (`0.033s`) 扫描 `network_id`、其表字段关联子对象及 `base ± 6` 邻近对象的 `Vector3` 字段，一旦监测到位移 `>= 0.5m` 即锁定移动字段 (`goid_live`) 持续更新，并屏蔽后续停留在出土穴 (`<= 1.0m`) 的 `entity_damaged` 坐标回弹；若事件未附带 `network_id`，则以每帧最多 256 个槽位的分片预算在 `1..16384` 内定位匹配最大血量与参考坐标的对象。
  - **玩家朝向与距离投影**：仅在存在活跃或潜地霸王虫时按帧租约读取 `D.player()`、`D.aim().forward` 与（可选）`D.players(false)`，基于 Stingray ENU 水平面（`+X` 东、`+Y` 北、`+Z` 上）计算 3D 距离与相对玩家朝向的 `(right, forward)` 分量，零霸王虫时不占用 Hub 轮询租约。
  - `mission_started` / `mission_ended` + `HD2Data.mission()` `epoch` 校验：任务切换或返回舰桥时立即清空上一局残留状态。
- **`hivelord_health.cfg` 与 `ModOptionsMenu` 双向同步及双语切换**：
  - 支持 `language` 配置项（`auto` 跟随 `BingusTranslations` / `MDL.i18n` / `MDL3.ui.language`，或强制指定 `zh` / `en`）；`ModOptionsMenu` 标签与 `hivelord_health.cfg` 双向持久化，并配合原生字体 CJK 字形探测（`cjk_probe`）防止拉丁字库下出现乱码。
  - 游戏内通过 `ESC -> MDL 设置` 调整语言、血条与定位雷达参数（`language`、`hud_*`、`locator_*`）时，自动防抖写回 `hivelord_health.cfg` 并即时重绘；游戏重启后从 `hivelord_health.cfg` 读取并回推至 `ModOptionsMenu` 控件状态。

## 3. Stingray GUI 与 `MDL3.gui` 渲染安全不变量

1. **兼容 Stingray 可调用表构造器 (`is_ctor`)**：
   引擎中的 `stingray.Vector2`、`stingray.Vector3`、`stingray.Color` 为带有 `__call` 元方法的类表，绘制前统一通过 `is_ctor` 判定。
2. **`IdString64.from_hex` 绝不跨帧缓存**：
   每次重建文本图层时均在当帧内即时生成 `IdString64` 并通过 `Application.can_get` 校验 `font` / `material` / `texture` 均已就绪。
3. **原生 UI 字体层 (`M.text_gui`) 与进度条矩形层 (`M.gui`) 分离**：
   - 底层 `M.gui` 承载最多 4 个常驻矩形句柄（外框、底槽、受击残影缓冲条、血量填充条），通过 `Gui.update_rect` 原地更新，零句柄泄漏。
   - 顶层 `M.text_gui` 承载最多 2 行文本（主标题、状态副标题）。**绝不对原生字体句柄调用 `Gui.update_text` 或 `Gui.destroy_text`**。
4. **`MDL3.gui` 双层画布零重建原则（`dev.41+`）**：
   - 图形画布 `loc_shape_canvas`（`layer = 62`）固定每帧发射完全相同的 22 个图元槽位（未使用槽位以 `{0,0,0,0}` 移至屏幕外），保证玩家转动视角或目标进出雷达范围时 100% 原地更新、零画布重建。
   - 文字画布 `loc_text_canvas`（`layer = 64`，高于图形层）仅在内容或量化位置变化时按 `<= 10 Hz` 节流重建，不影响底层图形画布；`MDL3.gui` 不可用时自动退回至血条副标题距离显示。

## 4. 构建与离线验证

在项目根目录（`hd2-hive-lord-health`）下执行：

```powershell
# 1. 运行离线模拟测试套件与变异回归测试
python tests/test_health.py
python tests/test_health.py --all-mutations

# 2. 构建 Stingray .patch_0 归档与可安装模组压缩包（含静态白名单与加载器验收测试）
python scripts/build_addons.py --self-test
python scripts/build_addons.py --target health

# 3. 独立校验产出的压缩包结构与字节码加载
python tests/loader_accept.py --zip dist/HiveLord-HP-Health-2.3.0.zip --expect mods/hivelord/hivelord_health
```
