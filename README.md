# wildpig.glucose — 状态栏血糖小组件

Omarchy（Quickshell）状态栏上的血糖药丸 + 详情弹窗。数据来自雅培
LibreLinkUp（瞬感通）只读接口，或你自己的 Nightscout。

> ⚠️ 不是医疗器械，**不能据此做治疗决策**。报警延迟、断连、云端滞后都可能发生，
> 紧急情况请用官方路径或扎手指。

## 它解决了官方 App 的什么毛病

| App 的问题 | 这个组件 |
|---|---|
| 数据显示单一 | 药丸显示当前值 + 趋势箭头，越界自动变色；可选迷你曲线 |
| 历史数据不能在曲线上取 | 弹窗里任意点都带数值、时间、趋势 |
| 看不到昨天的数据 / 没有时间窗口 | 3h / 6h / 12h / 24h 窗口 + 24h 视图下可 `‹ ›` 翻到昨天、前天 |
| 菜单多而无用 | 只有一个弹窗：曲线、目标区间、缺口、达标率、低于/高于占比、传感剩余 |
| 断了看不出来 | 药丸变暗 + 横幅提示读数年龄，统计里直接显示**最大缺口**（分钟） |
| 不会主动告诉你 | 可选的高低血糖桌面通知，只在越界那一刻响，点一下打开详情 |

## 现在显示的是假数据

组件默认跑在 `mock` 源上（合成曲线），这样不用账号也能看效果。
**切到真数据只要改一个文件**：`~/.config/omarchy/glucose/config.json`。

## 数据怎么流过来的

```
瞬感2代传感器 ──BLE──▶ 瞬感宝（手机，每分钟）──▶ 瞬感云
                                                  │
                          ┌───────────────────────┴──────────────┐
                          ▼                                      ▼
              LibreLinkUp 只读接口                        瞬感通 / FLwatch
                          │
              scripts/glucose-fetch.py（每 60 秒）
                          │  归一化成 mg/dL + UTC 秒
                          ▼
              状态栏药丸 + 详情弹窗
```

关键前提（**缺一不可**，否则云端就是空的）：

1. 传感器必须是**用「瞬感宝」手机 App 启动**的（不是那个扫描检测仪）
2. 瞬感宝要有网络（Wi-Fi 或给瞬感宝开蜂窝数据权限），且**别上滑强杀它**
3. 瞬感宝里已经**发出共享邀请**，并且对方账号已经在 **瞬感通** 里**接受**了

## 配置 LibreLinkUp（瞬感通）

1. 打开**瞬感宝** → 找「共享 / 数据共享 / 连接的应用」→ 填一个邮箱发出邀请
   - 先试你自己的邮箱；若提示已注册，就换第二个邮箱
2. 用那个邮箱注册登录 **瞬感通**，接受邀请，确认能看到曲线
3. 建配置（只放非机密项）：

```bash
mkdir -p ~/.config/omarchy/glucose
cp ~/.config/omarchy/plugins/wildpig.glucose/config.example.json \
   ~/.config/omarchy/glucose/config.json
$EDITOR ~/.config/omarchy/glucose/config.json      # 只需填 email / region
```

4. **输入账号密码**（密码存进系统 keyring，不写进任何文件）：

```bash
python3 ~/.config/omarchy/plugins/wildpig.glucose/scripts/glucose-fetch.py --set-credentials
```

提示输入邮箱（回车用配置里的）和密码（隐藏输入）；先验证能登录，再把密码存入
keyring，并把邮箱/区域写回 config。**密码不会出现在 `config.json` 或任何 git 文件里。**

也可用环境变量（适合临时/CI）：`GLUCOSE_LLU_EMAIL` / `GLUCOSE_LLU_PASSWORD`。
优先级：环境变量 → keyring → `config.json` 的 `password`（旧字段，仅向下兼容）。

`region` 中国区填 `cn`（接口域名是 `api-cn.myfreestyle.cn`）；留空脚本会自己探测，但慢一些。

5. 命令行验证，**先别管状态栏**：

```bash
python3 ~/.config/omarchy/plugins/wildpig.glucose/scripts/glucose-fetch.py --whoami
```

这个命令**不读血糖**，只回答两个问题：我是谁、我在关注谁。

```json
{
  "region": "cn",
  "role": "patient",          ← patient = 发布者（瞬感宝主账号），"follower" = 关注者
  "connections": [],          ← 空数组 = 还没有任何共享关系
  "hint": "no follower link for this account: ..."
}
```

`connections` 里有一条记录，才算能取到数据：

```json
{
  "role": "patient",
  "connections": [
    { "patientId": "...", "targetLow": 70, "targetHigh": 180,
      "sensorSerial": "...", "latest": "9/16/2026 7:12:03 AM" }
  ]
}
```

然后再看真实数据：

```bash
python3 ~/.config/omarchy/plugins/wildpig.glucose/scripts/glucose-fetch.py --debug \
  | python3 -m json.tool | head -40
```

`"ok": true` 且有 `series` 就算通了；`"ok": false` 看 `error` / `code`：

| code | 含义 | 怎么办 |
|---|---|---|
| `no-share` | 这个账号没有在关注任何传感器 | 见下方“role=patient”那一节 |
| `auth` | 邮箱或密码错 | LibreLinkUp 用**完整邮箱**登录，不是用户名 |
| `cooldown` | 连续登录失败 3 次，已暂停 30 分钟 | 修好账号后删掉 `~/.local/state/glucose/login-guard.json` 立刻重试 |
| `region` | 区域服务器不对 | 试 `cn` / `eu` / `us` |
| `terms` | 雅培要求重新同意条款 | 打开官方 App 同意一次再试 |
| `network` / `config` | 网络或配置问题 | 看 `--debug` 的报错 |

5. 状态栏右键或 `omarchy-shell wildpig.glucose refresh` 立刻刷新。

### 登录成功但 `no-share`（role=patient）

这是最常见的坑，而且很反直觉：

> **你的瞬感宝主账号，可以直接登录 LibreLinkUp，但它“不关注任何人”，所以拿不到数据。**
> 它的 JWT 里写着 `"role":"patient"`——它自己就是那个病人。

Abbott 的模型里，**只有 follower（关注者）角色才能读数据**，而 follower 关系只能通过
“邀请 → 接受”建立，而且这个关系会（换传感器、长期不用、换设备后）失效。

修复方式，二选一：

**A. 自己关注自己**（不用第二个邮箱）
1. **瞬感宝** → 菜单 → 「共享 / 数据共享 / 连接的应用」→ 输入**自己的邮箱** → 发送邀请
2. **瞬感通** → 用**同一个邮箱**登录 → 会看到邀请 → **接受**
3. 重跑 `--whoami`，`connections` 里应该突然多出一条

**B. 用第二个邮箱当关注者**
1. **瞬感宝** → 邀请第二个邮箱（比如 `xxx@gmail.com`）
2. **瞬感通** → 用第二个邮箱**注册**并登录 → 接受邀请
3. 重新运行 `--set-credentials`，输入第二个邮箱那组（同样只进 keyring）

> 注意：只在瞬感通里**自己注册一个账号并不会自动看到任何东西**——注册出来的是
> 又一个 patient，而不是 follower。必须走邀请。

环境变量可覆盖：`GLUCOSE_CONFIG`、`GLUCOSE_CACHE`。

## 可选：用自建 Nightscout 当后端

如果你已经在跑 Nightscout（或 `nightscout-librelink-up` 侧车），
把 `source` 改成 `nightscout`，好处是有**更长的历史**（可以看前几天、做报告），
而且数据落在自己手里，不怕雅培改接口。

```json
{
  "source": "nightscout",
  "historyHours": 48,
  "nightscout": {
    "url": "https://ns.example.com",
    "token": "管理后台的 API secret",
    "tokenType": "secret"
  }
}
```

`tokenType`：`secret` 用 `api-secret` 头（脚本自动做 SHA1）；`token` 则当作只读
token 放进查询串。

## 设置项

在 `~/.config/omarchy/shell.json` 的布局项里直接写（保存即热重载）：

```json
{ "id": "wildpig.glucose", "unit": "mmol/L", "palette": "traffic", "windowHours": 12 }
```

| 键 | 默认 | 说明 |
|---|---|---|
| `unit` | `mmol/L` | `mmol/L` 或 `mg/dL` |
| `palette` | `traffic` | `traffic` 红/绿/黄分级；`theme` 只有越界时才用主题强调色 |
| `lang` | `zh` | `zh` / `en` |
| `showTrend` | `true` | 药丸是否带趋势箭头 |
| `showUnit` | `false` | 药丸是否带单位 |
| `sparkline` | `false` | 药丸里画最近 3 小时的迷你曲线（窄屏会自动退回纯文字） |
| `alerts` | `false` | 高低血糖桌面通知。**接上真实数据后再打开** |
| `alertRepeatMinutes` | `15` | 持续越界时，多久再提醒一次（只在越界那一刻和每隔这么久提醒，不会每次轮询都响） |
| `refreshIntervalSec` | `60` | 轮询间隔（最低 15 秒，别太激进，雅培会限流） |
| `staleMinutes` | `20` | 超过多久没新数据就把药丸变暗并弹横幅提示 |
| `source` | `""` | 覆盖配置文件里的 `source`（`librelinkup` / `nightscout` / `mock`） |
| `windowHours` | `6` | 弹窗默认窗口 |

### 提醒（alerts）的行为

- 只在**越界的那一刻**发通知（上升沿），不是每次轮询都发；持续越界按
  `alertRepeatMinutes` 重复
- **数据已经过期时不提醒**：两小时前的读数不是"现在"的新闻
- 同一条通知用固定 ID 替换，不会堆成一摞
- 点通知会直接打开详情弹窗
- 传感器剩余不足 24 小时时提醒一次
- 外壳重启后的头两分钟不提醒，避免重启就复读一遍旧警报

### 迷你曲线

`sparkline: true` 时药丸变成「曲线 + 数值」，采样最近 3 小时、抽稀到 40 个点，
越界时整条曲线跟着变色。宽度是自动算的，不会挤压相邻图标。

## 交互

| 操作 | 效果 |
|---|---|
| 左键点药丸 | 开/关详情弹窗 |
| 中键 / 右键 | 立刻刷新 |
| `R` | 刷新 |
| `1` `2` `3` `4` | 切到 3h / 6h / 12h / 24h |
| `[` `]` | 24h 视图下往前/后翻一天 |
| `Esc` | 关闭弹窗 |

命令行：

```bash
omarchy-shell wildpig.glucose toggle
omarchy-shell wildpig.glucose refresh
```

## 颜色约定（`palette: traffic`）

| 区间 | 颜色 |
|---|---|
| < 3.0 mmol/L（54 mg/dL） | 红 |
| < 目标下限（默认 3.9） | 橙红 |
| 目标区间内 | 绿 |
| > 目标上限（默认 10.0） | 黄 |
| > 13.9 mmol/L（250 mg/dL） | 橙 |

目标上下限来自云端账号设置（LibreLinkUp 的 `targetLow/targetHigh`），
Nightscout 源用配置里的值。

## 开发 / 改代码

- **`shell.json` 的改动会即时热重载**（改设置项、换窗口大小，保存就生效）。
- **QML / JS 文件的改动需要重启外壳**：实测「保存 → 自动 reload」不会把新代码
  应用到一个已经挂载的组件上（即使在 `shell rescanPlugins` 之后也不行），
  所以改完 `BarWidget.qml` / `Panel.qml` / `Model.js` 后跑：

  ```bash
  omarchy restart shell
  ```

- 不要在 `Model.js` 顶部加 `.pragma library`：那会把脚本缓存在外壳进程里，
  任何改动直到重启都不生效（而且是被 `dump` 在内存里的旧版本）。
- 用假数据开发：`"source": "mock"`，弹窗会一直显示"示例数据"横幅提醒你。

## 已知限制

- **曲线上的空洞是真实的**：LibreLinkUp 只在手机连着传感器并上传时才有数据；
  蓝牙断了、手机没网、App 被杀，曲线就断。脚本把超过 15 分钟的间隔拆段，
  不会用直线把缺口连起来（避免看着像真数据）。
- LibreLinkUp 本身**滞后 5~15 分钟**，且历史数据偶尔晚到。
- LibreLinkUp 的 graph 接口一般只给最近 **约 24 小时**；想看更久要用 Nightscout。
- 第三方 App 有被雅培掐掉的先例（Spike 被下架过）。**自建 Nightscout 最抗风险**。
- 传感器更换、账号改动后，共享关系偶尔要**重新邀请 + 重新接受**。

## 文件结构

```
~/.config/omarchy/plugins/wildpig.glucose/
├── manifest.json          插件清单（供 Omarchy 注册与设置界面使用）
├── BarWidget.qml          状态栏药丸 + 轮询 + IPC
├── Panel.qml              详情弹窗（曲线 / 窗口 / 统计）
├── Model.js               纯函数：单位换算、区间判定、曲线几何、文案
├── scripts/glucose-fetch.py   取数（LibreLinkUp / Nightscout / mock）
├── config.example.json
└── README.md

~/.config/omarchy/glucose/config.json    账号配置（600，别提交）
~/.local/state/glucose/last.json         最近一次结果缓存（登录后秒出）
~/.local/state/glucose/token.json        LibreLinkUp token 缓存（免重复登录）
```

`scripts/glucose-fetch.py` 只用 Python 标准库，不需要 pip 安装任何东西。

## 卸载

```bash
omarchy plugin disable wildpig.glucose
rm -rf ~/.config/omarchy/plugins/wildpig.glucose
rm -rf ~/.config/omarchy/glucose ~/.local/state/glucose
```

## 可选：Jev 曲线解读（TypeSafe）

接上 [TypeSafe](https://typesafe.ai) 的 Jev 后，弹窗里会多一行
「Jev: 餐后波动 · 置信 55% · 伪值 28%」——它对**当前曲线**做一次类型化判断，
帮你一眼看懂「这段是什么形态」。

**它只是解读。** 不是医疗器械，也不会：

- 隐藏任何读数
- 改变或抑制任何高低血糖报警
- 给出治疗建议

配置（`~/.config/omarchy/glucose/config.json`）：

```json
"jev": {
  "enabled": true,
  "apiKey": "",
  "model": "jev-1.13.0",
  "onlyWhenOutOfRange": true,
  "minIntervalSec": 900
}
```

- key 优先取环境变量 `TYPESAFE_API_KEY`，其次 `~/.winnow/env`
- `onlyWhenOutOfRange`：默认只在越界时调用（省钱）；设 `false` 则每次刷新都判断
- `minIntervalSec`：两次调用最短间隔，默认 900 秒
- 命令行试一次：`scripts/glucose-fetch.py --interpret`

判定结果写入 `~/.local/state/glucose/jev.json`；弹窗直接读 `last.json` 里的
`interpretation` 字段。

## 历史数据与「昨天 / 前天」

LibreLinkUp 的 `graph` 接口**每次只返回约 12 小时**（实测请求 72 小时也只给约 12 小时、
~47 个点）。所以弹窗里点 `24h` 后用 `‹ ›` 翻到昨天、前天，靠的不是云端——
而是插件**每次轮询都把读数累积**到本地滚动历史里：

```
~/.local/state/glucose/history.json      # 按时间戳去重，默认保留 7 天
```

配置：

```json
"history": {
  "enabled": true,
  "retentionHours": 168
}
```

含义：**从你开始运行这个组件的那天起**，历史会一天天攒起来，昨天/前天才有数据。
接上 Nightscout 的话历史更完整（`source` 改成 `nightscout`），因为它本身就存长期数据。

## 安全 / 凭据

- **代码和仓库里没有任何账号密码。** 密码只用 `--set-credentials` 输入一次，存进桌面
  keyring（libsecret）；`config.json` 只保留邮箱（非机密）和区域。
- 凭据优先级：环境变量 `GLUCOSE_LLU_EMAIL` / `GLUCOSE_LLU_PASSWORD`
  → keyring → `config.json` 的 `password`（旧字段，仅向下兼容）。
- 缓存文件（`last.json` / `history.json` / `token.json`）权限均为 `0600`，且都在
  `.gitignore` 里。
- 这是**只读**接口，不会写回雅培云端；但血糖属于健康数据，注意本机与备份的隐私。
- 非医疗器械，**不能据此做治疗决策**。

## 开源 / 贡献

MIT 许可（见 `LICENSE`）。欢迎提 Issue / PR。提交前请跑：

```bash
omarchy plugin validate .
python3 -m py_compile scripts/glucose-fetch.py
node --check Model.js
```
