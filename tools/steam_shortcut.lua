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
    elseif a == "--help" or a == "-h" then
        print("usage: lua tools/steam_shortcut.lua --version <id> --dir <instance> [--java <java>] [--username <name>] [--target <lua>] [--online] [--hidden] [--json]")
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
