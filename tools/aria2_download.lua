-- tools/aria2_download.lua: optional external aria2c downloader.
-- The core launcher stays curl-only; this tool exports a task list with the
-- core CLI, runs aria2c, then lets the core verify/repair the result.
--
--   lua tools/aria2_download.lua --version 1.21.8 --dir .minecraft --jobs 16
--   lua tools/aria2_download.lua --profile steamprof --dir .minecraft --export-only

local script = (arg[0] or "tools/aria2_download.lua"):gsub("\\", "/")
local tools_dir = script:match("^(.*)/") or "."
local root_dir = tools_dir:match("^(.*)/") or "."
local src = root_dir .. "/src"
package.path = table.concat({
    src .. "/?.lua", src .. "/core/?.lua", src .. "/net/?.lua",
    src .. "/auth/?.lua", src .. "/accounts/?.lua", src .. "/host/?.lua",
    src .. "/vendor/?.lua",
}, ";") .. ";" .. package.path

local util = require("util")
local json = require("json")

local opts = { jobs = 16, dir = ".minecraft" }
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--version" then opts.version = arg[i + 1]; i = i + 2
    elseif a == "--profile" then opts.profile = arg[i + 1]; i = i + 2
    elseif a == "--dir" then opts.dir = arg[i + 1]; i = i + 2
    elseif a == "--jobs" then opts.jobs = tonumber(arg[i + 1]) or 16; i = i + 2
    elseif a == "--tasks" then opts.tasks = arg[i + 1]; i = i + 2
    elseif a == "--aria2" then opts.aria2 = arg[i + 1]; i = i + 2
    elseif a == "--export-only" then opts.export_only = true; i = i + 1
    elseif a == "--no-verify" then opts.no_verify = true; i = i + 1
    elseif a == "--help" or a == "-h" then
        print("usage: lua tools/aria2_download.lua (--version <id> | --profile <id>) --dir <root> [--jobs N] [--export-only] [--no-verify] [--tasks file] [--aria2 path]")
        os.exit(0)
    else
        io.stderr:write("unknown argument: " .. a .. "\n"); os.exit(2)
    end
end
if not opts.version and not opts.profile then
    io.stderr:write("--version or --profile is required\n"); os.exit(2)
end

local root = util.abs(opts.dir)
local tasks = opts.tasks and util.abs(opts.tasks) or util.join(root, "aria2-tasks.txt")
local meta = util.join(root, "aria2-tasks.json")
local lua = os.getenv("LUA") or arg[-1] or "lua"
local main = util.join(root_dir, "src/main.lua")
local function q(s) return util.quote(s) end

local export = lua .. " " .. main .. " download"
if opts.profile then
    export = export .. " --profile " .. q(opts.profile)
else
    export = export .. " " .. q(opts.version)
end
export = export .. " --dir " .. q(root) .. " --export-aria2 " .. q(tasks)
    .. " --export-json " .. q(meta)
local ok = os.execute(export)
if not (ok == true or ok == 0) then
    io.stderr:write("export failed\n"); os.exit(1)
end

local count = 0
if util.exists(meta) then
    local data = json.decode(util.read(meta))
    count = #(data.tasks or {})
end
print(string.format("exported %d task(s): %s", count, tasks))
if opts.export_only then return end

local aria2 = opts.aria2 or os.getenv("ARIA2C")
if not aria2 or aria2 == "" then
    local probe = util.IS_WINDOWS and "where aria2c 2>nul"
        or "command -v aria2c 2>/dev/null"
    local f = io.popen(probe)
    aria2 = f and f:read("l") or nil
    if f then f:close() end
end
if not aria2 or aria2 == "" then
    io.stderr:write("aria2c not found; install it or pass --aria2 <path>; task list kept at " .. tasks .. "\n")
    os.exit(1)
end

local cmd = q(aria2) .. " -i " .. q(tasks) .. " -j " .. tostring(math.max(1, opts.jobs))
    .. " -c --file-allocation=none --check-integrity=true --auto-file-renaming=false"
local proxy = os.getenv("KAMINEC_PROXY") or os.getenv("HTTPS_PROXY") or os.getenv("HTTP_PROXY")
if proxy and proxy ~= "" then cmd = cmd .. " --all-proxy=" .. q(proxy) end
print("running aria2c ...")
local code = os.execute(cmd)
print(string.format("aria2c exit: %s", tostring(code)))

-- remove aria2 control files before verify
if util.IS_WINDOWS then
    os.execute('del /s /q "' .. root:gsub("/", "\\") .. '\\*.aria2" 2>nul')
else
    os.execute("find " .. q(root) .. " -name '*.aria2' -delete 2>/dev/null")
end

if opts.no_verify then return end
local verify = lua .. " " .. main .. " download"
if opts.profile then
    verify = verify .. " --profile " .. q(opts.profile)
else
    verify = verify .. " " .. q(opts.version)
end
verify = verify .. " --dir " .. q(root) .. " --verify --repair"
local vok = os.execute(verify)
if not (vok == true or vok == 0) then
    io.stderr:write("verify/repair failed\n"); os.exit(1)
end
print("done")
