# 霸王虫血量侦察包 (Hive Lord HP Probe) 1.1.0  —— 技术细节

> 只读 · 分阶段侦察 · 每次上机只前进一小步

这个包是干什么的
它不是血量 UI，而是**侦察工具**：不修改游戏内存，只调用游戏自己暴露的 Lua 接口，
把能读到的东西全部落到磁盘上。它存在的理由是——

> 上一版有个侦察 mod 直接遍历 `Network` 表、把每个成员函数都调用一遍看返回什么，
> **把游戏搞崩了两次**，只留下 5 行日志。所以现在每一条引擎调用都必须
> **先被证明是安全的**，并且崩溃点会**在调用之前**写进日志。

用一句话说：**它是用来在"不知道"的时候，用最小代价换取事实的工具。**

它回答的问题
1. 游戏引擎的 Lua 接口到底有哪些可用（有没有"枚举所有实体"这种函数）；
2. 霸王虫的 game object 能不能被找到；
3. 它的血量字段在第几个、能不能读到实时数值。

阶段（每次只做一件，都能单独得出结论）
  Stage A  列出引擎 Lua API 表（只列名字和类型，**一个都不调用**）
  Stage B  会话 / 对端 / 世界 / 已拥有对象的报告（只调用已证明安全的接口）
  Stage C  用 `game_object_exists` 做 game-object-id 普查
  Stage D  用 `game_object_field_batched` 按指纹扫霸王虫的伤害分区血量星座
           （150000 主体 + 150000×9 分区、35000×14、15000×14、20000×1、
            5000×14、10000×2 —— 离线从明文的 generated_entities.dl_bin
            推出来的，见 work/hivelord/HIVE_LORD_HEALTH.md）
  Stage E  对每个指纹候选做完整字段数组 dump + 实时观察

为什么每一步都这么小心
* **Stage A 只列表，不调用。** 用错的参数个数或未知的类型名去调引擎函数，
  是**原生访问违例**，不是 Lua 错误，`pcall` 抓不住。
* 本文件里的每一次调用都写在 `SAFE_*` 白名单里，并且都由已发布、可用的
  DRIVER HUD 1.2.1 单独证明过。
* **每个有风险的操作都在执行前写日志**，所以日志最后一行就是杀死游戏的那次调用。
* **Stage D 在磁盘上保存游标。** 如果崩了，下次启动会从让游戏崩溃的那个对象
  **之后**继续，而不是再崩一次。

产物在哪
  %APPDATA%\Arrowhead\Helldivers2\

  hivelord_STATUS.txt        ★先看这个，第一行是结论
  hivelord.log               全过程日志（每次调用前的那一行最关键）
  hivelord_census.txt        Stage C 的 id 普查结果
  hivelord_owned*.txt        Stage B 的已拥有对象报告
  hivelord_shape*.txt        Stage E 的字段数组 dump
  hivelord_state.txt         Stage D 的磁盘游标（崩溃后续跑用）

前置要求
只需 **Bingus Shared Loader v18 或更新（API 1）**。
不需要、也不依赖 HD2 HUD+ 或任何别的 mod。**纯只读**：不写游戏内存，
不发网络包，不改游戏数据。

安装
----
  1. 导入 HiveLord-HP-Probe-1.1.0.zip，启用 Core。
  2. Purge → Deploy → 启动游戏。
  3. 进任务，把日志给我即可。

读日志的方法
* 结论不对时**先看最后一次"调用前"的日志行** —— 它写着即将执行什么；
* Stage D 崩过之后，`hivelord_state.txt` 里的游标会让下一次跳过那个对象；
* 想从头再来：删掉 `hivelord_state.txt`。

如果你只是想要"看到血量"，用 `HiveLord-HP-Health`（精确血量，装完即用），
不需要这个包。
