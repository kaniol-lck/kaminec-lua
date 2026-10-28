-- tools/server.lua: minimal vanilla Minecraft server create/download/start/stop.
-- L1/L2 only; modded server installers are out of scope.
local script = (arg[0] or "tools/server.lua"):gsub("\\", "/")
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
local http = require("http")

local M = {}
local args = arg

local function q(s) return util.quote(s) end
local function die(msg) io.stderr:write(tostring(msg) .. "\n"); os.exit(1) end
local function read_json(path)
    if not util.exists(path) then return nil end
    local ok, v = pcall(json.decode, util.read(path))
    if not ok then return nil end
    return v
end

local function config_path(dir) return util.join(dir, "server.json") end
local function pid_path(dir) return util.join(dir, "server.pid") end
local function log_path(dir) return util.join(dir, "logs", "latest.log") end

local function load(dir)
    local cfg = read_json(config_path(dir))
    if not cfg then die("server.json not found; run: server create <version> --dir <dir>") end
    return cfg
end

local function save(dir, cfg) util.write(config_path(dir), json.encode(cfg) .. "\n") end

local function ensure_server_jar(dir, cfg)
    local jar = util.join(dir, "server.jar")
    if util.exists(jar) then return jar end
    die("server.jar missing; run: server download --dir " .. dir)
end

local function eula_ok(dir)
    local path = util.join(dir, "eula.txt")
    if not util.exists(path) then return false end
    return util.read(path):match("eula%s*=%s*true") ~= nil
end

local function cmd_create(rest, opts)
    local version = rest[2]
    if not version then die("usage: server create <version> --dir <dir>") end
    local dir = util.abs(opts.dir or ("servers/" .. version))
    util.mkdir(dir)
    local password = opts["rcon-password"] or ("kaminec-" .. tostring(math.random(100000, 999999)))
    local cfg = {
        version = version,
        java = opts.java or "java",
        memory = opts.memory or "2G",
        port = tonumber(opts.port) or 25565,
        rcon_port = tonumber(opts["rcon-port"]) or 25575,
        rcon_password = password,
        accept_eula = opts["accept-eula"] or false,
    }
    save(dir, cfg)
    util.write(util.join(dir, "eula.txt"),
        "# By changing the setting below to TRUE you are indicating your agreement to the Minecraft EULA.\n"
        .. "eula=" .. (cfg.accept_eula and "true" or "false") .. "\n")
    local properties = util.join(dir, "server.properties")
    if not util.exists(properties) then
        util.write(properties, table.concat({
            "server-port=" .. cfg.port,
            "motd=Kaminec server",
            "online-mode=true",
            "enable-rcon=true",
            "rcon.port=" .. cfg.rcon_port,
            "rcon.password=" .. cfg.rcon_password,
            "broadcast-rcon-to-ops=true",
            "max-players=20",
            "level-name=world",
        }, "\n") .. "\n")
    end
    print("created server at " .. dir)
    print("  version: " .. version)
    print("  eula:    " .. (cfg.accept_eula and "accepted" or "NOT accepted (edit eula.txt or rerun with --accept-eula)"))
    print("  rcon:    " .. cfg.rcon_port)
end

local function get_json(url)
    local status, body = http.get_json(url)
    if status ~= 200 then die("HTTP " .. tostring(status) .. " for " .. url) end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then die("invalid JSON: " .. url) end
    return data
end

local function cmd_download(opts)
    local dir = util.abs(opts.dir or ".")
    local cfg = load(dir)
    local manifest = get_json("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
    local entry
    for _, v in ipairs(manifest.versions or {}) do
        if v.id == cfg.version then entry = v; break end
    end
    if not entry then die("version not found in manifest: " .. cfg.version) end
    local meta = get_json(entry.url)
    local server = meta.downloads and meta.downloads.server
    if not server or not server.url then die("version json has no downloads.server") end
    local jar = util.join(dir, "server.jar")
    print("downloading server.jar ...")
    http.download(server.url, jar, { sha1 = server.sha1 })
    util.write(util.join(dir, "version.json"), json.encode(meta) .. "\n")
    print("server.jar: " .. jar)
end

local function is_running(dir)
    local path = pid_path(dir)
    if not util.exists(path) then return false, nil end
    local pid = (util.read(path):gsub("%s+", ""))
    if pid == "" then return false, nil end
    if util.IS_WINDOWS then
        local f = io.popen('tasklist /FI "PID eq ' .. pid .. '" /NH 2>nul')
        local out = f and f:read("a") or ""
        if f then f:close() end
        return out:find(pid, 1, true) ~= nil, pid
    end
    local ok = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    return ok == true or ok == 0, pid
end

local function java_arg_list(cfg, jar)
    return { "-Xmx" .. cfg.memory, "-jar", jar, "nogui" }
end

local function java_args(cfg, jar)
    local quoted = {}
    for _, a in ipairs(java_arg_list(cfg, jar)) do quoted[#quoted + 1] = q(a) end
    return table.concat(quoted, " ")
end

local function ps_quote(s)
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function start_background(dir, cfg, jar)
    util.mkdir(util.join(dir, "logs"))
    local log = log_path(dir)
    if util.IS_WINDOWS then
        local ps = util.join(dir, "run.ps1")
        local arg_lines = {}
        for _, a in ipairs(java_arg_list(cfg, jar)) do
            arg_lines[#arg_lines + 1] = ps_quote(a)
        end
        local script = table.concat({
            "$ErrorActionPreference='Stop'",
            "$args = @(" .. table.concat(arg_lines, ", ") .. ")",
            "$p = Start-Process -FilePath " .. ps_quote(cfg.java) .. " -ArgumentList $args"
                .. " -WorkingDirectory " .. ps_quote(dir)
                .. " -RedirectStandardOutput " .. ps_quote(log)
                .. " -RedirectStandardError " .. ps_quote(log .. ".err")
                .. " -WindowStyle Hidden -PassThru",
            "$p.Id | Set-Content " .. ps_quote(pid_path(dir)),
        }, "\r\n") .. "\r\n"
        util.write(ps, script)
        local ok = os.execute('powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' .. q(ps))
        if not (ok == true or ok == 0) then die("failed to start server") end
    else
        local cmd = "nohup " .. q(cfg.java) .. " " .. java_args(cfg, jar)
            .. " > " .. q(log) .. " 2>&1 & echo $! > " .. q(pid_path(dir))
        os.execute(cmd)
    end
    util.sleep(2)
end

local function cmd_start(opts)
    local dir = util.abs(opts.dir or ".")
    local cfg = load(dir)
    if not eula_ok(dir) then
        die("eula.txt is not accepted; edit it or rerun create with --accept-eula")
    end
    local jar = ensure_server_jar(dir, cfg)
    if is_running(dir) then die("server already running") end
    if opts.foreground then
        local ok = os.execute(q(cfg.java) .. " " .. java_args(cfg, jar))
        os.exit(ok == true or ok == 0 and 0 or 1)
    end
    start_background(dir, cfg, jar)
    print("started server (pid " .. tostring(util.exists(pid_path(dir)) and util.read(pid_path(dir)) or "?") .. ")")
    print("log: " .. log_path(dir))
end

local function rcon_command(cfg, command)
    if util.IS_WINDOWS then
        local helper = util.join(root_dir, "tools/rcon.ps1")
        return os.execute("powershell.exe -NoProfile -ExecutionPolicy Bypass -File " .. q(helper)
            .. " -HostName 127.0.0.1 -Port " .. tostring(cfg.rcon_port)
            .. " -Password " .. q(cfg.rcon_password) .. " -Command " .. q(command))
    end
    local helper = util.join(root_dir, "tools/rcon.py")
    return os.execute("python3 " .. q(helper) .. " 127.0.0.1 " .. tostring(cfg.rcon_port)
        .. " " .. q(cfg.rcon_password) .. " " .. q(command))
end

local function cmd_stop(opts)
    local dir = util.abs(opts.dir or ".")
    local cfg = load(dir)
    local running, pid = is_running(dir)
    if not running then print("server is not running"); return end
    local ok = rcon_command(cfg, "stop")
    if not (ok == true or ok == 0) then
        if opts.force then
            if util.IS_WINDOWS then os.execute("taskkill /PID " .. pid .. " /F >nul 2>&1")
            else os.execute("kill -9 " .. pid) end
            print("RCON failed; force-killed pid " .. tostring(pid))
        else
            die("RCON stop failed; enable rcon or use --force")
        end
    end
    for _ = 1, 30 do
        local still = is_running(dir)
        if not still then break end
        util.sleep(1)
    end
    util.rmtree(pid_path(dir))
    print("server stopped")
end

local function cmd_status(opts)
    local dir = util.abs(opts.dir or ".")
    local running, pid = is_running(dir)
    print(running and ("running (pid " .. tostring(pid) .. ")") or "stopped")
end

local function cmd_log(opts)
    local dir = util.abs(opts.dir or ".")
    local path = log_path(dir)
    if not util.exists(path) then print("(no log)"); return end
    local lines = {}
    for line in util.read(path):gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    local n = tonumber(opts.lines) or 40
    local start = math.max(1, #lines - n + 1)
    for i = start, #lines do print(lines[i]) end
end

local function cmd_backup(opts)
    local dir = util.abs(opts.dir or ".")
    local running = is_running(dir)
    if running then die("stop the server before backup (safe world copy)") end
    local world = util.join(dir, "world")
    if not util.isdir(world) then die("world directory not found: " .. world) end
    local backup_dir = util.join(dir, "backups")
    util.mkdir(backup_dir)
    local name = "world-" .. os.date("%Y%m%d-%H%M%S") .. ".tar.gz"
    local target = util.join(backup_dir, name)
    local ok = os.execute("tar -czf " .. q(target) .. " -C " .. q(dir) .. " world")
    if not (ok == true or ok == 0) then die("backup failed") end
    print("backup: " .. target)
end

local function cmd_eula(opts)
    local dir = util.abs(opts.dir or ".")
    local cfg = load(dir)
    cfg.accept_eula = true
    save(dir, cfg)
    util.write(util.join(dir, "eula.txt"), "eula=true\n")
    print("eula accepted")
end

local function main()
    local opts = {}
    local rest = {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a:sub(1, 2) == "--" then
            local key = a:sub(3)
            local nxt = args[i + 1]
            if nxt and nxt:sub(1, 2) ~= "--" then opts[key] = nxt; i = i + 2
            else opts[key] = true; i = i + 1 end
        else
            rest[#rest + 1] = a; i = i + 1
        end
    end
    local cmd = rest[1]
    if cmd == "create" then cmd_create(rest, opts)
    elseif cmd == "download" then cmd_download(opts)
    elseif cmd == "start" then cmd_start(opts)
    elseif cmd == "stop" then cmd_stop(opts)
    elseif cmd == "status" then cmd_status(opts)
    elseif cmd == "log" then cmd_log(opts)
    elseif cmd == "backup" then cmd_backup(opts)
    elseif cmd == "eula" then cmd_eula(opts)
    else
        print("usage: lua tools/server.lua <create|download|start|stop|status|log|backup|eula> --dir <server-dir>")
        print("  create <version> --dir ... [--accept-eula] [--port 25565] [--rcon-port 25575]")
        print("  start --dir ... [--foreground]")
        print("  stop --dir ... [--force]")
    end
end

main()
