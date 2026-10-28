# Changelog

本项目从 0.1.0 开始记录。格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 SemVer。

## [0.1.0] - 2026-10-28

### Added

- Lua 5.4 CLI：`versions` / `plan` / `download` / `launch`
- 现代 version json：rules、arguments、classifier、Maven `url`、asset index
- Forge / NeoForge / Fabric 本地实例启动；Forge 1.12.2 legacy 格式
- SHA1 校验、`.part` 断点续传、`--repair` / `--verify`
- 下载任务导出：aria2 input / JSON；`tools/aria2_download.lua` 可选外置下载
- 服务端 L1/L2 工具：create/download/start/status/log/RCON stop/backup
- 离线账号、官方启动器 token 导入、Microsoft OAuth 浏览器登录
- 可嵌入的插件 API（`api_version = 1`）
- Profile 层：全局 defaults、profile CRUD、`--profile` 下载/启动
- `profile create --from-existing`：只读挂接已有实例/版本目录
- 从官方启动器 / CurseForge 导入 profile（external 只读挂接）
- Linux 支持：平台抽象、`kaminec.sh`、`run.sh`、`login` 自动设备码
- Linux 真实启动验证（WSLg + OpenAL，1.21.8 到主菜单）
- POSIX 启动链路测试（fake java 验证 `run.sh`）
- CI：Windows + Ubuntu + macOS，Lua 5.4
- 回调页成功/失败两态与基础样式

### Fixed

- Windows 下 `cmd.exe` 引号与工作目录问题
- 资源下载路径中的反斜杠转义问题
- 回调页 UTF-8 乱码
- 启动命令/计划输出中的 access token 脱敏

### Known limitations

- 仅支持 Windows
- 微软登录需要自己的 Azure client id；新应用需 Minecraft API 审核
- `login --live` 不可用（Xbox Live 401）
- 不自动下载/管理 Java，需用户提供 `--java` 或 PATH 中的 `java`
