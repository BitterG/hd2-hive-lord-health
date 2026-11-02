# 霸王虫精确血量显示 (Hive Lord Health) v2.0.0 —— 技术说明

> 纯 PUC Lua 5.1 · 基于 MDL3 + HD2 Data Hub (`HD2Data` API 1) · 纯只读零 FFI

## 1. 失效根因分析（v1.10.0 -> v2.0.0）

旧版 v1.10.0 基于旧加载器 Bingus Shared Loader v18 编写，在新版游戏与 **MDL3 (`3.0.0-dev.21-preview`)** 下失效有两个直接原因：

1. **游戏内 Lua VM 已切换为纯 PUC Lua 5.1（无 LuaJIT `ffi`）**：
   旧版第一阶段强依赖 `require('ffi')` 调用 Win32 `GetModuleHandleA` 与 `ReadProcessMemory`。在 MDL3 的游戏内 Lua 5.1 虚拟机中，`require('ffi')` 会直接抛出异常拒绝加载。
2. **硬编码 PE 校验与 RVA 已随游戏更新彻底过期**：
   旧版锁死了旧游戏构建 `25480438` 的 PE 头特征与固定偏移（`game.dll+0x3326688` / `0x346BF98`）。当前游戏版本（如 `25988413` / `26251122`）不仅内存布局已变，且代码页按需解密，直接在 Lua 里裸读固定 RVA 既不兼容也不安全。

## 2. v2.0.0 数据架构：`HD2Data` (API 1) 事件驱动

新版完全移除了 `ffi`、Win32 API 与硬编码偏移，改为通过 **HD2 Data Hub (`>= 0.3.0`)** 提供的公开只读全局接口 `_G.HD2Data` (`api == 1`) 获取霸王虫生命值：

- **实体识别双重校验**：
  - 优先匹配语义目录标识：`e.semantic_id == 'enemy/v1/terminids/hive_lord'`（以及 `e.entity:is('enemy/v1/terminids/hive_lord')`）。
  - 兼容回退匹配 64 位类型哈希：`e.type:upper() == 'D465D9C7F77A07CB'`（默认最大生命值 `150,000`）。
- **关键事件闭环**：
  - `entity_spawned`：霸王虫生成时立即建档显示 `150,000 / 150,000 (100.0%)`；若检测到刚潜地的残血霸王虫记录，则触发破土继承（`HIVE_LORD_RESURFACE`），避免新实体 ID 导致血条误回满。
  - `entity_damaged`：实时同步精确 `e.health`、`e.max_health` 与单次伤害 `e.damage`；若玩家中途加入战局错过了 `entity_spawned`，首次命中即刻建档（`mid-fight attach`）。
  - `entity_died`（**致命一击必订事件**）：在 HD2 Data Hub 内部实现中，当目标生命状态切入死亡（`life >= 2`）时直接走 `if life >= 2` 分支派发 `entity_died`，**不会再触发 `elseif` 分支的 `entity_damaged`**。因此必须订阅 `entity_died` 才能保证最后一击准确归零为 `0 / 150,000 (SLAIN)`。
  - `mission_started` / `mission_ended` + `HD2Data.mission()` `epoch` 校验：任务切换或返回舰桥时立即清空上一局残留状态。
- **热重载与掉线自愈**：
  - 轮询检查每个订阅句柄的 `sub:active()`，若 Hub 热重载替换了 `_G.HD2Data` 表或重置了订阅，自动退订旧句柄并重连全部 5 个事件；`shutdown()` 时完整调用 `sub:unsubscribe()` 并清空全局哨兵 `_G.__HIVELORD_HEALTH`。

## 3. Stingray GUI 渲染安全不变量

参考 `MDL3` 运行时与实战验证过的原生字体 HUD 模式，`hivelord_health.lua` 严格执行以下引擎安全约束：

1. **兼容 Stingray 可调用表构造器 (`is_ctor`)**：
   引擎中的 `stingray.Vector2`、`stingray.Vector3`、`stingray.Color` 为带有 `__call` 元方法的类表（例如同时提供 `Vector3.x(v)` 方法与 `Vector3(x, y, z)` 构造调用），`type(...)` 返回 `'table'` 而非 `'function'`。绘制前统一通过 `is_ctor` 判定，避免误判 API 缺失。
2. **`IdString64.from_hex` 绝不跨帧缓存**：
   Stingray 的 `IdString64` 临时值仅在当前帧有效，跨帧复用会导致引擎底层崩溃或材质失效。每次重建文本图层时均在当帧内即时生成 `IdString64` 并通过 `Application.can_get` 校验 `font` / `material` / `texture` 均已就绪后绑定材质槽位（`88bac99b00000000` 等）。
3. **原生 UI 字体层 (`M.text_gui`) 与进度条矩形层 (`M.gui`) 分离**：
   - 底层 `M.gui` 仅承载 4 个常驻矩形句柄（底框、底槽、受击缓冲条、当前血条），通过 `Gui.update_rect` 原地更新，零句柄泄漏。
   - 顶层 `M.text_gui` 在 `M.gui` 之后创建（确保文字始终浮于血条之上），专门绘制 `MDL3.ui.fonts` 原生游戏字体文本。**绝不对原生字体句柄调用 `Gui.update_text` 或 `Gui.destroy_text`**；仅在文字内容变化时（高频受击下限流 `<= 20 Hz`）在确认 `world` 身份存活（`v == M.text_world`）的前提下以 `World.destroy_gui` 整体替换 `M.text_gui`。
   - 当 `MDL3.ui.fonts` 尚未发布或世界包装器不具备引用同一性时，自动回退至 `M.gui` 上的 `'core/performance_hud/debug'` 调试字体（最多保留 2 个文本句柄并通过 `Gui.update_text` 原地刷新），且总表面创建次数受 `surface_cap = 12` 硬上限保护。
4. **CJK 字库探测与 ESC 面板置顶**：
   - 使用 `Gui.text_extents` 对比 `"霸王虫"` 与 `"???"` 的像素宽度；若相等说明当前游戏语言贴图集不含中文字符，自动降级为纯英文标题 `'HIVE LORD'`。
   - 当玩家打开 `ESC -> MDL 设置` 调整本模组滑块时，自动开启临时预览并在 `MDL3.panel` 重建后延迟 `0.14s` 重建自身 GUI，使血条始终浮于设置面板正上方以便直观对齐。

## 4. 构建与离线验证

在项目根目录（`hd2-hive-lord-health`）下执行：

```powershell
# 1. 运行离线模拟测试套件（41 项功能/边界断言）与变异回归测试（9 项变异全捕获）
python tests/test_health.py
python tests/test_health.py --all-mutations

# 2. 构建 Stingray .patch_0 归档与可安装模组压缩包（含静态白名单与加载器验收测试）
python scripts/build_addons.py --self-test
python scripts/build_addons.py --target health

# 3. 独立校验产出的压缩包结构与字节码加载
python tests/loader_accept.py --self-test
python tests/loader_accept.py --zip dist/HiveLord-HP-Health-2.0.0.zip
```
