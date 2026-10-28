# Kaminec-Lua

一个用 **Lua 5.4** 写的极简 Minecraft: Java Edition 启动器（Windows / Linux）。

目标很明确：不做完整产品，只做能独立跑通、可嵌入其他项目的 CLI 启动核心。灵感来自 [KL_Launcher](https://github.com/kaniol-lck/KL_Launcher) 与 [Kaminec](https://github.com/kaniol-lck/Kaminec)。

## 状态

- 当前版本：**0.1.0**（Windows / Linux；macOS 仅 CI 验证）
- 已实测启动到主菜单：
  - Minecraft 1.21.8（Windows 离线；Linux WSLg + OpenAL）
  - Forge 1.20.1 / NeoForge 21.1.209 / Fabric 0.20.1
  - Forge 1.12.2（Java 8）
- 自动下载、SHA1 校验、断点续传、natives 解压、旧版本格式回退
- 离线账号 / 官方启动器 token 导入 / Microsoft OAuth 浏览器登录

## 功能

- `versions` / `plan` / `download` / `launch` 四段式 CLI
- 现代 version json（`arguments`、rules、classifier、Maven `url`）
- 旧版本（≤1.12.2）的 `minecraftArguments`、默认 JVM 参数、legacy natives
- 本地已安装实例优先，支持 Forge/NeoForge/Fabric 的继承版本
- 下载先落 `.part` 再校验/rename，`--repair` / `--verify` 可修复/全量校验
- 可嵌入的插件 API（`src/plugin.lua`，`api_version = 1`）

## 环境要求

- Windows 10/11 或 Linux
- [Lua 5.4](https://www.lua.org/download.html)（`lua.exe` / `lua5.4` 在 `PATH`，或设置 `LUA` 环境变量）
- `curl`
- Java：1.21.x 需要 Java 21+；1.12.2 需要 Java 8（用 `--java` 指定）
- Windows PowerShell（仅 Windows 浏览器回调登录使用；Linux 用 `login --device-code`）
- Linux 解压 legacy natives 需要 `unzip`（或 `python3`）

## 快速开始

```bat
:: 查看可下载版本
kaminec.bat versions

:: 只生成启动计划（JSON）
kaminec.bat plan 1.21.8 --dir .minecraft --out plan.json

:: 下载客户端、库、资源
kaminec.bat download 1.21.8 --dir .minecraft

:: 离线启动
kaminec.bat launch 1.21.8 --dir .minecraft --name Steve

:: 已有本地实例：完全离线
kaminec.bat launch 1.20.1-forge-47.3.0 --dir <实例目录> --offline --name Steve
```

Java 路径可用 `--java "C:\Path\To\java.exe"` 指定；不指定时使用 `PATH` 里的 `java`。

Linux：

```sh
./kaminec.sh versions
./kaminec.sh plan 1.21.8 --dir .minecraft --out plan.json
./kaminec.sh download 1.21.8 --dir .minecraft
./kaminec.sh launch 1.21.8 --dir .minecraft --name Steve
```

## 登录

三种方式：

1. **离线账号**：`--name Steve`，不需要网络。
2. **从官方启动器导入**：读取官方启动器保存的短命 access token，约 24 小时有效：
   ```bat
   kaminec.bat import --dir .minecraft
   kaminec.bat import --dir .minecraft --yes
   ```
   只支持官方启动器，不扫描其他启动器；不保存 refresh token。
3. **Microsoft OAuth**：需要自己的 Azure 应用 client id：
   ```bat
   :: Windows：浏览器授权 + loopback
   kaminec.bat login --dir .minecraft --client-id <your-client-id>

   :: Linux：自动使用设备码（不需要本地回调服务）
   ./kaminec.sh login --dir .minecraft --client-id <your-client-id>
   ```
   client id 也可以写入 `<实例目录>/msa.json`，或通过 `KAMINEC_MSA_CLIENT_ID` 环境变量提供。

> 本项目不内置任何 Azure client id。自己的应用如果尚未获得 Minecraft API 批准，`login_with_xbox` 会返回 403；此时请使用离线账号或官方启动器导入。

`login --live` 是早期实验路径，当前不可用（Xbox Live 返回 401）。

## 安全说明

- 登录 token 以明文保存在 `<实例目录>/accounts.json`，只用于本机启动。
- 不要把 `accounts.json`、`msa.json`、`run.bat` / `run.sh` 提交到仓库或分享给他人。
- 启动命令输出会把 `--accessToken` 脱敏为 `***`，启动脚本在游戏结束后删除。

## 平台

- **Windows 10/11**：完整支持（下载、启动、浏览器 loopback 登录）。
- **Linux**：已在 WSLg 下真实启动 1.21.8（OpenAL / Sound engine 正常）；CLI 下载、离线账号、官方启动器导入、设备码登录可用；CI 有 Ubuntu 测试。
- **macOS**：CI 离线测试与 POSIX 启动脚本测试通过；没有真机启动验证。

浏览器 loopback 登录目前仅 Windows（PowerShell 回调服务）；Linux 的 `login` 会自动使用设备码。

## Profile 与全局设置

launcher 根目录的 `profiles.json` 保存全局 `defaults` 和每个 profile：

```bat
:: 全局缺省值（未在 profile 中覆盖时生效）
kaminec.bat profile defaults --dir .minecraft --java "C:\Java\bin\java.exe" --memory 2G --username Steve

:: 管理 profile
kaminec.bat profile list --dir .minecraft
kaminec.bat profile create 1.21.8 --dir .minecraft --name "Vanilla 1.21.8" --memory 4G
kaminec.bat profile show vanilla-1-21-8 --dir .minecraft
kaminec.bat profile edit vanilla-1-21-8 --dir .minecraft --java "C:\Java\jdk-21\bin\java.exe"
kaminec.bat profile delete vanilla-1-21-8 --dir .minecraft --yes

:: 用 profile 下载/启动
kaminec.bat download --profile vanilla-1-21-8 --dir .minecraft
kaminec.bat launch --profile vanilla-1-21-8 --dir .minecraft

:: 从官方启动器 / CurseForge 导入（只读挂接）
kaminec.bat profile import --from official --dir .minecraft --dry-run
kaminec.bat profile import --from official --dir .minecraft --yes
```

合并顺序：内置默认值 → `defaults` → profile `settings` → CLI 参数。
导入的 profile 标记 `external=true`，只读引用外部实例，删除 profile 不会删除源目录。
第三方启动器（Prism/HMCL/ATLauncher）导入以后放到 `tools/`，不在核心 CLI 内。

## Steam（可选，独立脚本）

Steam 支持不在核心 CLI 里，由独立脚本生成「添加非 Steam 游戏」所需字段：

```bat
:: 普通参数（会显示 Lua 控制台）
lua tools\steam_shortcut.lua --version 1.21.8 --dir .minecraft --java "C:\Java\bin\java.exe"

:: 隐藏窗口（生成 wscript + 隐藏 cmd wrapper，不显示 Lua/Java 终端）
lua tools\steam_shortcut.lua --version 1.21.8 --dir .minecraft --java "C:\Java\bin\java.exe" --hidden

:: 直接写入 Steam（先完全退出 Steam；会备份 shortcuts.vdf）
lua tools\steam_shortcut.lua --version 1.21.8 --dir .minecraft --java "C:\Java\bin\java.exe" --hidden --apply
```

`--apply` 会输出 `Long AppID`，可用
`steam://rungameid/<Long AppID>` 启动；重复执行按名称去重。

输出：

- 名称
- 目标（默认 Lua；`--hidden` 时是 `wscript.exe`）
- 起始位置（实例目录）
- 启动参数（`src/main.lua launch ...` 或生成的 `.vbs`）

Steam → 库 → 添加非 Steam 游戏 → 浏览选择上面的目标，再填入起始位置和启动参数。
`--hidden` 会在实例目录生成 `steam-launch-<版本>.cmd/.vbs`；`--json` 可用于外部工具。

## 目录

```text
src/
  main.lua      CLI 入口
  plugin.lua    可嵌入 API
  util.lua      通用路径/文件/引号工具
  core/         版本解析、规则、参数、库模型
  net/          HTTP、下载、校验、资源、natives
  auth/         Microsoft 登录、回调
  accounts/     账号存储与官方启动器导入
  host/         宿主边界与启动
  vendor/       vendored Lua 库（dkjson）
tests/          离线测试与 fixtures
tools/          开发辅助脚本
kaminec.bat     Windows 入口
kaminec.sh      Linux 入口
```

## 许可

BSD-2-Clause。第三方组件见 `THIRD_PARTY_NOTICES.md`。

本项目不是 Mojang、Microsoft 或 Minecraft 官方项目；Minecraft 是 Mojang Studios 的商标。
