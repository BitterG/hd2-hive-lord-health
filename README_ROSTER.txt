========================================================
霸王虫名册 + 血量探针 (Hive Lord Roster + HP Probe) 1.1.0
只读 · 进程内 · 精确当前血量
========================================================

★ 1.1.0：现在直接读出**精确的当前血量**
--------------------------------------------------------
参考 mod **Enemy HP 1.1.1**（一个已发布的敌人血量显示 mod）证明了敌人当前血量
**在客户端内存里确实可读**。我把它的归档解出来（是明文 Lua），它的读法是：

```
hm   = *(game + RVA)                      血量管理器
n    = u32 at hm+0x1020                   条目数
arr  = *(hm+0x1048)                       描述符指针数组
recs = *(hm+0x1058)                       记录数组
d    = *(arr + j*8)                       描述符 [u64 type][u32 entity][u32 unit][u32 goid]
hp   = i32 at recs + j*0x1B8 + 0x14       ★ 精确当前血量
max  = 血量表里按描述符的 type 哈希查到的 HealthComponentData 记录 +0x00
```

**这修正了本项目之前一个重要的错误结论。** 我先前写"客户端只有 4 字节同步值"——
那是错的：客户端确实有**精确的每实体当前血量**，只是它**不在** `HealthComponent` 里
（所以按原型字段做的签名按构造永远找不到它），而在这些 `0x1B8` 步长的记录里。
`stride 0x5650` 的血量表，和我们离线逐字节解析的**是同一张表**。

现在 STATUS 第一行是：

```
OK - Hive Lord HP 145238 / 150000 -- exact, from the live health manager
     (global 0x..., entry 3 of 6) [roster 0x660:ok/44 0x668:... ]
```

★ RVA 不写死：从运行中的代码里现场反推
--------------------------------------------------------
RVA 随构建变化，而且**磁盘上的 `game.dll` 代码段是加密的**（实测熵
**7.9998 bits/byte**）—— 从文件里搜不出来；All-Stalker 的字节校验也是**在内存里**做的。

内存里的代码是解密过的，而访问器**必然**要碰 `+0x1048` 和 `+0x1058`。
所以本 mod 扫 `game.dll` 可执行区，找这两个位移，再往回找加载该全局的
`mov reg,[rip+disp32]`，得到候选全局地址，再用**结构校验**确认：

* 条目数必须在 1..2048；
* 三个指针都必须可读；
* 前几个描述符的 type 必须非零。

校验不过就换下一个候选；一个都不过就写 `HEALTH_MANAGER not found`，并且
**不报任何血量**。这样游戏更新时是"找不到"，而不是"报一个自信的错数字"。

反推成功时日志会写出它（`HEALTH_MANAGER global=0x... hm=0x... n=... recs=0x...`），
可以据此固化成常量。

★ 名册：回答"它在不在"（1.0.0 起）
--------------------------------------------------------
```
director = *(game.dll + 0x276CA20)
header   = *(director + 0x660 | 0x668 | 0x670)     三个阵营槽
rows     = *(header + 0x00)      count = *(header + 0x08)
row i    : rows + i*0x80         实体 ID = *(row + 0x08)   8 字节
```
霸王虫的实体 ID 是**两个独立来源对上**的：

* 我们自己逐字节解析明文数据表：
  `murmur64a("content/fac_bugs/cha_hive_lord/cha_hive_lord") = 0xD465D9C7F77A07CB`；
* All-Stalker 抓下来的实战名册第 35 行：`cb077af7c7d965d4`（小端）= 同一个值。

**同一个值也是血量表里那条记录的键**，所以一个常量同时服务两条读法。
复算脚本：`work/hivelord/verify_entity_id.py`。

★ `overlap` 自检：区分"读到了名册"和"读到了看似合理的东西"
--------------------------------------------------------
抓取到的 39 个实体里有几个出现在这次读到的名册里，这个数就是 `overlap`。
读到正确结构时它接近 39；stride 或槽位错了它就是 0。所以读空时 STATUS 写得很清楚：

```
OK - Hive Lord NOT in any roster (...); overlap 0 means the layout is wrong,
     not that the Hive Lord is absent
```

★ 它**不会**做什么
--------------------------------------------------------
* **不写内存**：只用 `GetModuleHandleA` / `GetCurrentProcess` /
  `ReadProcessMemory` / `VirtualQuery`。**没有** `VirtualProtect`、没有
  `WriteProcessMemory`、不开别的进程、不碰代码页。构建脚本静态检查
  `FFI is used for reading only (no write primitive)` 通过。
* **不改刷怪**：All-Stalker 自己警告"boss/subentity 的生成路径可能绕开名册替换"，
  所以这里只读名册，不指望靠它召唤霸王虫。
* **构建不认识就拒绝**：先校验 `game.dll+0x93F159` 是不是 `49 8b 40 08`
  （读 `row+8` 的那条指令），不对就写 `REFUSED - build gate failed` 且什么都不读。

产物在哪
--------
  %APPDATA%\Arrowhead\Helldivers2\

  hivelord_roster_STATUS.txt  ★先看这个，第一行是结论
  hivelord_roster.log         ROSTER / HIVELORD_HP / HEALTH_MANAGER /
                              EXE_REGIONS / MODULE / BUILD_GATE / POLL_ERROR
                              （都只在内容变化时写，不会刷屏）
  hivelord_roster.txt         完整名册（每槽每行 + 实体 ID + 是否已知实体）

安装
----
  1. 导入 HiveLord-HP-Roster-1.1.0.zip，启用 Core。
  2. Purge → Deploy → 启动游戏。
  3. 进任意一局任务，等 10~20 秒（director 进任务才有；代码扫描每 2 秒一片，
     整个 game.dll 约 40 片）。
  4. 看 STATUS 第一行。

可选配置放
  %APPDATA%\Arrowhead\Helldivers2\hivelord_roster.cfg
  debug / poll_seconds / max_rows / roster_dump / start_delay

★ 它回答一个之前回答不了的问题：**霸王虫这一局到底在不在？**
--------------------------------------------------------
有一次实机里，你确认霸王虫在场并且把它打死了，但 Reader 读了 901 个对象、
**没有任何一个**带 150000 —— "它不在"和"我读不到"完全分不开。名册是另一条信号：
它是游戏 director 自己的阵营实体清单，用指针从模块 RVA 走两步就能读到，
**和网络层同步了什么毫无关系**。

STATUS 第一行就是结论：

```
OK - Hive Lord present: roster slot 0x660 row 35 (entity 0xD465D9C7F77A07CB);
     44 rows scanned, 39 match the captured Terminid roster [0x660:ok/44 0x668:... ]
```

或者

```
OK - Hive Lord NOT in any roster (44 rows scanned across 1 slot(s), 39 match the
     captured Terminid roster) [...]; overlap 0 means the layout is wrong,
     not that the Hive Lord is absent
```

**最后那句是有意写的**：读出来是空的时候，"它不在"和"我读错了结构"必须能分开。
`overlap` 就是那个判据 —— 它是抓取到的 39 个实体里有多少个出现在这次读到的名册里。
读到正确的结构时它接近 39；结构读错（stride/槽位错）时它是 0。

它读什么
--------
```
director = *(game.dll + 0x276CA20)
header   = *(director + 0x660 | 0x668 | 0x670)     ← 三个阵营槽
rows     = *(header + 0x00)      count = *(header + 0x08)
row i    : rows + i*0x80         实体 ID = *(row + 0x08)   8 字节
```

偏移来自 All-Stalker v0.2.1 的 `docs/TECHNICAL.md`（Steam 构建 24826606 / EXE 1.8.45317.0）。

霸王虫的实体 ID 是**两个独立来源对上**的：

* 我们自己逐字节解析明文数据表：
  `murmur64a("content/fac_bugs/cha_hive_lord/cha_hive_lord") = 0xD465D9C7F77A07CB`；
* All-Stalker 抓下来的实战名册第 35 行：`cb077af7c7d965d4`（小端）= 同一个值。

复算脚本：`work/hivelord/verify_entity_id.py`。

它**不会**做什么
--------
* 不写内存：只用 `GetModuleHandleA` / `GetCurrentProcess` / `ReadProcessMemory`，
  **没有** `VirtualProtect`、没有 `WriteProcessMemory`、不碰代码页、不开别的进程。
* 不改刷怪：All-Stalker 自己的文档警告"boss/subentity 的生成路径可能绕开名册替换"，
  所以这里**只读名册**，不指望靠它召唤霸王虫。
* 构建不认识就**拒绝**：写死的是 RVA，换个构建就是"自信的错答案"。所以先校验
  `game.dll+0x93F159` 的 4 个字节是不是 `49 8b 40 08`（就是读 `row+8` 的那条指令），
  不对就写 `REFUSED - build gate failed` 并且**什么都不读**。

产物在哪
--------
  %APPDATA%\Arrowhead\Helldivers2\

  hivelord_roster_STATUS.txt  ★先看这个，第一行是结论
  hivelord_roster.log         ROSTER 行（只在内容变化时写，不会刷屏）
                              MODULE / BUILD_GATE / POLL_ERROR
  hivelord_roster.txt         完整名册（每个槽的每一行 + 实体 ID + 是否已知实体），
                              识别失败时这就是证据

安装
----
  1. 导入 HiveLord-HP-Roster-1.0.0.zip，启用 Core。
  2. Purge → Deploy → 启动游戏。
  3. 进任意一局任务，等 10~20 秒（director 进任务才有）。
  4. 看 STATUS 第一行。

不需要配置。可选配置放
  %APPDATA%\Arrowhead\Helldivers2\hivelord_roster.cfg
  debug / poll_seconds / max_rows / roster_dump / start_delay
