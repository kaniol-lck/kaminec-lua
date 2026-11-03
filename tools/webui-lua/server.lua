-- tools/webui-lua/server.lua: LuaSocket backend for the shared webui frontend.
-- Requires LuaSocket (`luarocks install luasocket`). Python-free.
--
--   lua tools/webui-lua/server.lua --dir .minecraft --port 8766 --open
--
-- Binds 127.0.0.1 only; API calls require the per-run token. Real work is
-- delegated to the Lua CLI in background jobs; this server never uses a shell
-- for untrusted arguments beyond generated per-job scripts with validated input.

local script = (arg[0] or "tools/webui-lua/server.lua"):gsub("\\", "/")
local webui_dir = script:match("^(.*)/") or "."
-- strip "tools/webui-lua" (two path components) to get the repo root
local parent = webui_dir:match("^(.*)/[^/]+$")
local repo_root = parent and parent:match("^(.*)/[^/]+$") or "."
if repo_root == "" then repo_root = "." end
local src = repo_root .. "/src"
package.path = table.concat({
    src .. "/?.lua", src .. "/core/?.lua", src .. "/net/?.lua",
    src .. "/auth/?.lua", src .. "/accounts/?.lua", src .. "/host/?.lua",
    src .. "/vendor/?.lua", webui_dir .. "/?.lua",
}, ";") .. ";" .. package.path

local socket = require("socket")
local json = require("json")
local util = require("util")

local WEB_DIR = repo_root .. "/tools/webui/public"
local MAIN_LUA = repo_root .. "/src/main.lua"
local JOB_ROOT = nil
local TOKEN = nil
local QUIET = false
local LUA_EXE = nil

local function log(fmt, ...)
    if not QUIET then
        io.stderr:write("[webui-lua] " .. string.format(fmt, ...) .. "\n")
    end
end

local function q(s) return util.quote(tostring(s)) end
local function now() return os.time() end

local function random_token()
    local f = io.open("/dev/urandom", "rb")
    if f then
        local bytes = f:read(24) or ""
        f:close()
        local hex = bytes:gsub(".", function(c)
            return string.format("%02x", string.byte(c))
        end)
        if #hex >= 32 then return hex:sub(1, 32) end
    end
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    local parts = {}
    for i = 1, 8 do parts[i] = string.format("%08x", math.random(0, 0x7fffffff)) end
    return table.concat(parts):sub(1, 32)
end

local function array(t)
    return setmetatable(t or {}, { __jsontype = "array" })
end

local function json_send(client, status, value)
    local body = json.encode(value or {})
    local reason = status == 200 and "OK" or status == 400 and "Bad Request"
        or status == 401 and "Unauthorized" or status == 404 and "Not Found"
        or status == 405 and "Method Not Allowed" or "Error"
    client:send("HTTP/1.1 " .. status .. " " .. reason .. "\r\n"
        .. "Content-Type: application/json; charset=utf-8\r\n"
        .. "Content-Length: " .. #body .. "\r\n"
        .. "Cache-Control: no-store\r\nConnection: close\r\n\r\n" .. body)
end

local function file_send(client, path)
    local f = io.open(path, "rb")
    if not f then json_send(client, 404, { error = "not found" }); return end
    local data = f:read("*a") or ""
    f:close()
    local ctype = "application/octet-stream"
    if path:match("%.html$") then ctype = "text/html; charset=utf-8"
    elseif path:match("%.js$") then ctype = "text/javascript; charset=utf-8"
    elseif path:match("%.css$") then ctype = "text/css; charset=utf-8"
    elseif path:match("%.png$") then ctype = "image/png"
    elseif path:match("%.svg$") then ctype = "image/svg+xml" end
    client:send("HTTP/1.1 200 OK\r\nContent-Type: " .. ctype
        .. "\r\nContent-Length: " .. #data
        .. "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" .. data)
end

local function url_decode(s)
    return (tostring(s):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end):gsub("+", " "))
end

local function parse_query(path)
    local query = path:match("%?(.+)$") or ""
    local out = {}
    for key, value in query:gmatch("([^&=]+)=([^&]*)") do
        out[url_decode(key)] = url_decode(value)
    end
    return out
end

local function parse_headers(client)
    local headers = {}
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local key, value = line:match("^([^:]+):%s*(.*)$")
        if key then headers[key:lower()] = value end
    end
    return headers
end

local function read_body(client, headers)
    local n = tonumber(headers["content-length"] or "0") or 0
    if n <= 0 then return "" end
    if n > 64 * 1024 then return "" end
    return client:receive(n) or ""
end

local function token_ok(client, headers, query)
    local supplied = headers["x-webui-token"] or query.token or ""
    return supplied == TOKEN
end

local function valid_profile_id(id)
    return type(id) == "string" and id:match("^[A-Za-z0-9._-]+$") ~= nil
end

local function valid_version(v)
    return type(v) == "string" and v:match("^[A-Za-z0-9._+-]+$") ~= nil
end

local function load_state(root)
    local path = util.join(root, "profiles.json")
    if not util.exists(path) then
        return { root = root, profiles = array({}), error = "profiles.json not found" }
    end
    local ok, data = pcall(json.decode, util.read(path))
    if not ok or type(data) ~= "table" then
        return { root = root, profiles = array({}), error = "invalid profiles.json" }
    end
    local profiles = array({})
    for pid, profile in pairs(data.profiles or {}) do
        if type(profile) == "table" then
            profiles[#profiles + 1] = {
                id = pid,
                name = profile.name or pid,
                version = profile.version or "",
                root = profile.root or root,
                game_dir = profile.game_dir or "",
                external = profile.external == true,
                settings = profile.settings or {},
            }
        end
    end
    table.sort(profiles, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return { root = root, profiles = profiles }
end

local function find_profile(root, id)
    local state = load_state(root)
    for _, p in ipairs(state.profiles) do
        if p.id == id then return p end
    end
    return nil
end

local function read_lines(path, max)
    if not util.exists(path) then return array({}) end
    local out = array({})
    local n = 0
    for line in util.read(path):gmatch("[^\r\n]+") do
        n = n + 1
        out[n] = line
    end
    local start = math.max(1, n - (max or 500) + 1)
    local trimmed = array({})
    for i = start, n do trimmed[#trimmed + 1] = out[i] end
    return trimmed
end

local function job_status(id)
    local dir = util.join(JOB_ROOT, id)
    local done = util.join(dir, "done")
    local logpath = util.join(dir, "output.log")
    local started = util.join(dir, "started")
    local status, code = "running", nil
    if util.exists(done) then
        local text = (util.read(done) or ""):gsub("%s+", "")
        code = tonumber(text) or -1
        status = code == 0 and "done" or "failed"
    elseif not util.exists(started) then
        status = "failed"
        code = -1
    end
    local began = tonumber(util.read(started) or "") or now()
    return {
        status = status,
        returncode = code,
        error = nil,
        elapsed = math.max(0, now() - began),
        output = read_lines(logpath, 500),
    }
end

local function shell_quote_script(value)
    -- POSIX single-quote, used only in generated .sh files.
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function spawn_job(args)
    local id = string.format("%x%x", now(), math.random(0, 0xffffff))
    local dir = util.join(JOB_ROOT, id)
    util.mkdir(dir)
    local logpath = util.join(dir, "output.log")
    local done = util.join(dir, "done")
    local started = util.join(dir, "started")
    util.write(started, tostring(now()) .. "\n")
    local lua = LUA_EXE or os.getenv("LUA") or arg[-1]
        or (util.IS_WINDOWS and "lua.exe" or "lua5.4")
    local command = { lua, MAIN_LUA }
    for _, a in ipairs(args) do command[#command + 1] = a end

    if util.IS_WINDOWS then
        local bat = util.join(dir, "run.bat")
        local lines = {
            "@echo off",
            "cd /d " .. q(repo_root),
        }
        local parts = {}
        for _, a in ipairs(command) do parts[#parts + 1] = q(a) end
        lines[#lines + 1] = table.concat(parts, " ") .. " > " .. q(logpath) .. " 2>&1"
        lines[#lines + 1] = "echo %errorlevel% > " .. q(done)
        util.write(bat, table.concat(lines, "\r\n") .. "\r\n")
        -- `start` returns immediately; the generated bat writes the exit code.
        os.execute('start "" /b cmd /c ' .. q(bat))
    else
        local sh = util.join(dir, "run.sh")
        local lines = {
            "#!/bin/sh",
            "cd " .. shell_quote_script(repo_root),
        }
        local parts = {}
        for _, a in ipairs(command) do parts[#parts + 1] = shell_quote_script(a) end
        lines[#lines + 1] = table.concat(parts, " ") .. " > " .. shell_quote_script(logpath) .. " 2>&1"
        lines[#lines + 1] = "echo $? > " .. shell_quote_script(done)
        util.write(sh, table.concat(lines, "\n") .. "\n")
        os.execute("sh " .. shell_quote_script(sh) .. " >/dev/null 2>&1 &")
    end
    return id
end

local function handle_client(client, root)
    client:settimeout(3)
    local request = client:receive("*l")
    if not request then return end
    local method, target = request:match("^(%S+)%s+(%S+)")
    if not method or not target then return end
    local headers = parse_headers(client)
    local body = read_body(client, headers)
    local path, query = target, parse_query(target)
    path = path:gsub("%?.*$", "")
    local is_api = path:sub(1, 5) == "/api/"

    if is_api and not token_ok(client, headers, query) then
        json_send(client, 401, { error = "invalid token" })
        return
    end

    if method == "GET" then
        if path == "/" or path == "/index.html" then
            file_send(client, WEB_DIR .. "/index.html")
            return
        end
        if path == "/api/state" then
            json_send(client, 200, load_state(root)); return
        end
        if path == "/api/java" then
            local id = spawn_job({ "java", "list" })
            json_send(client, 200, { job = id }); return
        end
        if path:match("^/api/jobs/") then
            local id = path:match("^/api/jobs/([^/]+)$")
            if not id or not id:match("^[0-9a-fA-F]+$") then
                json_send(client, 404, { error = "job not found" }); return
            end
            json_send(client, 200, job_status(id)); return
        end
        local relative = path:gsub("^/", "")
        if relative ~= "" and not relative:find("%.%.") and not relative:find("\\") then
            file_send(client, WEB_DIR .. "/" .. relative)
            return
        end
        json_send(client, 404, { error = "not found" }); return
    end

    if method == "POST" then
        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= "table" then data = {} end
        if path == "/api/action" then
            local action, pid = data.action, data.profile
            if action ~= "download" and action ~= "launch" then
                json_send(client, 400, { error = "action must be download or launch" }); return
            end
            if not valid_profile_id(pid) then
                json_send(client, 400, { error = "invalid profile id" }); return
            end
            if not find_profile(root, pid) then
                json_send(client, 404, { error = "unknown profile" }); return
            end
            local id = spawn_job({ action, "--profile", pid, "--dir", root })
            json_send(client, 200, { job = id }); return
        end
        if path == "/api/profile" then
            local version, name = data.version, data.name
            if not valid_version(version) then
                json_send(client, 400, { error = "invalid version" }); return
            end
            local args = { "profile", "create", version, "--dir", root, "--java-auto" }
            if type(name) == "string" and name ~= "" then
                table.insert(args, "--name"); table.insert(args, name)
            end
            local id = spawn_job(args)
            json_send(client, 200, { job = id }); return
        end
        json_send(client, 404, { error = "not found" }); return
    end

    json_send(client, 405, { error = "method not allowed" })
end

local function parse_args()
    local opts = { dir = ".minecraft", port = 8766, open = false, quiet = false }
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--dir" then opts.dir = arg[i + 1]; i = i + 2
        elseif a == "--port" then opts.port = tonumber(arg[i + 1]) or 8766; i = i + 2
        elseif a == "--token" then opts.token = arg[i + 1]; i = i + 2
        elseif a == "--lua" then opts.lua = arg[i + 1]; i = i + 2
        elseif a == "--open" then opts.open = true; i = i + 1
        elseif a == "--quiet" then opts.quiet = true; i = i + 1
        elseif a == "--help" or a == "-h" then
            print("usage: lua tools/webui-lua/server.lua --dir <root> [--port 8766] [--token t] [--lua path] [--open] [--quiet]")
            os.exit(0)
        else
            io.stderr:write("unknown argument: " .. tostring(a) .. "\n")
            os.exit(2)
        end
    end
    return opts
end

local function main()
    local opts = parse_args()
    if not util.exists(MAIN_LUA) then
        io.stderr:write("src/main.lua not found: " .. MAIN_LUA .. "\n")
        os.exit(1)
    end
    local root = util.abs(opts.dir)
    if not util.isdir(root) then
        io.stderr:write("launcher root not found: " .. root .. "\n")
        os.exit(1)
    end
    JOB_ROOT = util.join(root, ".webui-jobs")
    util.mkdir(JOB_ROOT)
    TOKEN = opts.token or random_token()
    QUIET = opts.quiet
    LUA_EXE = opts.lua or arg[-1] or os.getenv("LUA")
        or (util.IS_WINDOWS and "lua.exe" or "lua5.4")

    local server, err = socket.bind("127.0.0.1", opts.port)
    if not server then
        io.stderr:write("bind failed: " .. tostring(err) .. "\n")
        os.exit(1)
    end
    server:settimeout(1)
    local url = string.format("http://127.0.0.1:%d/?token=%s", opts.port, TOKEN)
    print("Kaminec-Lua WebUI (LuaSocket)")
    print("  root:  " .. root)
    print("  url:   " .. url)
    print("  bind:  127.0.0.1 only; Ctrl+C to stop")
    if opts.open then
        local mac = not util.IS_WINDOWS and (os.getenv("OSTYPE") or ""):lower():find("darwin") ~= nil
        if util.IS_WINDOWS then
            os.execute('start "" ' .. q(url))
        elseif mac then
            os.execute("open " .. q(url))
        else
            os.execute("xdg-open " .. q(url) .. " >/dev/null 2>&1")
        end
    end
    while true do
        local client = server:accept()
        if client then
            local ok, err2 = pcall(handle_client, client, root)
            if not ok then log("request error: %s", tostring(err2)) end
            client:close()
        end
    end
end

main()
