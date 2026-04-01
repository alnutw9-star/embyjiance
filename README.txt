Emby + 189Pro Guard Suite 使用说明
=================================

文档版本：v2.0
创作时间：2026-04-02
最后更新：2026-04-02

作者：walnut
联系方式：alnutw9@gmail.com
版权声明：本文档及配套脚本仅供授权使用，未经允许禁止转载、倒卖、二次分发或商用，侵权必究。

一、项目简介
------------
Emby + 189Pro Guard Suite 是一套用于 Emby 与 189Pro 联动监控、自动恢复、Telegram 通知与远程控制的守护工具集。

适用场景：
1. Emby 作为核心服务运行；
2. 189Pro / cloud189pro 作为配套服务或反代链路的一部分；
3. 希望在服务异常时自动检测、自动恢复、自动通知；
4. 希望通过 Telegram 私聊远程查看状态、手动重启与控制守护功能。

主要特点：
1. 同时监控 Emby 与 189Pro；
2. 189Pro 异常时会先复核 Emby，避免误判；
3. Emby 与 189Pro 支持独立失败计数、独立熔断；
4. 支持 Telegram 私聊控制；
5. 支持自动恢复、手动重启、守护暂停与恢复；
6. 日志分层清晰，适合长期运行与排障。

二、文件说明
------------
actions.sh
公共动作库，负责以下核心能力：
- 健康检查
- 自动恢复
- 手动重启动作
- 熔断逻辑
- Telegram 发送
- 状态摘要生成

emby_guard.sh
主守护脚本，负责：
- 定时巡检 Emby 与 189Pro
- 异常计数
- 触发自动恢复
- 熔断控制
- 守护日志输出

tg_control.sh
Telegram 控制器，负责：
- 接收私聊命令
- 查询状态
- 手动重启 Emby / 189Pro
- 暂停或恢复守护功能
- 返回详细执行结果

config.conf
总配置文件，必须先修改后再运行。
主要包含：
- 路径配置
- Emby 配置
- 189Pro 配置
- 监控节奏
- 恢复等待时间
- 熔断参数
- 日志参数
- Telegram 参数

start_suite.sh
手动启动主守护与 Telegram 控制器。

stop_suite.sh
手动停止主守护与 Telegram 控制器。

status_suite.sh
查看当前守护与控制器进程状态。

三、部署步骤
------------
1. 将整个目录放到服务器，例如：
   /cloud189pro/emby检测

2. 编辑 config.conf，至少修改以下项目：
   TG_BOT_TOKEN
   TG_CHAT_ID
   TG_ALLOW_CHAT_IDS
   TG_ALLOW_USER_IDS
   SERVICE_NAME
   PRO189_CONTAINER_NAME

3. 建议确认以下路径存在：
   BASE_DIR
   LOG_DIR
   RUN_DIR
   TMP_DIR

4. 赋予执行权限：
   chmod +x *.sh

5. 先停掉旧版脚本或旧监控服务：
   embyjc.sh
   emby-monitor.service

6. 手动启动：
   ./start_suite.sh

7. 查看当前状态：
   ./status_suite.sh

8. 如需停止：
   ./stop_suite.sh

四、配置重点说明
----------------
1. Emby 默认本机检测地址：
   http://127.0.0.1:8096/emby/System/Info/Public

2. 189Pro 默认本机检测地址：
   http://127.0.0.1:8091/

3. Telegram 建议使用私聊，不建议群组控制。

4. 建议 TG_ALLOW_USER_IDS 填写实际 Telegram 用户 ID；
   若暂时不确定，可先留空，仅校验 TG_ALLOW_CHAT_IDS。

5. 若服务器访问 Telegram 需要代理，请在 config.conf 中设置：
   TG_PROXY

6. 若 189Pro 有更稳定的健康接口，建议将：
   PRO189_HEALTH_PATH
   改为该接口，以提高检测准确率。

五、监控与恢复策略
------------------
1. 同时监控 Emby 与 189Pro；
2. Emby 与 189Pro 分别独立统计失败次数；
3. Emby 与 189Pro 分别独立熔断，互不影响；
4. 当 Emby 与 189Pro 同时异常时：
   - 先恢复 Emby
   - 再重新检查 189Pro
   - 如 189Pro 仍异常，再恢复 189Pro

5. 当仅 189Pro 异常时：
   - 先快速复核 Emby
   - 若 Emby 正常，则只重启 189Pro
   - 若 Emby 也异常，则转为先恢复 Emby，再恢复 189Pro

6. 当仅 Emby 异常时：
   - 直接执行 Emby 自动恢复流程

7. 自动恢复失败后不会无限重启；
   若短时间内恢复次数过多，将触发熔断，暂停自动恢复。

六、当前推荐参数
----------------
当前推荐使用偏稳定的节奏，避免误判和连环重启：

1. 正常巡检间隔：
   15 秒一次

2. 异常复查间隔：
   5 秒一次

3. 连续失败阈值：
   Emby：3 次
   189Pro：3 次

4. Emby 恢复等待：
   优雅重启后：180 秒
   强制重启后：300 秒

5. 189Pro 恢复等待：
   docker restart 后：90 秒
   stop/start 后：120 秒

6. 熔断窗口：
   30 分钟内统计恢复次数

7. 熔断暂停时间：
   60 分钟

说明：
这一套参数偏向“稳定优先”，适合长期运行。
若后续长期观察确认稳定，再考虑逐步缩短时间。

七、日志位置
------------
所有日志默认写入 config.conf 中 LOG_DIR 指定目录。

主要日志如下：

guard.log
主守护关键日志。
记录：
- 守护启动
- 异常检测
- 自动恢复开始
- 自动恢复成功或失败
- 熔断触发与解除

actions.log
动作执行日志。
记录：
- Emby 重启
- 189Pro 重启
- 动作锁
- 手动操作与自动操作过程

telegram.log
Telegram 发送日志。
记录：
- 发送成功
- 发送失败
- TG 请求错误信息

tg_control.log
Telegram 控制器审计日志。
记录：
- 收到的命令
- 权限校验结果
- 命令执行结果
- 控制器启动与退出

debug.log
调试日志，默认关闭。
仅在开启 DEBUG_LOG_ENABLE 后输出。

八、Telegram 命令
-----------------
/help
查看帮助菜单。

/status
查看 Emby、189Pro、守护工具整体状态。

/status_emby
只查看 Emby 当前状态。

/status_189pro
只查看 189Pro 当前状态。

/restart_emby
手动重启 Emby，并返回详细结果。

/restart_189pro
手动重启 189Pro，并返回详细结果。

/restart_all
依次重启 Emby 与 189Pro，并返回整体结果。

/pause_guard
暂停守护的自动恢复功能。

/resume_guard
恢复守护的自动恢复功能。

说明：
1. 当前 Telegram 控制按私聊场景设计；
2. 非私聊命令默认忽略；
3. 执行类命令会返回详细结果与耗时；
4. 手动重启时会尽量避免与守护自动恢复冲突。

九、通知说明
------------
启用 Telegram 后，系统可发送以下通知：

1. 脚本启动通知
2. 脚本停止通知
3. 异常预警通知
4. 开始恢复通知
5. 恢复成功通知
6. 恢复失败通知
7. 熔断告警通知
8. 状态心跳通知（默认关闭）

建议：
若不希望 Telegram 消息过多，可关闭异常预警，仅保留：
- 开始恢复
- 恢复成功
- 恢复失败
- 熔断
- 启动/停止

十、注意事项
------------
1. 上线前请先停掉旧版监控脚本和旧服务；
2. 请先确认 Emby 与 189Pro 的本机访问地址可用；
3. 请确认 Telegram Bot Token、Chat ID、User ID 配置正确；
4. 若 Telegram 命令无响应，请优先检查：
   - tg_control.sh 是否运行
   - Telegram 配置是否正确
   - tg_control.log 是否有报错
   - telegram.log 是否有发送失败记录

5. 若发生频繁自动恢复：
   - 请优先检查真实服务问题
   - 不建议一味缩短检测时间
   - 建议先保证恢复窗口足够，再逐步调优

6. 若需手动维护，建议先通过 Telegram 使用：
   /pause_guard
   维护结束后再：
   /resume_guard

十一、维护建议
--------------
1. 先稳定运行，后逐步调优；
2. 先确认服务本身稳定，再压缩恢复等待时间；
3. 保持 Telegram 控制仅私聊使用；
4. 定期检查日志目录与历史日志大小；
5. 如需长期使用，建议先连续观察数天再改动关键参数。

十二、版权与使用声明
--------------------
本套件及本文档由 walnut 编写整理。
仅供授权环境使用。

未经作者许可，禁止：
1. 倒卖
2. 二次分发
3. 伪装原创
4. 商业转载
5. 擅自修改后冒充原作者发布

侵权必究。

作者：walnut
联系邮箱：alnutw9@gmail.com
创作时间：2026-04-02
最后更新：2026-04-02