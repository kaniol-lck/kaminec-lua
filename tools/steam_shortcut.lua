-- tools/steam_shortcut.lua: print the fields needed to add a Kaminec-Lua entry
-- to Steam as a non-Steam game. This is deliberately NOT part of src/main.lua.
--
-- Usage:
--   lua tools/steam_shortcut.lua --version 1.21.8 --dir D:/game/.minecraft \
--       --java "C:/Java/bin/java.exe" [--username Steve] [--name "..."] [--json]
--
-- Steam: Library -> Add a Non-Steam Game -> Browse -> select the Lua executable,
-- then paste Target / StartDir / LaunchOptions from this output.

local script = (arg[0] or "tools/steam_shortcut.lua"):gsub("\\", "/")
local tools_dir = script:match("^(.*)/") or "."
local root = tools_dir:match("^(.*)/") or "."
local src = root .. "/src"
package.path = table.concat({
    src .. "/?.lua",
    src .. "/core/?.lua",
    src .. "/net/?.lua",
    src .. "/auth/?.lua",
    src .. "/accounts/?.lua",
    src .. "/host/?.lua",
    src .. "/vendor/?.lua",
}, ";") .. ";" .. package.path

local util = require("util")
local json = require("json")
local adapters = require("adapters")
local planner = require("planner")

local opts = { username = "Steve", dir = ".minecraft" }
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--version" then
        opts.version = arg[i + 1]; i = i + 2
    elseif a == "--dir" then
        opts.dir = arg[i + 1]; i = i + 2
    elseif a == "--java" then
        opts.java = arg[i + 1]; i = i + 2
    elseif a == "--target" then
        opts.target = arg[i + 1]; i = i + 2
    elseif a == "--username" then
        opts.username = arg[i + 1]; i = i + 2
    elseif a == "--name" then
        opts.name = arg[i + 1]; i = i + 2
    elseif a == "--online" then
        opts.online = true; i = i + 1
    elseif a == "--json" then
        opts.json = true; i = i + 1
    elseif a == "--hidden" then
        opts.hidden = true; i = i + 1
    elseif a == "--apply" then
        opts.apply = true; i = i + 1
    elseif a == "--force" then
        opts.force = true; i = i + 1
    elseif a == "--steam-user" then
        opts.steam_user = arg[i + 1]; i = i + 2
    elseif a == "--help" or a == "-h" then
        print("usage: lua tools/steam_shortcut.lua --version <id> --dir <instance> [--java <java>] [--username <name>] [--target <lua>] [--online] [--hidden] [--apply] [--steam-user <id>] [--force] [--json]")
        os.exit(0)
    else
        io.stderr:write("unknown argument: " .. tostring(a) .. "\n")
        os.exit(2)
    end
end

if not opts.version then
    io.stderr:write("--version is required\n")
    os.exit(2)
end

local instance = util.abs(opts.dir)
local ok, plan = pcall(planner.build, adapters.cli(), instance, opts.version, {
    offline = not opts.online,
})
if not ok then
    io.stderr:write("build plan failed: " .. tostring(plan) .. "\n")
    os.exit(1)
end

local target = opts.target or os.getenv("LUA") or arg[-1]
if target and (target:find("[/\\]") ~= nil) then
    target = util.abs(target)
end
if not target or target == "lua" or target == "lua.exe" then
    local probe = util.IS_WINDOWS and "where lua 2>nul"
        or "command -v lua5.4 2>/dev/null || command -v lua 2>/dev/null"
    local f = io.popen(probe)
    local line = f and f:read("l") or nil
    if f then f:close() end
    if line and line ~= "" then
        target = line:gsub("%s+$", "")
    end
end
if not target then
    io.stderr:write("cannot locate Lua; pass --target <path-to-lua>\n")
    os.exit(1)
end

local java = opts.java or "java"
local shortcut_name = opts.name or ("Minecraft " .. opts.version .. " (Kaminec-Lua)")

local function q(s) return util.quote(s) end
local function native_path(p)
    if util.IS_WINDOWS then return (tostring(p):gsub("/", "\\")) end
    return p
end
local repo_root = util.abs(root):gsub("/%./", "/"):gsub("/%.$", "")
local main_script = native_path(util.join(repo_root, "src/main.lua"))
local instance_display = native_path(instance)
local target_display = native_path(target)
local java_display = native_path(java)
local args = { q(main_script), "launch", opts.version, "--dir", q(instance_display) }
if not opts.online then args[#args + 1] = "--offline" end
args[#args + 1] = "--name"; args[#args + 1] = q(opts.username)
if opts.java then args[#args + 1] = "--java"; args[#args + 1] = q(java_display) end
local launch_options = table.concat(args, " ")

-- Optional Windows wrapper: Steam -> wscript.exe -> hidden cmd -> lua -> java.
-- wscript is a GUI-subsystem process, and `Run ..., 0, True` hides the cmd
-- window, so no Lua/Java console is visible. The cmd file contains no token.
local target_display, launch_options_display = target_display, launch_options
local hidden_files
if opts.hidden then
    if not util.IS_WINDOWS then
        io.stderr:write("--hidden is Windows-only (wscript wrapper)\n")
        os.exit(2)
    end
    local safe_version = opts.version:gsub("[^%w%._-]", "_")
    local cmd_path = util.join(instance, "steam-launch-" .. safe_version .. ".cmd")
    local vbs_path = util.join(instance, "steam-launch-" .. safe_version .. ".vbs")
    local lua_target = target_display
    util.write(cmd_path, "@echo off\r\ncd /d " .. q(instance_display) .. "\r\n"
        .. q(lua_target) .. " " .. launch_options .. "\r\n")
    local windir = os.getenv("SystemRoot") or "C:\\Windows"
    local wscript = native_path(windir .. "\\System32\\wscript.exe")
    local vbs = 'Set sh = CreateObject("WScript.Shell")\r\n'
        .. 'sh.Run "cmd /c " & Chr(34) & "' .. native_path(cmd_path):gsub('"', '""') .. '" & Chr(34), 0, True\r\n'
    util.write(vbs_path, vbs)
    hidden_files = { cmd = native_path(cmd_path), vbs = native_path(vbs_path) }
    target_display = wscript
    launch_options_display = q(native_path(vbs_path))
end

local result = {
    name = shortcut_name,
    target = target_display,
    startdir = instance_display,
    launch_options = launch_options_display,
    version = opts.version,
    instance = instance_display,
    username = opts.username,
    hidden = hidden_files ~= nil,
}

local function crc32(s)
    local function table_crc()
        local t = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if (c & 1) ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
            end
            t[i] = c
        end
        return t
    end
    local t = table_crc()
    local c = 0xFFFFFFFF
    for i = 1, #s do c = t[(c ~ s:byte(i)) & 0xFF] ~ (c >> 8) end
    return (~c) & 0xFFFFFFFF
end

local function steam_root()
    local f = io.popen('reg query "HKCU\\Software\\Valve\\Steam" /v SteamPath 2>nul')
    if not f then return nil end
    local out = f:read("a"); f:close()
    local p = out:match("SteamPath%s+REG_SZ%s+([^\r\n]+)")
    return p and p:gsub("\\", "/") or nil
end

local function steam_running()
    local f = io.popen('tasklist /FI "IMAGENAME eq steam.exe" /NH 2>nul')
    if not f then return false end
    local out = f:read("a"); f:close()
    return out:lower():find("steam.exe", 1, true) ~= nil
end

local function apply_shortcut()
    if not util.IS_WINDOWS then error("--apply is Windows-only") end
    if steam_running() and not opts.force then
        error("Steam 正在运行；请先完全退出 Steam（含托盘），或加 --force")
    end
    local root = steam_root()
    if not root then error("找不到 Steam 安装目录") end
    local users = {}
    local f = io.popen('dir /b /ad "' .. root:gsub("/", "\\") .. '\\userdata" 2>nul')
    if f then
        for line in f:lines() do
            if line:match("^%d+$") then users[#users + 1] = line end
        end
        f:close()
    end
    if #users == 0 then error("没有 Steam 用户目录；先登录一次 Steam") end
    local user = opts.steam_user or users[1]
    local path = root .. "/userdata/" .. user .. "/config/shortcuts.vdf"
    local data = util.exists(path) and util.read(path) or ""
    local quoted_exe = '"' .. target_display .. '"'
    local appid = (crc32(quoted_exe .. shortcut_name) | 0x80000000) & 0xFFFFFFFF
    local long_appid = (appid << 32) | 0x02000000
    result.appid = appid
    result.long_appid = long_appid
    result.long_appid_text = string.format("%u", long_appid)
    result.steam_shortcut = path
    result.steam_user = user
    if data:find(shortcut_name .. "\0", 1, true) then
        result.already = true
        return
    end

    local function cs(v) return v .. "\0" end
    local function st(k, v) return "\1" .. cs(k) .. cs(v) end
    local function it(k, v) return "\2" .. cs(k) .. string.pack("<I4", v & 0xFFFFFFFF) end
    local key = "0"
    if data ~= "" then
        local n = 0
        while data:find("\0" .. tostring(n) .. "\0", 1, true) do n = n + 1 end
        key = tostring(n)
    end
    local launch_raw = hidden_files and hidden_files.vbs or launch_options
    local entry = "\0" .. cs(key)
        .. it("appid", appid)
        .. st("AppName", shortcut_name)
        .. st("Exe", quoted_exe)
        .. st("StartDir", instance_display)
        .. st("icon", "")
        .. st("ShortcutPath", "")
        .. st("LaunchOptions", launch_raw)
        .. it("IsHidden", 0)
        .. it("AllowDesktopConfig", 1)
        .. it("AllowOverlay", 1)
        .. it("OpenVR", 0)
        .. it("Devkit", 0)
        .. st("DevkitGameID", "")
        .. it("DevkitOverrideAppID", 0)
        .. it("LastPlayTime", 0)
        .. st("FlatpakAppID", "")
        .. st("sortas", "")
        .. "\0" .. cs("tags") .. "\8"
        .. "\8"
    local new
    if data == "" then
        new = "\0" .. cs("shortcuts") .. entry .. "\8\8"
    else
        new = data:sub(1, -3) .. entry .. data:sub(-2)
    end
    local backup
    if util.exists(path) then
        backup = path .. ".bak-" .. os.date("%Y%m%d-%H%M%S")
        util.write(backup, data)
    end
    local tmp = path .. ".tmp"
    util.write(tmp, new)
    os.remove(path)
    local ok, err = os.rename(tmp, path)
    if not ok then error("写 shortcuts.vdf 失败: " .. tostring(err)) end
    result.backup = backup
end

if opts.apply then
    local ok, err = pcall(apply_shortcut)
    if not ok then
        io.stderr:write("apply failed: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

if opts.json then
    print(json.encode(result))
    os.exit(0)
end

print("Steam 非 Steam 游戏快捷方式参数")
print("")
print("名称:       " .. shortcut_name)
print("目标:       " .. target_display)
print("起始位置:   " .. instance_display)
print("启动参数:   " .. launch_options_display)
if hidden_files then
    print("隐藏窗口:   已生成 " .. hidden_files.cmd)
    print("            和 " .. hidden_files.vbs)
end
if opts.apply then
    print("Steam 配置:  " .. tostring(result.steam_shortcut))
    print("AppID:       " .. tostring(result.appid))
    if result.long_appid_text then
        print("Long AppID:  " .. result.long_appid_text)
    end
    if result.already then
        print("状态:        已存在，未重复添加")
    elseif result.backup then
        print("备份:        " .. result.backup)
    end
end
print("")
if hidden_files then
    print("Steam: 库 -> 添加非 Steam 游戏 -> 浏览 -> 选择上面的 wscript.exe,")
    print("       再把「起始位置」和「启动参数」填进去（启动时不会出现终端窗口）。")
else
    print("Steam: 库 -> 添加非 Steam 游戏 -> 浏览 -> 选择上面的 Lua 可执行文件,")
    print("       再把「起始位置」和「启动参数」填进去。")
end
print("")
if not util.exists(target) then
    print("警告: 目标不存在: " .. target)
end
if opts.java and not util.exists(java) then
    print("警告: Java 路径不存在: " .. java)
end
