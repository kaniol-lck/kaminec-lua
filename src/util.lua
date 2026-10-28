-- util.lua: cross-platform filesystem + shell helpers (no C modules).
-- Windows keeps the existing cmd.exe/PowerShell behavior; POSIX uses sh.
local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
M.IS_WINDOWS = IS_WINDOWS
M.path_separator = IS_WINDOWS and ";" or ":"

function M.join(...)
    local parts = { ... }
    local out = {}
    for _, p in ipairs(parts) do
        if p and p ~= "" then
            -- curl config files treat '\' as an escape character, so every path
            -- handed to a child process uses forward slashes on both platforms
            local s = tostring(p):gsub("\\", "/")
            if #out == 0 then
                out[#out + 1] = s:gsub("[/]+$", "")
            else
                out[#out + 1] = s:gsub("^[/]+", ""):gsub("[/]+$", "")
            end
        end
    end
    return table.concat(out, "/")
end

function M.exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

-- Directories do not open with io.open on Windows; use the shell.
function M.isdir(path)
    path = tostring(path)
    local cmd
    if IS_WINDOWS then
        cmd = 'if exist "' .. path:gsub("/", "\\") .. '\\*" (echo 1) else (echo 0)'
    else
        cmd = "test -d " .. M.quote(path) .. " && echo 1 || echo 0"
    end
    local f = io.popen(cmd)
    local s = f and f:read("l") or "0"
    if f then f:close() end
    return s:gsub("%s+$", "") == "1"
end

function M.size(path)
    local f = io.open(path, "rb")
    if not f then return -1 end
    local s = f:seek("end")
    f:close()
    return s
end

function M.read(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local data = f:read("a")
    f:close()
    return data
end

function M.write(path, data)
    M.mkdir(M.dirname(path))
    local f = assert(io.open(path, "wb"), "cannot write " .. path)
    f:write(data)
    f:close()
end

-- PowerShell/cmd and POSIX shells need different quoting.
function M.quote(s)
    s = tostring(s)
    if IS_WINDOWS then
        return '"' .. s:gsub('"', '\\"') .. '"'
    end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.mkdir(path)
    path = tostring(path)
    if IS_WINDOWS then
        path = path:gsub("/", "\\")
        os.execute('mkdir "' .. path .. '" 2>nul')
    else
        os.execute("mkdir -p " .. M.quote(path) .. " 2>/dev/null")
    end
end

function M.rmtree(path)
    path = tostring(path)
    if IS_WINDOWS then
        os.execute('rmdir /s /q "' .. path:gsub("/", "\\") .. '" 2>nul')
    else
        os.execute("rm -rf " .. M.quote(path) .. " 2>/dev/null")
    end
end

function M.dirname(path)
    return (tostring(path):match("^(.*)[/\\][^/\\]*$")) or "."
end

function M.cwd()
    local f = io.popen(IS_WINDOWS and "cd" or "pwd")
    local s = f:read("l") or "."
    f:close()
    return (s:gsub("%s+$", ""))
end

-- absolute, forward-slash path
function M.abs(path)
    path = tostring(path)
    if IS_WINDOWS then
        if path:match("^%a:[/\\]") or path:match("^\\\\") then
            return (path:gsub("\\", "/"))
        end
    else
        if path:sub(1, 1) == "/" then
            return path
        end
        if path:sub(1, 2) == "~/" then
            path = (os.getenv("HOME") or ".") .. path:sub(2)
        end
    end
    return M.join(M.cwd(), path)
end

function M.basename(path)
    return (tostring(path):match("([^/\\]+)$")) or path
end

function M.sleep(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds == 0 then return end
    if IS_WINDOWS then
        os.execute("ping -n " .. tostring(seconds + 1) .. " 127.0.0.1 >nul")
    else
        os.execute("sleep " .. tostring(seconds))
    end
end

function M.printf(fmt, ...)
    print(string.format(fmt, ...))
end

function M.now()
    return os.time()
end

return M
