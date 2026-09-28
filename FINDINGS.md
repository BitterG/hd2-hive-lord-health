# 霸王虫血量显示 —— 侦察结论与下一步

目标：给《绝地潜兵2》的霸王虫（Hive Lord）做血量显示 UI。
当前阶段：**先确认能不能正确读到血量**，UI 暂缓。

---

## 1. 一句话结论

血量**可以**通过游戏自己暴露的引擎 Lua 接口读到，不需要 FFI 扫内存：

```lua
local sr = rawget(_G, 'stingray')
local GS, Net = sr.GameSession, sr.Network
local session = Net.game_session()
local f = GS.game_object_field_batched(session, game_object_id, {})  -- 返回字段数组
```

`f` 是一个按该对象类型字段表顺序排列的数组。**关键难点不是"读"，是"找到霸王虫
的 game object id，并确定血量在第几个字段"。**

## 2. 证据：这个接口确实能读血量（`DRIVER_HUD` 1.2.1）

工作区里 `DRIVER_HUD_1.2.1` 是一个已发布、能用的 Bastion 坦克 HUD mod，
它读**车体实时血量**的方式就是这条路。解包后（59850 字节明文 Lua，
`work/hivelord/extracted/`）：

| 位置 | 内容 |
|---|---|
| 第 6 行 | `local App,Net,GS,World,Gui = sr.Application,sr.Network,sr.GameSession,sr.World,sr.Gui` |
| 第 61 行 | `local f=call(GS.game_object_field_batched,session,id,{})` |
| 第 72 行 | `hull_sig`：`f[15]` 是**最大血量**（Bastion = 8000），`f[30]` 是**当前血量** |
| 第 805 行 | 10 Hz 刷新：`c.hp=hf[30];c.max=hf[15]` |
| 第 846 行 | `rect(..., 294*s*M.hp/M.max, ...)` —— 血条就是这么画的 |
| 第 307/683 行 | `Net.object_info(type)` 返回 `{fields={{id="49c250a6"},...}}` |
| 第 380-670 行 | 作者内置的**类型字段表快照**：`{t="rHVbvgIu",n=27,h5="ec64918b",...}` |

两条重要推论：

1. **字段哈希是全局一致的**，但**数组下标是每种类型各自的**。同一张表里
   `h6="d7a5d63e"` / `f6="BLKY2IrV"`（同轴机枪弹药）在别的类型里出现在下标 11。
   所以"血量 = 第 30 个字段"这句话**只对 Bastion 车体成立**，对霸王虫必须重新定位。
2. `Net.object_info(类型名)` 需要**8 字符的混淆类型名**（`rHVbvgIu`、`un6y1d`…），
   这些名字**在磁盘上是加密的**：全盘扫描
   `E:\SteamLibrary\steamapps\common\Helldivers 2`（176 个文件）对
   `rHVbvgIu`/`fZwFCDKT`/`BLKY2IrV`/`game_object_field_batched`/`object_info`
   **全部 0 命中**。只有进程运行时才可见。

## 3. 反面证据：这条路踩过一次大坑（必须记住）

`work/` 里另有一个曾经的探测 mod（`FRVProbe`）。它的日志
（`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\FRVProbe.log`，共 5 行）停在：

```
--- session discovery ---
Net.game_session() -> userdata=[GameSession] | nil
  Net.game_session()       in_session=false | nil
```

之后没有任何输出，而同一时段 `%APPDATA%\Arrowhead\Helldivers2\dumps\` 里
**连续出现 4 个崩溃转储**（15:56 / 15:57 / 15:58 / 16:01）。

`M103-Supply-FRV-Gravity-Factor/tests/check_entry.py` 第 11-12 行把这个教训
写进了静态检查：

> *the earlier probe resource used the game's stingray entity API and crashed
> the game twice - that API must not come back.*

而且它的禁用正则包含 `game_object_|set_game_object_field|GameSession|
Network\.object_info`。

**教训**：那个探测在**遍历 `Network` 表并逐个调用成员**看返回值。
用错误的参数个数调用引擎函数，或传一个不存在的类型名，是**原生访问违例，
不是 Lua 错误 —— `pcall` 拦不住**。所以：

* 只允许调用**已被 DRIVER HUD 证明安全**的成员；
* 绝不"探测性地"调用未验证的引擎函数；
* 把危险的调用**先写日志再执行**，这样崩溃点会自己写在日志最后一行。

这条已经固化成 `HiveLord-HP/scripts/build.py` 的静态检查
（"no engine member outside the allow-list is referenced"）和
`HiveLord-HP/tests/` 里的一个变异测试。

## 4. 离线确定的霸王虫血量数值（逐字节）

数据源：`filediver/datalibrary/generated_entities.dl_bin`（45,630,790 字节
**明文**镜像）；结构权威是游戏自带的 `dl_library.dl_typelib`（用
`tools/dltypelib.py` 精确解析，1177 个类型）。健康值是 **int32**（不是 float）。
完整报告与脚本：`work/hivelord/HIVE_LORD_HEALTH.md`（+ `01…09` 脚本与 JSON）。

| 项 | 值 |
|---|---|
| LDLD 块 magic | `0x0075F1EE`；magic 前 4 字节即类型哈希 |
| 类型哈希 | `0xB3915DE3` == `djb2("HealthComponentData")`（对 `dl_type_names.txt` 暴力验证唯一）|
| 块声明大小 | 10,909,072 == typelib 的 `sizeof(HealthComponentData)` |
| 载荷起点 | magic+24 = `0x0075F206`（用"下一个 LDLD magic 恰在 magic+28+size"验证，不是假设）|
| 记录 index | **27**（hashmap 槽 459 的 Index=27，其 Resource = `murmur64a("content/fac_bugs/cha_hive_lord/cha_hive_lord")`；且 493 条记录里只有它含 `crown`/`jaws` 部位）|
| 记录跨距 | **22096 (0x5650)** = `HealthComponent` |
| 固定部分 | **1120 B** |
| `DamageableZoneInfo` / `DamageableZone` | 456 / **552 (0x228)** ← 这就是观测到的 0x228 间隔 |
| 部位数组 | 记录+0x208，38 个，stride 552；`Health` @zone+0xE8，`Constitution` @zone+0xEC |

记录 27 的固定字段（偏移即字面值）：
`Health` +0x00=150000；`Constitution` +0x18=0；`Size` +0x28=3 (UnitSize_Massive)；
`Mass` +0x2C=30000.0；`KillScore` +0x30=2000。
默认部位 `DefaultDamageableZoneInfo`（+0x40）的 `Health` 是 **−1** —— 这正是
早先"在 0x7F4A36..0x7F4CE6 之间扫不到 150000"的原因。

38 个部位（Health/Constitution）：
`0:150000/0 jaws · 1:150000/0 crown · 2-7:15000/35000 spine5..spine0 ·
8:20000/35000 boss · 9-14:15000/35000（含 defeat_arrowhead、boss_back）·
15-21:150000/0（含 body_head）· 22,23:10000/0 · 24-37:5000/0（*_leg）`

**wiki 逐项吻合，零数值分歧，未见构建漂移。** 解析出的多重集
`150000×9 + (15000+35000)×12 + (20000+35000)×1 + 10000×2 + 5000×14 = 38`
正好复现 wiki 的 Crown/Jaws/Mouth/Inner Flesh/Dorsal/Sterna/Lower Sterna/
Mandibles/Fins 清单；差别只在命名与顺序（引擎把"Fins"叫 `*_leg`，
背板叫 `spine0..5`）。早先 int32 扫描的 42 个偏移全部重新读回并映射，
0 个无法解释，0 个不符。

> ⚠ 一条重要的**假设修正**：`stingray.ThinHash` 是 **uint32（4 字节）**，
> 等于 `MurmurHash64A(name,0)` 的**高 32 位** —— 不是 8 字节。
> 这就是 `456 + Actors[24]×4 = 552` 能成立的原因。

## 5. 这次交付的探测包

`HiveLord-HP/dist/HiveLord-HP-Probe-1.0.0.zip`

| 阶段 | 做什么 | 风险 |
|---|---|---|
| A | **只列**引擎 Lua 接口的名字和类型，一次调用都不发 | 无 |
| B | 用已验证安全的调用报告 session / peer / 拥有的对象 / `object_info` 字段表 | 低 |
| C | `game_object_exists` 普查 id 1..32766，列出所有活动实体 | 低 |
| D | 对每个实体 `game_object_field_batched`，按第 4 节的指纹打分 | **本次唯一未经验证的调用** |
| E | 命中者：导出完整字段数组，并每秒复查记录变化 | 低 |

安全设计：

* **写前日志（write-ahead）**：每个危险调用执行前先落盘，崩溃点自己写在日志末行。
* **断点续扫**：`hivelord_state.txt` 记游标，重启游戏从崩溃点的下一个 id 继续，
  不会重复崩在同一处。
* **只在任务里扫**（`in_mission_only`），飞船里不做 D。
* **先写后做、随时 flush**，任何时刻崩溃都有产物。
* 只输出到 `%APPDATA%\Arrowhead\Helldivers2\`（若不可写则依次退化到
  `%LOCALAPPDATA%\CowboyBingus\...\Logs`、`%TEMP%`、当前目录）。

离线验证：`HiveLord-HP/tests/run_tests.py`（lupa 假引擎，19 项全过），
5 个变异测试全部被抓（含"故意加一个投机引擎调用"和"删掉写前游标"）。

## 6. 下一次上机要回答的问题

1. `hivelord_api.txt` 里 `GameSession` / `Network` 有没有**枚举函数**
   （比如 `objects_*` / `*_of_type`）？有的话下一版就能直接按类型取对象，
   不用再扫 id 空间。
2. `hivelord_census.txt` 里 id 空间有多大、任务里有多少实体。
3. `hivelord_cand*.txt`：霸王虫的**字段总数**和**血量字段下标**，
   以及满血时那一串 150000/35000/15000/5000 出现在哪些下标上。
4. `WATCH` 行：挨打后哪些下标在掉 → 那就是 main health 的字段；
   哪些不变 → 是各部位的**上限**。

拿到 3、4 之后，下一版才能：把"当前血量 / 最大血量"两个下标固化成常量 + 用
字段哈希做身份校验，然后才谈 HUD 怎么画。

## 7. 兜底方案（并行交付）

`HiveLord-HP/dist/HiveLord-HP-MemScan-1.0.0.zip`

完全不调用引擎实体接口（因此不可能重演那个崩溃），只在进程内存里按第 4 节的
字节布局找 `HealthComponent`：

* **主特征**：`Health=150000` 紧跟 `HealthChangerate=0.0`（8 字节），
  再用 `Constitution=0` / `Size=3` / `Mass=30000.0` / `KillScore=2000`
  打分（≥4/6 才认）。
* **补充特征**：相邻的 `15000` + `35000`（某个部位的 Health/Constitution）。
  部位上限不随伤害变化，所以**扫描开始前就已经掉血的霸王虫**靠这条也能找到 ——
  这是主特征在构造上必然漏掉的情形。
* 命中后每 2 秒回读 `Health`，变化写 `WATCH_CHANGE` —— 那一行就是
  "实时血量确实读到了"的直接证据。
* 每帧最多 6 ms CPU、单次读 512 KB、分片推进；断点存在
  `hivelord_mem_state.txt`；pcall 的错误**不吞**，一律写日志。

离线验证：`HiveLord-HP/tests/test_memscan.py`（lupa 假内存空间 + 类型严格的
FFI 桩，17 项全过，连跑三次稳定），5 个变异测试全部被抓 ——
其中两个（`no-chunk-overlap`、`restart-region-each-frame`）需要专门设计夹具
才抓得住：一个把 8 字节特征**横跨 chunk 接缝**放，并且要求命中必须来自
**主特征**而不是补充特征；另一个把每帧预算调到 1 µs，逼出"每个内存区跨帧"。

## 8. 测试与构建状态

| 命令 | 结果 |
|---|---|
| `python HiveLord-HP/tests/run_tests.py` | 21 项全过 |
| `python HiveLord-HP/tests/test_memscan.py` | 17 项全过（连跑 3 次稳定） |
| `python HiveLord-HP/tests/test_hp.py` | 22 项全过 |
| `python HiveLord-HP/tests/test_hp.py --hud` | 23 项全过 |
| **15 个变异测试** | **15/15 全部被抓** |
| `scripts/build_addons.py --target probe\|memscan\|hp` | 静态检查 + 归档 round-trip 全过 |

离线仿真过程中抓出的**真实 bug**（都已修，且都有对应的变异测试）：

1. 候选只有在**第一帧**才导出 → 命中永远不落盘；
2. 日志目录不存在时**一个字节都不写** → 改成候选目录链（APPDATA → LOADER → TEMP → `.`）；
3. 内存区扫描的偏移**不跨帧保存** → 大内存区每帧从头开始，永远扫不完；
4. 内存区游标是 **0 基**而 Lua 数组是 1 基 → 第一个内存区被当成不存在而跳过；
5. `pcall` **吞掉**扫描错误 → 表现为"一直在扫"，永远没有产物；
6. `r.data`（夹具字段）误用进扫描器 → 现场必崩；
7. `%d` 配一个**小数**配置值 → LuaJIT 容忍，严格 Lua 直接报错；
8. 扫描收尾的 `SCAN_DONE` 被**放在预算判断之后** → 小预算时永远不写结论行；
9. 完成判断用 `<` 而不是 `<=` → 每帧只能扫一个内存区时，**最后一个区永远不扫**；
10. **当前血量字段只从"现在还是 150000"的字段里找** → 挨打过的字段已经不是
    150000，因此**永远找不到当前血量**。必须从"曾经是 150000"的历史里找
    （这是本轮最要命的一个，`cur_idx` 会永远是 nil）。

## 9. 交付物三件套

| 包 | 作用 | 何时用 |
|---|---|---|
| `dist/HiveLord-HP-Reader-1.0.0.zip` | **正式交付**：认出霸王虫 + **运行时自定位血量字段** + 每秒读数 + 可选文字 HUD | 默认用这个 |
| `dist/HiveLord-HP-Probe-1.1.0.zip` | 更瘦的诊断包（不打 HUD，不做自定位） | 想先只做只读侦察时 |
| `dist/HiveLord-HP-MemScan-1.0.0.zip` | 兜底：不碰引擎实体接口，按字节特征在内存里找 | Reader 认不出来时 |

**为什么 Reader 不需要第二次上机**：引擎的字段数组是**按类型各自的位置**排列的，
下标不能照抄（DRIVER HUD 用车体证明了下标 15=上限 / 30=当前，但同一个"同轴弹药"
字段在别的类型里在下标 6 和 11）。所以 Reader 改成**按数值语义现场推**：

* **上限** = 值停在 `150000` 不动的那一个；
* **当前值** = 数值掉下去的那一个（关键：必须查"曾经是 150000"的历史，
  挨打后的字段已经不是 150000 了）；
* **主池** = 掉得最多的那一个（主池接收各部位转移过来的伤害）；
* **部位数组** = 最长的、连续全是已知部位上限值的那一段；上限通常是它前面那个。

`hivelord_hp.log` 的 `HP` 行会把推导结果**和理由**一起写下来
（字段总数 / 上限下标 / 当前值下标 / 掉量 / 动过的字段 / 部位数组区间），
所以即使启发式选错了，也能据此把下标固化成常量。断点与已锁定的 goid 存在
`hivelord_hp_state.txt`，重开不再扫 32766 个 id。

### 9.1 给"唯一一次上机"买的保险

强判定（"数组里有 10 个 150000"）**是个猜测**：已发布的 DRIVER HUD 读的车体
数组只有 35 个字段、一对 max/current、**没有任何部位数组**。如果霸王虫的数组
也是这样，强判定永远不触发，那一次上机就白费了。所以：

* 凡是字段里出现过 `150000` 的对象，**整个数组导出**到
  `hivelord_hp_weakN_goidM.txt`（上限 64 个）；
* 每 15 秒写一次 `SCOREBOARD`：按 `n150k` → `distinct` 排序的候选表（前 12）。

这样猜错也不会有损失——答案已经在磁盘上。离线夹具里专门造了一个
**sparse 霸王虫**（只有 max+current，没有部位数组）来验证这条路：强判定不触发、
弱导出照常、SCOREBOARD 按 `n150k=2` 排到第一。

## 10. 实心血条需要的资源格式（已解出，暂未使用）

DRIVER HUD 用 `Gui.triangle(gui, v1,v2,v3, 3, color, material, uv,uv,uv)` 画实心
矩形，其中 `material='mods/driver_hud/solid'`。它把那个名字打包成了**两个**资源：

| 资源名哈希 | 类型哈希 | 名称 | 大小 |
|---|---|---|---|
| `0xc6ac4930a4cd744e` | `0xcd4238c6a0c69e32` | `resource_hash("texture")` | 340 B |
| 同上 | `0xeac0b497876adedf` | `resource_hash("material")` | 160 B |

（顺带验证了 `resource_hash("lua") == 0xA14E8DFA2CD117E2`，即资源类型哈希就是
murmur64a(类型名)。）

**贴图 340 B = 纯头部，没有像素数据**：192 B 的 Stingray 贴图头
（`+0x08 = 0xffffffff`，其余为 0）+ 148 B 的 DDS
（`DDS ` magic @192，124 B `DDS_HEADER`，20 B `DX10` 头）。
DDS 里：高 16 / 宽 8 / pitch 128 / depth 1 / mip 5，`ddspf.dwFourCC="DX10"`，
`dxgiFormat=77`、`resourceDimension=3`（TEXTURE2D）、`arraySize=1`。
**零像素字节** —— 说明真正决定颜色的是 shader + 顶点色（`Gui.triangle` 传了
`color`），贴图槽只是个占位符。

**材质 160 B，布局已逐字段确认**：

```
+0x00  0x120=288, 1, 24, 124    头部/大小
+0x40  1
+0x80  u32 = 0x5f8113d2         shader id（未破解：154,600 个名字里没有）
+0x88  u32 = 0x3aa8b87e         = ThinHash("diffuse_map")  ← 已破解，贴图槽名
+0x8c  u64 = 0xc6ac4930a4cd744e 引用的贴图资源名哈希（与材质自己同名！）
```

破解方法：`ThinHash(name) = MurmurHash64A(name,0) >> 32`（**32 位**，不是 8 字节），
对 `filediver/hashes/*.txt` 全部 154,600 个名字做暴力匹配，`0x3aa8b87e` 唯一命中
`diffuse_map`。shader id 没有命中，说明它引用的是被混淆过的内部名字。

**要自己造一份**只需：复制这个 160 B 模板，把 `+0x8c` 的 u64 改成
`resource_hash("mods/hivelord/solid")`，再按同样的头部格式生成一个
`mods/hivelord/solid` 贴图（两个资源：texture + material）。

**为什么这一版先不做**：我无法离线验证它到底渲染不渲染。在一个"读数本身还没
实机确认"的版本上再叠一个"未经验证的渲染资源"，只会让失败模式更难分辨。
所以这一版 HUD 用**文字进度条**（游戏自带调试字体，无需任何额外资源，一定能显示），
实心条留到读数确认之后。

## 11. 三件套的验证总账

| | 检查项 | 变异测试 |
|---|---|---|
| Reader（HUD 关 / 开） | **103 / 108 全过** | 29 / 29 被抓 |
| 诊断 probe | 21 全过 | 5 / 5 被抓 |
| 兜底 MemScan | 26 全过 | 9 / 9 被抓 |
| **合计** | **258 项** | **43 / 43** |
| 静态检查自检 | 4/4 可证伪 | — |
| 加载器发现逻辑自检 | 4/4 可证伪 | — |

本轮额外抓出的 bug：

11. **当前血量字段只从"现在还是 150000"的字段里找** → 挨打过的字段已经不是
    150000，于是 `cur_idx` 永远是 nil。必须查"曾经是 150000"的历史。
12. 假引擎只有**一个 world** → `ensure_gui` 要在非任务 world 上建表面，
    于是 HUD 那条路根本走不到，"HUD 未开启时不得绘制"这个断言是**空转**的。
13. SCOREBOARD 只在扫完 32766 个 id 后才写 → 每帧 2 个要 4 分钟以上，
    "已经落盘"的保险形同虚设。改成每 15 秒写一次。
14. 变异测试本身的两个坑：`--mutate` 分支**只跑了主套件**（没跑保险套件和
    纯函数套件），所以新加的变异全部"逃逸"；以及**冗余的双重 clamp**
    让"去掉一端 clamp"的变异被另一端挡住——变异必须表达真正的 bug
    （两端都不 clamp），否则测的是假东西。

## 12. 打包 / 部署 / 发现：端到端已验证

**部署的字节 = 我构建的字节。** 用户装好并 Deploy 之后，游戏目录里的
`data/9ba626afa44a3aa3.patch_3` 是 27520 字节，与
`dist/HiveLord-HP-Reader-1.0.0.zip` 内 `Addon/9ba626afa44a3aa3.patch_0` **逐字节相同**：

```
sha256 deployed = FE868A40B3B468623DB20E2AE0BB98892A12337AD98CB01AF3CBE1EA9C5CEA76
sha256 built    = FE868A40B3B468623DB20E2AE0BB98892A12337AD98CB01AF3CBE1EA9C5CEA76
```

**而且加载器一定会发现它。** `tests/loader_accept.py` 把
`BingusSharedLoader/src/discover.lua` 的规则**逐条照搬**（含几个容易写错的细节：
`offset64` 在高 32 位 > 2²¹ 时必须放弃，因为 Lua 数字是 double；未被标记的
覆盖会隐藏同 key 的旧声明；patch 号大的赢），对**真实已部署的补丁**跑一遍：

```
9ba626afa44a3aa3.patch_4: rejected ['row 0: no valid declaration']   ← 加载器自己，符合预期
discovered mods/hd2/maxigun_amr          (patch_0)
discovered mods/hd2/maxigun_amr_data     (patch_1)
discovered mods/hd2/maxigun_amr_patch    (patch_2)
discovered mods/hivelord/hivelord_hp     (patch_3)
```

三个包（probe / memscan / hp）都通过同一套规则。这条检查现在**接进了构建**：
只要加载器不认，构建就失败——"打出来但根本不会被加载"是这里最贵的失败模式。

自检（4/4）证明这个检查**能失败**：改坏声明、让声明的哈希与 key 不符、
改坏 magic，三种都被拒绝。

## 13. 静默失败路径已封堵

之前三件套的**环境闸门都写在日志初始化之前**：loader 版本太旧、或
`stingray.GameSession` 在加载时还不可用，addon 会直接 `return`，
**一个字节都不写**。用户看到的是"什么都没发生"，而真正的原因永远不会
出现在任何文件里——对一个一次性资源来说这是最糟的失败模式。

现在三件套都是：**先建日志 → 再判环境闸门**，每条拒绝都写进
`*_STATUS.txt` 与 `*.log`（`REFUSED - <原因>`），并带上 loader 的
api / version。新增的 env 测试套件逐个验证：

| 场景 | 期望 |
|---|---|
| 没有 `stingray` 全局 | STATUS + log 都写 `no stingray global`，`installed=false` |
| `stingray.GameSession` 缺席 | 写 `GameSession is unavailable`，`installed=false` |
| loader API = 0（v14 的情况） | 写 `API is 0, need >= 1`，`installed=false` |
| 没有可链的全局 `update` | 写 `no global update`，`installed=false` |
| MemScan 没有 `ffi` | 写 `ffi builtin is unavailable`，且**不启动扫描** |

## 14. 第一次实机运行的结论（2026-09-22）

加载器日志：`mods/hivelord/hivelord_hp: loaded` ✓ —— **mod 确实被加载并运行了**，
`game_object_exists` 也真的工作（普查到 169 / 168 / 172 / 174 个活动对象）。
但**一个候选都没找到**：`top candidate none; 0 array(s) dumped`。

从 `hivelord_hp.log`（134 行）读出两个致命问题：

### 14.1 引擎句柄每次调用都是新包装 → 状态每帧被清空

```
SESSION_CHANGE session=[GameSession] peer=e5767462040a0ff9 world=[World]
SWEEP start max_id=32766
SESSION_CHANGE session=[GameSession] peer=e5767462040a0ff9 world=[World]
SWEEP start max_id=32766
...（重复 100+ 次）
```

`session`/`peer` 的内容完全没变，但 `SESSION_CHANGE` **每帧都触发**。
原因：`Net.game_session()` / `App.main_world()` **每次调用返回一个新的包装对象**，
所以 `session ~= M.session` 恒为真 → 重置逻辑（清空普查、把 `probe_id` 归零）
**每帧执行一次** → 扫描永远从 id 1 重来。`hivelord_hp_state.txt` 里的
`probe_cursor=903` 就是它跑到过的最远处。

DRIVER HUD 用的是同一套 `session~=M.session or peer~=M.peer or world~=M.world`
比较——它能"看起来正常"是因为坦克 HUD 每帧重新绑定一次也无所谓，
而一个 32766 个 id 的慢扫描被每帧重置就完全失效了。

**修法**：比较句柄的**渲染值**而不是身份 ——
`local key = tostring(session) .. '|' .. tostring(peer)`。
`tostring` 渲染的是句柄的内容（`[GameSession]`、`[World]`），是稳定的；
真正的 peer 变化仍然会带来不同的 key。地图切换改用
`GS.in_session` 的 false→true 跳变来检测（`MISSION_ENTER`）。

### 14.2 game object id 是稀疏的，线性遍历根本走不到

普查在同一个世界里看到过 **4096** 和 **8192** 这两个 id。
而探测是"从 1 逐个往上走、每帧 2 个"，32766 个 id 要 **16383 帧（约 4.5 分钟）**，
而且绝大多数 id 根本不存在。第一次实机里它只走到 903，**一个存在的对象都没探到**，
所以连一行 `SCAN` 都没有。

**修法**：普查本来就知道哪些 id 真的存在——探测改为**只走普查名单**
（约 170 个对象，2 秒内走完）。另外普查结果改为**累加合并**，
避免"任务结束后世界只剩 2 个对象"的那次普查把任务里看到的 174 个 id 覆盖掉。

### 14.3 顺带收紧的两处保险

* 扫描门槛从"至少两种已知上限值"（`distinct >= 2`）放宽到
  **"至少一种"**（`distinct >= 1`）。只含 `150000` 的数组正是 sparse 霸王虫的形状，
  原来的门槛会把它**静默丢掉**。
* 前 20 个对象无条件写一行 `SAMPLE goid=.. fields=.. distinct=..`。
  上一次运行连 `SCAN` 都没有，导致"`field_batched` 到底能不能用"这个问题
  在日志里**无法回答**——现在有原始字段数就能回答。
* 普查名单同时写进日志（`CENSUS_IDS n=.. sample=[..]`），
  这样只发一个日志文件也够用。

### 14.4 这一轮新增的夹具（都对应真实故障）

| 夹具 | 复现的真实情况 |
|---|---|
| 引擎句柄每次调用返回新包装（带 `__tostring`） | 14.1 的每帧重置 |
| 霸王虫放在 id **8192** | 14.2 的稀疏 id |
| 数组**只含**两个 150000 | 14.3 的门槛过窄 |
| `in_session` 可切换 | 地图切换检测 |

对应的三个变异（`identity-session-compare`、`walk-id-space`、
`two-kinds-threshold`）全部被抓。**这轮的教训是：夹具的形态必须来自真实观测，
而不是我猜的形态**——之前三个夹具都"通过"了，是因为它们都长得像我假设的世界。

## 15. 第二次实机运行：一个**有歧义**的结果（必须消除）

同一天稍后 mod 继续运行，普查与状态文件刷新到：

```
hivelord_hp_census.txt   2696 B
hivelord_hp_state.txt    probe_cursor=32766      <- 整个 id 空间走完了
hivelord_hp.log          SCOREBOARD sweep_exhausted candidates=0
hivelord_hp_STATUS.txt   722 行，其中 687 行 "top candidate none; 0 array(s) dumped"
```

即：**扫描确实跑完了 380 个真实对象，却一个候选都没有**——没有任何对象含有
两种以上我已知的血量数值（150000 / 35000 / 15000 / 10000 / 5000 / 20000 /
8000 / 800 / 2500）。

id 分布很有信息量：

```
171..435（连续块） · 471 473 662 · 810..862 · 891..908 · 1025..1040 ·
1171..1190 · 1215 1233 1310 1329..1363 · 1375..1501 ·
4096..4196 · 8192..8332 · 12288..12333
```

**歧义在于**：`candidates=0` 有两种可能，而修法完全相反——

1. `game_object_field_batched` 对这些对象**根本返回空**。已知 DRIVER HUD 读的全是
   `objects_owned_by(session, peer)` 里的**本地拥有**对象（自己的载具）；
   如果这个接口只对本地拥有的对象有效，那么扫遍全场也没用。
2. 接口能用，只是这些对象的字段里没有我猜的那几个数值。

上一次的日志**无法分辨**这两者，因为旧版 `SCAN` 的门槛是 `distinct >= 2`，
而且没有记录原始字段数。

### 15.1 1.0.3 让这个问题必然有答案

新增一次性诊断块（全部是 DRIVER HUD 证明过的调用）：

```
DIAG object_info(rHVbvgIu).fields=27     <- 实体接口是否存活（该类型已知 27 字段）
DIAG owned n=.. ids=[..]
DIAG owned_probe goid=.. fields=..       <- 对"本地拥有"的对象读，能否读到字段
DIAG owned_field_reads ok=.. empty=..    <- 决定性数据
DIAG fields_hist empty=.. f1_8=.. f9_20=.. f21_40=.. f41plus=.. any_magic=..
CENSUS_FIELDS objects=.. with_fields=.. max_fields=..
```

`hivelord_hp_census.txt` 也加了列：`id / fields / distinct_magic / magic_counts`。

### 15.2 顺带发现并修掉的两个"日志盲区"

* **诊断块被 `return` 跳过**：找到目标时的 `return` 会跳过函数尾部的诊断——
  也就是**恰好在该跑的时候不跑**。改成 `break`，尾部照常执行。
* **诊断触发条件错了**：原来只在"探测队列走完"时触发，但找到目标会提前 `break`，
  队列永远不会"走完" → 诊断永不触发。改成"已探测 ≥ 8 个对象"就触发。

两者是同一个教训：**给证据加触发条件时，必须问一句"成功的那条路径会不会绕过它"**。

### 15.3 变异测试本身又暴露同一个洞

新加的两个变异（`no-owned-probe`、`census-without-field-counts`）第一次全部"逃逸"，
原因和上一轮一模一样：**`--mutate` 分支没有把新套件接进去**。
变异测试的价值完全取决于"变异会跑全套断言"，而这是个反复踩的坑——
它现在有 17 个变异，每次加套件都必须同步接进 `--mutate` 分支。

## 16. 第三次运行（仍是旧版在跑）：两个新结论

同一个旧版进程继续跑了很久，把日志与状态文件推到了新规模：

```
hivelord_hp.log        39893 B / 11140 行
hivelord_hp_STATUS.txt 760221 B        <- 76 万字节，这是个缺陷
hivelord_hp_census.txt 2850 B / 509 个 id
```

日志里 `SCOREBOARD sweep_exhausted candidates=0` 出现 **10901 次**，
`SWEEP start` 97 次，`SESSION_CHANGE` 56 次，**`SCAN` 一次都没有**。

### 16.1 又一个我自己造出来的缺陷：STATUS 无界增长

`status()` 把每一行都追加进一个表，然后**每次都把整张表重写一遍**——
O(n²) 的写入，而且把"状态文件"变成了第二个日志。760 KB 里真正有用的只有一行。
这不只是浪费：用户打开这个文件会看到 687 行重复的
"no strong Hive Lord match yet"，**结论被彻底埋掉**。

修法：STATUS 现在由**一行可替换的 `CONCLUSION:`** 加**最多 24 条去重后的备注**
组成。离线测试直接驱动 2000 条备注，断言文件仍 < 8 KB、最新的保留、最旧的被丢弃。
另外日志超过 2 MB 会自动截断。

### 16.2 空转：10901 次完整扫描里几乎全是重复

旧版每 20 秒就重扫一次 32766 个 id，一晚上一万次，几乎每次都在重新发现同一批对象。
现在：重扫间隔 120 秒起，**一次普查没有发现新 id 就把间隔翻倍**（最多 16 倍），
发现新 id 立刻恢复。

### 16.3 仍未被回答的那个问题

`SCAN` 一次都没有，但旧版 `SCAN` 的门槛是 `distinct >= 2`，所以**仍然无法区分**
"接口返回空"和"返回了但只有一个/零个已知数值"。这正是 §15.1 的诊断块要回答的，
而它只在 1.0.3+ 里存在。**下一次上机是这条歧义的终结。**

### 16.4 一个结构性线索

509 个 id 的分布是分块的：

```
171..1501 · 4096..4196 · 8192..8332 · 12288..12333
```

块间距恰好 4096，即 `id >> 12` 取值为 0 / 1 / 2 / 3。
所以 goid 的高位很可能编码了**对象类别**。现在普查会把
`CENSUS_BUCKETS id>>12 counts=[...]` 写进日志，
下次就能直接看出霸王虫落在哪个类别里，而不是靠猜。

## 17. ★ 从游戏自己的 Lua 里挖出了引擎实体 API

`work/gamelua/` 里是**游戏自己的 Lua 资源**（LuaJIT 字节码，外面套一层
8 字节资源信封）。它们和 addon 跑在**同一个 Lua VM** 里，所以它们引用的
全局/命名空间，addon 也能用。

用 `work/ljparse.py`（严格的 LuaJIT 2.1 读取器）反汇编
`core/entities/vector_fields/global_direction/global_direction.lua.main`
（游戏自己的"实体矢量场"脚本，它本来就要遍历实体、读组件数据），
拿到的命名空间读取顺序是：

```lua
local World              = stingray.World
local EntityManager      = stingray.EntityManager
local DataComponent      = stingray.DataComponent
local TransformComponent = stingray.TransformComponent
local Quaternion         = stingray.Quaternion
local VectorField        = stingray.VectorField
local LineObject         = stingray.LineObject
local Color              = stingray.Color
local Vector3            = stingray.Vector3
local Vector3Box         = stingray.Vector3Box
local Script             = stingray.Script
```

调用形状（从字节码窗口读出，`TGETS ... 'instances_with_tag_in_entity'` 前后）：

```lua
stingray.components.<组件名> = { entity_data = {...}, world_created = ..., ... }
local list = <组件>:instances_with_tag_in_entity(a, b)   -- 返回实例列表
for i = 1, #list do
    local v = <组件>:get_property(list[i], 'duration')   -- 按名字读属性
end
```

也就是说 Lua 侧存在 **`stingray.EntityManager`** 与 **`stingray.components`
（组件注册表）**，以及一个按 tag 查询实体实例的入口 —— 这正是我一直在找、
而 `objects_owned_by` 给不了的能力。

### 17.1 先把它变成"零风险"的侦察

这些表到底有什么，只能在真机的 Lua VM 里看。但**列出表的键是纯 `pairs()`
遍历，一次引擎调用都不发，不可能出错**。所以 Reader 现在在**加载时**就把
这些命名空间的键写进日志：

```
NS stingray keys=N [...]
NS stingray.EntityManager keys=N [...]
NS stingray.components keys=N [...]
NS stingray.DataComponent / TransformComponent / Script / Unit / World ...
```

这是**每一局都值得拿**的一份侦察，而且不需要扫描、不需要任务、不需要霸王虫
出现 —— 只要 mod 被加载就会写。

### 17.2 顺带修掉的两个"哑巴"缺陷

* **`M.cand_list` 不存在**：这是从旧的 probe 里带过来的残留字段名，恰好只在
  **"探测队列走完"那一刻**求值。它抛的错会把 mod 的全局 `failed` 置位，
  **整个 mod 从此彻底静默** —— 也就是在最有意思的那一刻死掉，而且日志里
  什么都不会说。修掉，并加了两条断言：**日志里绝不允许出现 `LUA_ERROR`**，
  以及**注入故障必须被记录**（为此加了一个只在测试时生效的故障注入缝）。
* **STATUS 的写入会先截断**：实机抓到一个 0 字节的 `STATUS.txt` ——
  正好采在"截断之后、写完之前"的窗口里。现在改成先写 `.new` 再 `remove`+`rename`，
  最坏情况只留下一个 `.new`，而不是空文件。

### 17.3 又一次证明了"日志洪水来自我自己"

日志涨到 456 KB / 22438 行，其中 **22438 行是同一条
`SCOREBOARD sweep_exhausted candidates=0`** —— 因为 `drained` 一旦为真就永远为真，
而它被写进了每帧的判断条件。现在只在"探测队列刚走完"记一次
（`PROBE_DRAINED`），加上**候选集变大时立刻记一次** + 定时记录。
后者很重要：**最好的候选往往是最后才发现的**，只靠定时器可能永远来不及报。

## 18. ★★ 第四次运行：一次拿到三个决定性结论

用户这次**两个包都装了**（`patch_3` = memscan，`patch_4` = reader），
加载器日志确认两个都 `loaded`。

### 18.1 实体 Lua 接口是活的，而且字段读**能用**

```
DIAG object_info(rHVbvgIu).fields=27
DIAG owned n=163 ids=[...]
DIAG owned_probe goid=0 fields=36 ...
DIAG owned_field_reads ok=5 empty=0
```

* `object_info('rHVbvgIu').fields = 27` —— **和 DRIVER HUD 记录的 27 个字段完全一致**，
  说明实体 Lua 接口在这个构建里完好。
* **`game_object_field_batched` 确实能读到东西**：`owned_probe` 导出的真实数组
  有 3 / 15 / 19 / 22 / 26 / 36 个字段，里面是 `Vector3(-110, 450, -160)` 这样的
  坐标、布尔标志、32 位哈希，甚至**同 peer id 字符串 `e5767462040a0ff9`**
  （和日志里的 peer 一致）。这推翻了我上一轮的猜测"接口对非自有对象不返回数据"。
* 但是：**没有任何对象的字段数组里出现我已知的血量数值**（`census any_magic=0`）。
  注意这条上一轮是**early 采样**得出的（只看过 8 个对象就下了结论并冻结），
  本轮已经修好采样门槛（见 18.4）。

### 18.2 ★ MemScan 找到了霸王虫的血量结构，并**三方验证**了离线解析

```
scanned 9858 readable regions, 6548 MiB address space
match at 0x22c67de49f6: health=150000 zones=38 magic=38
scan complete: 6598 MiB read, 1 structures found
```

* `health=150000` —— 与 wiki 和离线解析一致（main = 150,000）。
* `zones=38`、`magic=38` —— **38 个部位全部落在已知数值集合里**，
  正是离线解析出的 `9×150000 + 12×15000 + 1×20000 + 2×10000 + 14×5000 = 38`。
* 全内存 6.5 GiB 扫完**只找到 1 个**结构 → **零误报**。

**最关键的一步是对地址做算术**（离线完成）：

```
match address        : 0x22c67de49f6
离线文件内偏移        : 0x007F49F6      (LDLD 记录 27，Health 在 +0x00)
相减得到的映射基址    : 0x22c675f0000   ← 64 KiB 对齐 ✓
```

**所以这个命中就是"内存映射的明文数据表"本身**，而且 `Health` 恰好落在
离线预测的文件偏移上。这是三方交叉验证：离线解析 → 签名扫描 → 地址对齐。

### 18.3 由此得到的**负面结论**（同样重要）

只找到 1 个结构 = **内存里没有第二份"每个实体的 HealthComponent 副本"**
（至少在那个时刻没有）。也就是说：

* **血量上限/各部位上限**：在映射数据表里，**离线就已经知道**，不需要运行时读；
* **实时当前血量**：**不是** HealthComponent 的副本，所以"盯着蓝图看它变"是
  **永远不会变**的 —— 第一次 MemScan 的 watch 数据没写下来（日志 0 字节），
  但结构上它盯的就是数据文件。

这也解释了为什么"按部位上限指纹找实体"这条路只能验证布局，不能给出实时血量。
下一步要么找到**实时血量的真实存储**，要么回到字段数组（但需要先确认字段数组里
到底有没有血量 —— 见 18.4 修好的采样门槛）。

### 18.4 两个必须修掉的"我自己造的"问题

**① 结论下得太早然后被冻结。** 旧门槛是"探测 ≥ 8 个对象就跑诊断"，于是
`VERDICT` 在只看了 163 个对象里的 8 个时就写下了
"no census object held a known health value"，并且 `diag_done` 让它再也不更新。
**这是最危险的一类错误：一个基于 5% 样本的结论，会被下一轮当成事实。**
现在要求**走完队列的 80%**（且 ≥24 个）才出结论，并且随着样本增长**重新评估**。

**② 日志 0 字节。** 两个包的日志都是 0 字节，而 STATUS 正常——因为旧实现用
**常驻句柄 + flush**：`pcall(function() out:write(...); out:flush() end)` 一旦失败
就把 `out` 置 nil，**缓冲区里那行就永远丢了**，而且没有任何地方说这件事。
现在改成**逐行 open/append/close**（不可能丢），并且把**日志自己的健康度写进
STATUS**：`log: <路径> lines=N failed=M`。日志静默失败从此不可能被忽略。

**③ MemScan 只扫一遍。** 霸王虫通常在扫描开始很久之后才出现，一遍扫完就
"never again"等于永远看不到实体。现在**每 120 秒重扫一遍**，并且把命中
**分类**为 `BLUEPRINT`（地址减去已知文件偏移后 64 KiB 对齐）或 `OTHER`，
WATCH 行也带类别 —— 这样"只有蓝图"和"找到了实体"在一行里就能区分。

## 19. ★★ 第五次运行：上一轮那个"结论"被自己的数据推翻了

同一次 session 继续跑下去，出现了**决定性的一条**：

```
no strong Hive Lord match yet; probed 2304; top candidate goid=714 fields=46 [150000x1]; 1 array(s) dumped
```

并且导出了 `hivelord_hp_weak1_goid714.txt`：

```
# goid=714 fields=46 distinct_magic=1 [150000x1]
16	number	699050        (= 0xAAAAA)
17	number	150000        ← ★
...
33	table	<table 2> 711 713     ← 引用邻近对象
44	number	16383  (0x3FFF)   45	number	255  (0xFF)
```

**所以"没有任何对象的字段数组里有已知血量数值"这个结论是错的。**
它是**在 163 个对象里只看过 8 个**时写下的（§18.4 ①）。同一个 session 后来
（探到第 2304 个）就找到了 `field 17 = 150000`。这正是我上一轮修的那个
"5% 样本下结论" 的坑 —— 而**它在本轮就现了原形**：证据来自同一局游戏。

另外 `goid=20548 fields=82 [10000x1,2500x1]` 也说明**确实有对象的字段数组
带血量类数值**（10000 是霸王虫下颚的血量）。

### 19.1 但 714 从来没被"看"过

`read_once`/`report` 只在**强判定命中**后才运行，所以 714 虽然被找到、被导出，
却**从来没有被观察过**。于是唯一还缺的那件事——**受伤时哪个字段在动**——
明明对象就在眼前，却没有拿到。这是纯粹的浪费，也是本轮修的东西。

### 19.2 1.0.8：让"弱候选"也能被观察，并追踪**所有**数值字段

* **弱候选成为观察目标**：只要字段里出现过 `150000`，就按
  （150000 个数 × 1000 + 字段数）挑最好的那个作为 `watch_goid` ——
  **不再依赖强判定**。
* **追踪每一个数值字段**（上限 512 个），而不是只追踪 `150000` 的那几个。
  每秒记一行：

  ```
  WATCH_FIELDS goid=32 strong=false fields=40 changed=1 [6:150000->145000(-5000)]
  ```

  这一行**直接点名"当前血量"是哪个字段** —— 这是整个 reader 唯一还缺的事实。
* 有字段在动时，STATUS 的结论行写成
  `WEAK WATCH goid=...: N field(s) changed since first seen: ...`；
  没有字段动时写成"正在观察，还没有字段变化 —— 去打它"。

离线夹具验证（`test_hp.py --hud` 里的一条专门套件）：造一个**永远不会触发
强判定**的世界，确认弱候选被设为观察目标、被持续观察、并且在"受伤"后
**准确报出是第 6 个字段从 150000 掉到 145000**。

### 19.3 census 文件只是快照

上一次 `hivelord_hp_census.txt` 里 984 行中有 **874 行是 `-1`（没探到）** ——
因为 `land_census` 只在诊断触发时写一次。所以"census 里没有"不等于"存在里没有"。
现在 census 在诊断门槛（走完队列 80%）时才写，覆盖率高得多。

### 19.4 一个测试保真度的坑（又一次）

`no-scoreboard` 这个变异突然"逃逸"了。查下去：我的断言是
`'SCOREBOARD' in log`，而**结论文本里就有 "see SCOREBOARD" 这个词** ——
于是把 scoreboard 整个删掉，断言依然为真。改成按**行首**匹配
（`l.startswith('SCOREBOARD ')`）才恢复有效。
**断言必须匹配"那个东西本身"，而不是恰好也包含它的任意文本。**

## 20. 第六次运行：又是三个"我自己造的"问题（其中一个让兜底彻底失效）

### 20.1 ★ MemScan 的断点游标让"下一局"什么都不扫

```
LOG_OPEN path=...hivelord_mem.log
START memscan-v1 frame=601
REGIONS count=9903 total=6573 MiB
SCAN_RESUME region_index=9858 of 9903      ← 从"上一局扫完的位置"继续
SCAN_DONE pass=1 regions=9903 bytes=0 MiB matches=0 blueprint=0 live_like=0
```

游标是**为了崩溃后续扫**而存在的；但上一局**正常扫完**后它停在末尾 9903，
于是这一局从 9858 开始，只扫了最后 45 个内存区、**读了 0 MiB、什么都没找到**，
连上一局那个命中都没被重新验证，watch 也无事可做。
**一个"恢复"机制把正常路径整个吃掉了。**

修法：扫描完成时把游标**重置为 1**（崩溃中途仍然能正确续扫）。

### 20.2 Reader 的"拥有对象"闸门白费了一整局

这一局的日志：`MISSION_ENTER` 出现 **3 次**，但 `census: 0 ids`、`probed 0`。
原因是旧逻辑在 `objects_owned_by` 为空时**直接 return** —— 而这一局从头到尾
`owned=0`，于是普查一次都没跑，整局什么都没学到。

`objects_owned_by` 现在是**线索而不是闸门**：普查本身（便宜的
`game_object_exists` 调用）才是"当前有没有实体世界"的诚实判据，
而普查找不到对象时下游自然什么都不做。

### 20.3 `LOG_OPEN path=%s` —— 格式符没被展开

日志第一行是字面的 `LOG_OPEN path=%s`：我写成了 `w('LOG_OPEN path=%s', ...)`
而不是 `wf(...)`，`w` 只接受一个参数，于是**日志路径从来没被记下来**。
（这也是为什么上一轮只能靠 STATUS 里的 `log:` 行判断日志健康度。）
**一个"记录诊断信息"的调用自己坏了，而且坏得看不出来。**

### 20.4 MemScan 再次确认"只有蓝图"

同一次运行里 1.0.1 的第一趟也被同一个游标问题毁掉了，但上一局的数据仍然有效：
`MATCH addr=0x22c67de49f6 ... zones_magic=38`，以及
`WATCH n=1 0x22c67de49f6=150000` 一直不变 —— 与 §18.3 的结论一致：
**那是映射的数据表（蓝图），不是实体副本。**

### 20.5 测试保真度：`premature-verdict` 一度"逃逸"

我把诊断改到帧循环里并按 `probes/128` 做粗签名之后，"样本太小就下结论"
这个变异不再被抓 —— 因为后续会重新评估并覆盖它。为了让这个性质重新可测，
断言从"**最后一个** census 覆盖率够"改成"**每一个** census 覆盖率都够"，
并顺手删掉了普查刚结束、还没探测时那次**全是 -1** 的写盘
（它只是把真正有用的快照挤掉）。改完后变异又被抓住。

**一个断言只覆盖"最后状态"时，会放过"过程曾经是错的"。**

## 21. 第七次运行：把"没有霸王虫"和"读不到"分开了

### 21.1 MemScan 连续 4 趟完整扫描：0 个"活体"

**1.0.2 的游标修复生效了** —— 第 2/3/4 趟都真正扫了全量：

```
pass 1 complete: 0 MiB read, 0 structure(s)          ← 旧游标的残留（1.0.1）
match BLUEPRINT at 0x2146b5c49f6: health=150000 zones=38 magic=38
pass 2 complete: 6590 MiB read, 1 structure(s) (1 blueprint, 0 live-like)
pass 3 complete: 6588 MiB read, 1 structure(s) (1 blueprint, 0 live-like)
pass 4 complete: 6586 MiB read, 1 structure(s) (1 blueprint, 0 live-like)
```

**四趟共读约 26 GB 内存，每一趟都只找到同一个结构，而且都被判定为
`BLUEPRINT`（地址减去已知文件偏移后 64 KiB 对齐），`live-like` 恒为 0。**

这是一个**可重复的否定结论**：内存里**没有**第二份"每实体血量副本"。
所以"盯着 HealthComponent 看它变"这条路是死的 —— 这与 §18.3 的推断一致，
但现在有 4 趟独立扫描作为证据，而不是 1 趟。

`0x2146b5c49f6 − 0x7F49F6 = 0x2146ADD0000`，同样 64 KiB 对齐 —— 换了 session
（ASLR 不同）后依然吻合，也就是**离线解析在每个 session 都成立**。

### 21.2 Reader：上一次的结论其实是"这局没有霸王虫"

1.0.7（当时部署的版本）给出的结论是：

```
VERDICT: field reads work and 5 object(s) held a known health value -- see SCOREBOARD
DIAG: API fields=27, owned=46 (0 read ok), census any_magic=5
```

看起来像"读到了"，但 census 里那 5 个对象**全是 `800x1`** ——
`800` 是我加进 MAGIC 集合的一个普通数值。**"有对象含有已知血量数值"这句话
被一个无关的 800 满足了**，于是"这局没有霸王虫"和"霸王虫的血量不在字段数组里"
这两种完全相反的情况被混为一句。

这正是 1.0.10 修的：新增 `DIAG objects_with_150000=N`，结论分三种 ——

| 情况 | 结论 |
|---|---|
| 有对象带 150000 | `field reads work and N object(s) held 150000 -- see WATCH_FIELDS/SCOREBOARD` |
| 有已知数值但没有 150000 | `none held 150000 -- no Hive Lord was present in this mission` |
| 什么都没有 | `no census object held a known health value -- most likely no Hive Lord was present` |

### 21.3 现在缺的是一件很具体的事

到这一刻，所有工具问题都清了，剩下的**唯一**未知是：
**霸王虫在场并且正在掉血时，哪个字段在动。**

而上一次运行**没有霸王虫在场**（census 里没有任何 150000）。所以需要的不是
更多代码，而是一次**霸王虫真的在场**的采集：装 1.0.10，进巢都星球 Suicide+，
等霸王虫出现并**持续打它**，`WATCH_FIELDS` 会直接写出 `index:first->now`，
`STATUS` 的结论行也会给出同一句话。

### 21.4 这一轮的方法论收获

`VERDICT` 这类"一句话结论"必须**对区分度负责**：它把一组条件压成一句话，
只要其中任一条件可以被无关数据满足（800 也是"已知数值"），
结论就会把两种相反的情况说成同一种，而**读的人无从察觉**。
所以每条结论都要能回答："这句话为真，能不能由我关心的东西之外的东西造成？"

---

## 22. ★★ 第八次运行：网络字段路线被自己的数据判了死刑，同时找到了正确的内存签名

这一轮做完了两件必须一起看的事：**把主路线证伪**，以及**把兜底路线的根本缺陷修掉**。

### 22.1 先拿到的东西（都是实测，不是推断）

这一局有霸王虫在场。对象身份由**死亡事件**本身确认，不再依赖猜测：

* 全场 1472 个对象里**只有 1 个**带 `150000`（本局 `goid=624`；上一局 `goid=714`）；
* 它身上有一个 **6 bit 量化比例**字段：取值精确等于 float32 的 `k/63`，
  `k ∈ 0..63`。整局观测到的 27 个不同取值**全部**是 `k/63`，
  没有一个是别的数 —— 6 bit 网络同步的特征。
* 这个字段出现**连续 104 秒的单调下降**（62/63 → 24/63，即 147619 → 57143），
  中途一次回升都没有。看起来就是掉血。
* 它还有一个**单调下降、全程从不回升**的部位损伤位掩码：
  `16383 (0x3FFF) → 16243 → 16227 → 16167 → 15655 → 15623 → 7431 → 5383`。
  `16383 = 2^14−1`，而离线解析里霸王虫恰好有 **14 片鳍**
  （`boss_l/r_leg` + `spine0..5_l/r_leg`）。
* **对象在霸王虫死亡的同一刻消失**：日志最后一行是 `LOST goid=624`，
  该行之前没有任何 `MISSION_ENTER` / `SESSION_CHANGE`，所以不是任务切换。

### 22.2 一个自己造的陷阱：差点把 6 bit 比例当成总血量

那个比例字段整局出现 **8 次"回满到 63/63"**，而且和损伤位掩码**同时**存在：
掩码已经掉到 16167（掉了 4 片鳍）时，比例字段仍然读到 63/63。更关键的是：

**对象被销毁时，那个比例字段读数是 61/63（97%）。**

一个满血上限 150000 的 Boss 不可能在 97% 血量时死亡。所以那个比例字段
**不是总血量**，它只是"当前被打部位"的比例（它会在不同部位之间快速切换：
日志里有 0.06 秒内 58 → 63 的跳变，那不可能是回血，只能是换了部位）。

**判据：一个字段要想当总血量，它必须在对象死亡的那一刻归零。** 这一局
**46 个网络字段里没有任何一个满足这条**。所以：

> **客户端网络层根本没有同步霸王虫的总血量。** 只同步了部位比例和一个损伤掩码。
> "从网络字段读总血量"这条路是**结构性**走不通的，不是没找对字段。

这条负面结论的价值在于：它把剩下所有工作从"再试几个字段"变成了"只能读内存"。

### 22.3 兜底路线为什么一直只找到蓝图 —— 根本缺陷

MemScan 1.0.x 的签名是**数值** `150000`（int32 + 紧随的 float 0.0）。
4~8 遍全盘扫描（26~50 GB）永远只找到内存映射的数据表副本，这不是运气问题：

**霸王虫一掉血，活体实例里的 `Health` 就不再是 150000，这个签名按构造
不可能命中活体。** 之前那次唯一的 live-like 命中
（`health=150000 zones=3 magic=0`）之所以是 150000，正是因为它是**刚生成、
还没挨打**的瞬间；随后就 `MATCH_STALE` 了。

1.1.0 改成找**不随伤害变化的结构常量**（记录 +0x28 起 12 字节）：

```
03 00 00 00 | 00 60 EA 46 | D0 07 00 00
Size == 3 (UnitSize_Massive) | Mass == 30000.0f | KillScore == 2000
```

用游戏自己的数据表验证（`work/hivelord/sig_specificity.py`，
`tests/test_signature.py`）：

| 结论 | 数字 |
|---|---|
| 12 字节模式在整个 45,630,790 字节文件里出现次数 | **1**（位置 `0x7F4A1E` = record[27]+0x28） |
| `Size==3` 单条约束下的记录数 | 46（**不唯一**，所以三个常量必须同时要求） |
| `Mass==30000.0` 命中的记录 | 只有 [27] |
| `KillScore==2000` 命中的记录 | 只有 [27] |

这条验证被固化成 14 项检查 + 4 个变异自检，**常量与数据表漂移会让测试失败**，
而不是在任务里悄悄读错数字。

### 22.4 顺带修正的一个算错的数

我一开始把区域生命值总和写成 `1,620,000`，测试当场判错。正确值是：

```
9×150000 + 12×15000 + 1×20000 + 2×10000 + 14×5000 = 1,640,000
13 个部位带 35000 Constitution                     =   455,000
加上记录自身的 main Health 150000                   = 1,790,000
```

这三个数现在是活体读数正确性的**运行时断言**：主路径命中后会整块解析 38 个部位，
算出 `zone_health_sum` / `zone_constitution_sum` / `const35000` 并打印；
在数据表副本上还会跟这三个定值比对，不一致就写 `LIVE_LAYOUT_MISMATCH` 并明说
"不要相信活体数值"。**算错的常数差一点就成了运行时断言**——先算错、再被测试抓住，
比先算错、再上线要好得多。

### 22.5 这一轮的方法论收获

1. **排除法要有一个可判定的终点**：判定"某个字段不是总血量"的标准必须是
   "它没有在对象死亡时归零"，而不是"它看起来会回满"。前者可判定，后者是感觉。
2. **一个字段"会随伤害下降"远远不够**：6 bit 比例字段完美通过了这条，却是错的。
   真正的判据是**边界条件**（死亡时必须归零）。
3. **签名不能用会被目标行为改变的量**。用数值当签名，等于假设目标永远处于
   初始状态 —— 这是把"我看到的样本"当成了"目标的定义域"。
   正确的做法是找**不变量**：先证明它在整个数据表里唯一，再让它参与匹配。

---

## 23. ★★★ 第九次运行：客户端为什么**根本不可能**读到完整血量（结构性结论）

这一轮把上一轮留下的"活体实例到底在不在"彻底问死了，答案是否定的，
而且原因不在工具、不在签名、不在运气，**在客户端的组件模型里**。

### 23.1 先看实测：四次全盘 + 一次独立外部扫描，只有数据表

霸王虫在场期间（`goid=624` 已由它死亡时的 `LOST` 确认过身份）：

| 手段 | 范围 | 结果 |
|---|---|---|
| 模组 1.1.0 pass 3 / pass 4 | 6914 / 6894 MiB | `matches=1 blueprint=1 live_like=0` |
| 独立外部扫描器（Win32 `ReadProcessMemory`） | 12.9 GB | 唯一的"部位数组完整"结构就是只读数据表 |
| 1 秒一轮的高频窗口轮询 | 16 MiB 堆窗口 | 见 23.2 —— 全是化石 |

### 23.2 一个必须说清的假象：Lua 堆里的"化石"

高频轮询确实反复抓到 `main=0 / const=13..18 / zone_sum=1640000 / 38 部位完整` 的命中。
但把**同一地址**的原始字节逐次对比后，真相是：

```
同一地址 0x7ed8fe68，两次读取：
  main=150000 const=0   head=f0490200000000000000000000000000 01000000...   <- 与数据表逐字节相同
  main=0      const=15  head=00000000000000000000000000000000 d802c07e...    <- 别的分配
```

`f0 49 02 00 ...` 正是数据表记录的开头。这些命中是**模组自己 `read()` 出来的
组件字符串**（21496 字节的整块读取，以及 512 KiB 的分片读取）在 Lua 堆里的副本；
字符串被回收后**内存不清零**，新的小字符串只覆盖前 ~0x28 字节，
于是 `+0x28` 之后的旧字节（不变量 + 完整部位数组）原封不动地留着 ——
看起来"主血量=0、部位表完好"。

**判据升级**：同一地址出现**两份互相矛盾的内容**时，它不是实体，是复用未清零的内存。
（`main=0` 的那一份里 `+0x18` 读到 13/14/15/18，其实是**新字符串自己的字节**，
不是 Constitution。）

### 23.3 根因：客户端只有一个 4 字节的 `SyncedHealthComponent`

数据表里的 `HealthComponent`（22096 字节 / 记录）是**原型数据**。
用社区 hash 表把 typelib 里被剥掉的名字还原（1177 个类型还原出 1078 个）后，
运行时与血量相关的类型只有：

```
     size  nmem  name
        4     1  SyncedHealthComponent   0xC3C0B58F   <- 客户端唯一的运行时血量
       24     4  WoundableComponent      0x432D1854
     4992    14  DamageZoneShieldComponent 0x868B11A7  (内含 4864 = 38 x 128 的每部位数组)
    22096    51  HealthComponent        0x728F0129   <- 原型，数据表里 493 条
 10909072     2  HealthComponentData    0xB3915DE3
```

**`SyncedHealthComponent` 只有 4 个字节。** 4 个字节装不下 150000，更装不下 38 个部位。
所以：

> 客户端的每实体血量是一个**4 字节同步值**，和网络字段里读到的那个
> **6 bit 量化比例**是同一件事。完整血量（150000、以及 38 个部位当前值）
> **不在客户端进程里**——它是主机侧的权威状态。

这一条把三件事一次性解释了：
1. 为什么 9 个网络字段里没有任何一个在霸王虫死亡时归零；
2. 为什么 MemScan 找遍 26~50 GB 只有原型数据表；
3. 为什么"活体命中"全部是瞬时的、且原始字节与数据表逐字节相同（是副本，不是实体）。

### 23.4 对"血量显示"意味着什么（必须如实告知用户）

* **精确血量在客户端不可得**，这不是实现难度问题，是信息不存在。
  任何声称能显示霸王虫精确血量的客户端 mod，要么改的是主机侧，要么是编的。
* 客户端**确实**拿到的信号有两个，都在 46 个网络字段里，且已经解码：
  * **6 bit 血量比例** `k/63`（float32 精确等于 `k/63`，`k ∈ 0..63`）；
  * **14 位部位损伤掩码**（`16383 = 2^14−1` 起单调下降，与离线解出的 14 片鳍吻合）。
* 因此这个 mod 的**上限**是：如实显示"客户端同步值"，而不是伪造一个精确 HP。

### 23.5 这一轮的方法论收获

1. **"找不到"要分三种，不能混成一句**：签名不对、目标不在场、目标**不存在**。
   前两种靠改工具，第三种只能靠**类型系统**回答。用 typelib 把"存在的类型集合"
   列出来，比再扫 50 GB 内存有效得多 —— **离线一个 900 KB 的文件，
   推翻了 50 GB 扫描的结论**。
2. **同一地址的两次读取如果内容互相矛盾，说明它是复用内存，不是实体。**
   只看一次快照就下结论，会把"未清零的化石"当成"活体"。
3. **先算清"目标需要多少字节"，再看内存里有没有这么多字节的位置。**
   一次减法（4 字节 vs 22096 字节）就能止损，不该等到第 9 次上机。


