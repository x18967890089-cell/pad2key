# pad2key

把手柄当键盘用：给**不支持手柄的老游戏**补一套按键桥接（单文件 PowerShell + SDL2，零安装）。

> A single-file PowerShell bridge that turns gamepad buttons into key presses for games that only understand a keyboard.

<p align="center"><i>[ 截图位 · 待补：<code>docs/screenshot.png</code> ]</i></p>

<!-- 补图步骤：真实截图存为 docs/screenshot.png，去掉下面一行的注释，并删掉上面那行占位。 -->
<!-- ![pad2key running](docs/screenshot.png) -->

---

## 快速开始

前置条件：Windows + PowerShell 5.1 及以上（系统自带）+ 一个 SDL2 能识别的手柄。
不需要管理员权限，不需要安装任何东西。

### 1. 装 SDL2.dll

到 <https://libsdl.org> → Download → 下载 SDL2 的 Windows 发行包（`SDL2-2.x.y-win32-x64.zip`），
解压后把 **`SDL2.dll` 放到 `pad2key.ps1` 同一个目录**。

也可以放进任意一个 `PATH` 目录，脚本按「同目录 → PATH」的顺序查找，找不到会直接报错并给出下载地址。

> 位数要对齐：64 位 PowerShell 必须配 64 位的 `SDL2.dll`，装错会提示 `SDL2.dll could not be loaded`。

### 2. 自检（不需要游戏，也不需要手柄）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\pad2key.ps1 -SelfTest
```

没插手柄时的实际输出：

```
pad2key self-test
  PowerShell : 5.1.26100.8115 (64-bit)
  SDL2 dir   : ...\pad2key  [next to pad2key.ps1]
  SDL2 build : SDL-release-2.32.10-0-g5d2495703
  joysticks  : 0
waiting for controller...
self-test finished, no keys were injected
```

插上手柄再跑一次，`joysticks` 会变成大于 0，并列出设备名与是否被识别为 game controller。
看到 `waiting for controller...` 就说明环境没问题，只差一个手柄。

### 3. 挂到游戏上

```powershell
# 按进程名（名字后面带不带 .exe 都行；把 flashplayer_21_sa 换成你自己的游戏进程名）
.\pad2key.ps1 -GameName flashplayer_21_sa

# 或按 PID —— 启动器拉起游戏时最可靠
$game = Start-Process .\game.exe -PassThru
.\pad2key.ps1 -GamePid $game.Id
```

不知道进程名：游戏开着的时候跑 `Get-Process | Where-Object MainWindowTitle | Select-Object Id,ProcessName,MainWindowTitle`。

`-GamePid` 和 `-GameName` 都不给会直接报错退出（不会去猜进程名）。
游戏退出后脚本自己结束；中途拔手柄会自动松开所有按键，插回来自动重连。

日志写在脚本同目录的 `pad2key.log`。

### 4. 按键没反应时按顺序查

1. **游戏窗口是不是在前台**——默认只在前台注入，Alt-Tab 出去会自动松开所有键，这是设计不是 bug。
2. **权限要对齐**——游戏用管理员权限跑的，脚本也必须用管理员权限跑，否则按键被 UIPI 拦掉（表现是自检正常、游戏里毫无反应）。
3. **自检里的 `joysticks` 是 0**——SDL2 没认出设备：换 USB 口 / 有线连接重试，装好手柄官方驱动，或换更新的 SDL2 版本。
4. **自检能列出手柄、游戏里还是没反应**——目标游戏多半用 Raw Input 或带反作弊，`keybd_event` 送进去的键它不认，这种情况目前无解。

四条都排完还是不行，带上 `-SelfTest` 的完整输出开 issue。

## 键位配置

改键只改脚本顶部的 `# ---- config ----` 区，改完存盘重跑即可，不用重新安装。

| 手柄输入 | 默认按键 | vk 码 | 变量 |
|---|---|---|---|
| 左摇杆向左 | `A` | `0x41` | `$KEY_LEFT` |
| 左摇杆向右 | `D` | `0x44` | `$KEY_RIGHT` |
| `X` 键 | `W` | `0x57` | `$KEY_JUMP` |
| `A` 键 | `S` | `0x53` | `$KEY_CROUCH` |
| `LB` | `Z` | `0x5A` | `$KEY_FIRE` |
| `RB` | `X` | `0x58` | `$KEY_NADE` |

摇杆死区 `$DEAD = 8000`（轴范围 `-32768..32767`），超过即视为按下。

改成方向键的例子：

```powershell
$KEY_LEFT  = 0x25   # Left arrow
$KEY_RIGHT = 0x27   # Right arrow
```

vk 码表见 [Virtual-Key Codes](https://learn.microsoft.com/windows/win32/inputdev/virtual-key-codes)。

## 已知限制

- **只做键盘注入**（`keybd_event`）：用 Raw Input 独占或带反作弊的游戏可能收不到按键；目标游戏以管理员权限运行时，脚本也要以管理员权限运行，否则按键被 UIPI 拦掉。
- **只有左摇杆 X 轴 + 6 个按钮**，没有右摇杆、扳机、摇杆模拟量（推过死区就是全速），也没有组合键/宏。
- **默认只在游戏窗口处于前台时注入**，切走会立刻松开所有键。`-ForceOn` 可以关掉这层保护，但误触会打进别的窗口，一般不要用。
- **没有配置文件和多套键位**，换游戏就是改代码里的配置区。
- **仅 Windows**（`user32.dll` + `keybd_event`）。
- 手柄能不能认，取决于 SDL2 自带的映射库；`-SelfTest` 会打印设备名，认不出就换手柄或换更新的 SDL2。
- 只在 Windows 11 x64 + PowerShell 5.1 + SDL2 2.32 上实测过，其它环境请开 issue。

退出码：`0` 正常结束 / `1` 90 秒内没找到游戏进程 / `2` 参数不全 / `3` 找不到 `SDL2.dll` / `4` SDL 初始化失败。

## 许可证

MIT © 2026 Reid — 见 [LICENSE](LICENSE)。
