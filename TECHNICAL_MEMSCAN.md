# 霸王虫血量兜底扫描 (Hive Lord HP MemScan) 1.1.0  —— 技术细节

> 只读 · 不调用任何引擎实体接口

## 1.1.0 的关键修复：签名不再用血量"数值"
1.0.x 找的是数值 `150000`。这条路有个**结构性**缺陷：霸王虫一旦掉过血，活体实例里的
`Health` 就不再是 150000，签名**必然漏掉它**。这才是"扫遍 6.5 GiB 只找到内存映射的
数据表、永远看不到实体"的真正原因 —— 不是运气差，是签名按构造就不可能命中。

1.1.0 改成找**不随伤害变化的结构常量**（记录 +0x28 起，连续 12 字节）：

    03 00 00 00 | 00 60 EA 46 | D0 07 00 00
    Size == 3 (UnitSize_Massive) | Mass == 30000.0f | KillScore == 2000

离线用游戏自己的数据表 `filediver/datalibrary/generated_entities.dl_bin`
（45,630,790 字节）验证过：

* 这 12 个字节在**整个文件里只出现 1 次**，位置 `0x7F4A1E` = 霸王虫 record[27] + 0x28；
* 单看 `Size==3` 有 46 条记录共用，所以三个常量必须**同时**要求；
* `Mass==30000.0` 在 493 条记录里**唯一**，`KillScore==2000` 也**唯一**；
* 这套验证已固化成测试 `tests/test_signature.py`（14 项检查 + 4 个变异自检）。
  常量一旦和数据表漂移，测试会失败，而不是在任务里悄悄读错数字。

命中后不只报 `Health`，还会**整块读出 38 个部位**并给出求和：

    LIVE_COMPONENT addr=0x... main=150000 zone_health_sum=1640000 TOTAL=1790000
                   const35000=13/13 zones_plausible=38/38

`zone_health_sum=1640000`、`zone_constitution_sum=455000`、`const35000=13` 都是从离线
数据表算出来的定值，活体读出来必须一模一样；对不上说明偏移漂了，日志会写
`LIVE_LAYOUT_MISMATCH`。

## 为什么必须走内存：网络字段读不出总血量（有实测证据）
读了一整局霸王虫战斗直到它死亡（`hivelord_hp.log`，对象 `goid=624`）：

* 它身上 46 个网络字段里**没有任何一个在死亡时归零**。唯一像血量的是一个
  **6 bit 量化比例**（值为 `k/63`，float32 精确吻合），它死亡瞬间读到 **61/63 = 97%**；
* 那个对象的**部位损伤掩码单调下降** `16383 → 5383`、全程从不回满 → 证明一直是同一个
  实体，不是重生；
* 对象在霸王虫死亡的同一刻消失（日志最后一行 `LOST goid=624`）→ 对象身份确认无误。

**结论：客户端网络层根本没有同步霸王虫的总血量**，只同步了部位比例和损伤掩码。
所以"血量"只能从客户端自己的组件内存里读 —— 也就是 1.1.0 现在做的事。

## 1.0.x 的正面成果（保留）
```
scanned 9858 readable regions, 6548 MiB address space
match at 0x22c67de49f6: health=150000 zones=38 magic=38
scan complete: 6598 MiB read, 1 structures found
```
* `health=150000` = main 血量，与 wiki 和离线解析一致；
* `zones=38 magic=38` = **38 个部位全部落在已知数值集合**里
  （离线解出的是 9×150000 + 12×15000 + 1×20000 + 2×10000 + 14×5000 = 38）；
* 扫完 6.5 GiB **只找到 1 个**结构 → 零误报。
* 地址算术证明它命中的是"内存映射的明文数据表"：
  `0x22c67de49f6 − 0x7F49F6 = 0x22c675f0000`，**64 KiB 对齐**。

**重要的负面结论**：只找到 1 个结构，说明内存里**没有第二份"每实体血量副本"**。
也就是说"盯着蓝图等它变"永远不会变 —— 各部位**上限**离线就已知道，
而**实时当前血量**存在别处。

1.0.1 因此做了两件事：
* **每 120 秒重扫一遍**（霸王虫通常在扫描开始很久之后才出现，只扫一遍等于永
  远看不到实体）；
* 把命中**分类**为 `BLUEPRINT`（地址减去已知文件偏移后 64 KiB 对齐）或 `OTHER`，
  `WATCH` 行也带类别 —— "只有蓝图"和"找到了实体"一行就能区分；
* 日志改成逐行 open/append/close（旧实现丢了整整一局的日志），
  并把日志自身健康度写进 STATUS。

这是什么
这是**备选方案**（Plan B）。主方案（HiveLord-HP-Probe）走游戏自己的实体接口；
如果那条路走不通（以前有探测 mod 用引擎实体接口把游戏搞崩过两次），就用这个。

它**完全不碰 stingray / GameSession / Network**，只在进程内存里按字节特征找
霸王虫的血量结构体，找到之后盯着它，记录数值变化。**只读，不写内存。**

它在找什么
`HealthComponent` 结构，偏移量是从游戏自带 typelib + 明文数据表
`filediver/datalibrary/generated_entities.dl_bin` 逐字节解出来的：

    记录 +0x00  Health                int32   = 150000   ← 要盯的就是这个
    记录 +0x04  HealthChangerate      float32 = 0.0
    记录 +0x18  Constitution          int32   = 0
    记录 +0x28  Size (Massive)        int32   = 3
    记录 +0x2C  Mass                  float32 = 30000.0
    记录 +0x30  KillScore             int32   = 2000
    记录 +0x208 DamageableZones[38]   stride 552
               zone.Health        int32 @ zone+0xE8
               zone.Constitution  int32 @ zone+0xEC

`150000` 在这 10 个字节里和 `Size==3`、`Mass==30000.0`、`KillScore==2000`
紧挨在一起 —— 这是个非常窄的指纹，撞车的可能性极低。

两条特征：
  1. **主特征（1.1.0 起）= 上面 +0x28 的 12 字节结构常量**。它们不随伤害变化，
     所以霸王虫在扫描开始前就已经掉血、甚至掉了大半血，照样能命中。
  2. 补充特征 = 相邻的 `15000` + `35000`（某个部位的 Health/Constitution），
     以及数值 `150000` + `0.0` —— 只在满血实例和数据表上命中，作为交叉印证。

找到之后每 2 秒回读一次，数值变了就写 `WATCH_CHANGE`；对主特征命中还会整块解析
38 个部位（`LIVE_COMPONENT` / `hivelord_mem_live.txt`）—— **那几行就是
"实时血量确实读到了"的证据。**

前置要求
只需要 **Bingus Shared Loader v15 或更新（API 1）**。

安装与运行
  1. 导入 HiveLord-HP-MemScan-1.1.0.zip，启用 Core。
  2. Purge → Deploy → 启动游戏。
  3. 进任意一局任务（不限定巢都星球），待 10~20 秒让扫描跑完。
  4. 有霸王虫就更好：出现后让它挨点打。
  5. 退出游戏。

产物在哪
  %APPDATA%\Arrowhead\Helldivers2\

  hivelord_mem_STATUS.txt  ★先看这个。第一行是结论。
  hivelord_mem.log         主日志：
      REGIONS         扫到多少个可读内存区
      MATCH           找到的结构（地址 / 各字段值 / 部位数组是否对得上）
      MATCH_HEX       命中的 256 字节原始 hex（离线复核用）
      WATCH / WATCH_CHANGE   实时血量变化
      LIVE_COMPONENT  main + 38 部位求和（main/zone_sum/TOTAL/const35000）
      LIVE_LAYOUT_CHECK  用定值校验偏移有没有漂（只在数据表副本上打印）
      SCAN_DONE       扫完
  hivelord_mem_live.txt    活体命中时的 38 部位明细表
  hivelord_mem_state.txt   扫描断点

反馈时请把 hivelord_mem_STATUS.txt 和 hivelord_mem.log 一起给我。

性能与安全
* 每帧最多花 6 毫秒 CPU（可配），单次读取 512 KB，分片推进，
  不会像"一次扫 64 MB"那样把游戏卡死。
* 断点续扫：崩了重启会从上次的内存区继续，不会重复崩在同一个地方。
* pcall 的错误**不会被吞掉**，会写进日志（静默失败等于白跑一趟）。
* 只读：没有任何写入原语，也不需要改页保护。禁用 + Purge 即可完全移除。
* 建议先单机（Solo）测试。

配置（可选）
默认值即可用。要调就把下面的内容存成
  %APPDATA%\Arrowhead\Helldivers2\hivelord_mem.cfg
改完重启游戏。

  debug=true
  chunk=524288        # 单次读取字节数
  budget_ms=6         # 每帧扫描 CPU 预算（毫秒）
  start_delay=600     # 启动后等多少帧再开始扫
  watch_seconds=2     # 命中后的回读间隔
  max_matches=256     # 最多记录多少个结构
  hex_dump=256        # 每个命中导出的 hex 字节数

第三方来源
结构偏移来自游戏自带 typelib 与本地明文数据表；霸王虫部位血量数值与
https://helldivers.wiki.gg/wiki/Hive_Lord 完全一致。
