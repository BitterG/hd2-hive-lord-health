========================================================
霸王虫精确血量 (Hive Lord Health) 1.9.0
只读 · 直接读游戏的血量管理器 · 构建锁定
========================================================

★ 已实机验证：精确血量，死亡时归零
--------------------------------------------------------
同一次任务的完整弧线（101 次读数，min=0 max=150000）：

```
18:43:25 HP goid=4621 entity=1182 unit=4203513 j=93 hp=150000 max=150000 (table)   ← 生成
18:45:08 HP goid=4621 entity=1182 unit=4203513 j=88 hp=149197 max=150000 (table)
18:50:31 HP goid=4621 entity=1182 unit=4203513 j=88 hp=24408  max=150000 (table)
18:50:35 HP goid=4621 entity=1182 unit=4203513 j=88 hp=0      max=150000 (table)   ← 死亡
```

**"死亡时归零"是它区别于网络同步字段的证据**：那个 6 位字段只会饱和，永远到不了 0。
`goid/entity/unit` 全程不变，只有条目下标 `j` 会浮动 —— 锁定靠实体标识，不是碰巧的下标。

★ 读法（来自已发布的 Enemy HP 1.1.1）
--------------------------------------------------------
```
hm   = *(game + 0x3326688)                ← 每次轮询都重读，绝不缓存
n    = u32 at hm+0x1020
arr  = *(hm+0x1048)     recs = *(hm+0x1058)     记录步长 0x1B8，血量在 +0x14
d    = *(arr + j*8)     描述符 [u64 type][u32 entity][u32 unit][u32 goid][u32 flags]
hp   = i32 at recs + j*0x1B8 + 0x14      ★ 精确当前血量
max  : net = *(game+0x346BF98); t = *(net+0xF12B78)
       key = 描述符的 type；从 t[key % 1002] 起探测，16 字节一槽（u64 键 + u32 索引）
       max = u32 at t + 0x3EA0 + 索引 * 0x5650
```

**「每次重读 hm」不是细节，是这条路的命门。** 船上的管理器和任务里的**不是同一个分配**：
把指针缓存下来，进任务后就一直在读那个已经失效的旧管理器 —— 实机表现为 `entries=1`
卡死十一分钟、永远找不到霸王虫。回归测试用"船上管理器 → 任务管理器"的切换钉住它，
变异 `manager-cached` 会被抓。

★ 绘制：回到"已经被看见过能渲染"的那个调用
--------------------------------------------------------
**这个项目里唯一被确认渲染成功的调用，是第一个 mod（Reader）用的那个**：屏幕上的字
**重叠**过 —— 而只有**看得见**的字才会重叠。

```lua
Gui.text(gui, 文本, 'core/performance_hud/debug', 字号,
         'core/performance_hud/debug', Vector2(x, y), Color(a, g, g, g))
```

后来我把它换成了参考实现的形状（从游戏全局读字体/材质/alpha id、`IdString64.from_hex`、
`Gui.material` + `Material.set_*`、`Vector3` 位置）。**那套不是错的（那个 mod 用它跑得很好），
但它是另一套引擎 API 面**，而这个构建上**被验证过能渲染的只有前者**。四次崩溃全部发生在
换过去之后：

| 我做的 | 参考实现做的 | 结果 |
|---|---|---|
| `read()` 里每次 `ffi.new` | 复用同一个缓冲 | 进任务卡顿 |
| 只传材质 id，不配置 | 建材质对象 + 4 scalar/vector2/vector4/贴图 | 原生崩溃 |
| 世界变化时 `World.destroy_gui` | 从不销毁 | 进任务闪退 |
| 每次变化新建文本对象 | 建一次、`update_text` 原地更新 | 过几分钟崩溃 |

**Reader 之所以从没因为销毁而崩，是因为它那个"句柄身份比较"的 bug 让 `World.destroy_gui`
一次都没真正执行。** 我"修好"那个比较之后，它才开始真的被调用。

1.9.0 的绘制：

* **Reader 的调用形状**：debug 字体字符串 + `Vector2` + 原参数顺序。
* **不碰任何材质 API**（`Gui.material` / `Material.set_*` / `IdString64` 全不用）。
* **不销毁表面**：`World.destroy_gui` 一次都不调用。
* **文本：优先 `update_text` 原地更新**；没有 `update_text` 时用**真实句柄**销毁重建，
  且**每个表面最多 2 个文本对象**。
* **表面总数上限 12**，到顶就自己关闭绘制并写日志 —— 让"累积"在构造上不可能。
* **只有 `Gui.text` 是必需的**；缺了就拒绝绘制并写明原因。

★ 构建锁定：认错构建就拒绝，什么都不读
--------------------------------------------------------
```
game.dll        TimeDateStamp 0x6AB3B43F  SizeOfImage 0x04744000  CheckSum 0x00ECDA6F
helldivers2.exe TimeDateStamp 0x6AB382E4  SizeOfImage 0x039E8000  CheckSum 0x00E48B1D
构建 25480438
```
六项已在实机文件上离线核对（`work/verify_enemyhp_build.py`）。不匹配时写
`REFUSED - unsupported game build: ...`，并且**不读任何结构** —— 用错构建不会报错，
只会从无关结构里读出一个看起来很合理的数字。

★ 日志
--------------------------------------------------------
  hivelord_health_STATUS.txt   第一行是结论：
      CONCLUSION: Hive Lord 0 / 150000 exact (entry 88 of 169)
  hivelord_health.log
      BUILD / ARMED                       构建校验与启用
      MANAGER changed 0x.. -> 0x..        世界切换被发现
      MANAGER not available: ...          并写明是空 / 读不到 / 计数不合理
      NO_ENTRY entries=N max150000=M      管理器里没有霸王虫的键
      HP goid=.. j=.. hp=.. max=..        精确读数
      DIAG / DIAG_DESC                    只在**结构变化**时写；含三个素材 id
      HUD_STATE ...                       绘制走到哪一步，含 `painted=true font=debug-font`
      LUA_ERROR / HUD_ERROR / POLL_ERROR

★ 它**不会**做什么
--------------------------------------------------------
只用 `GetModuleHandleA` / `GetCurrentProcess` / `ReadProcessMemory`。
**没有** `VirtualProtect`、没有 `WriteProcessMemory`、不开别的进程、不碰代码页、
不改游戏数据、不发网络包。

安装
----
  1. 导入 HiveLord-HP-Health-1.9.0.zip，启用 Core。
  2. Purge → Deploy → 启动游戏。
  3. 进有霸王虫的任务；用 ping 键**标记**它。

可选配置 %APPDATA%\Arrowhead\Helldivers2\hivelord_health.cfg
  hud / hud_scale / hud_offset_y / hud_alpha / poll_seconds / diag_seconds /
  by_max_seconds / hold_seconds / surface_cap / start_delay / draw_every

**应急开关**：`hud = false` → 绘制路径完全不执行，**读数照常**。

其它包
----
* `Reader`：走网络字段，**不锁定构建**，给同步值（已证明不是精确血量）。
* `Roster`：走 director 名册判断"在不在"；其 RVA 属于旧构建 24826606，
  在 25480438 上会被构建闸门拒绝。
* 本包：血量管理器，精确值，仅适用于 25480438。三个包互不干扰。
