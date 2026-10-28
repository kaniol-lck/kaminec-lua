-- util.lua: filesystem + shell helpers (Windows-first, no C modules)
local M = {}

function M.join(...)
    local parts = { ... }
    local out = {}
    for _, p in ipairs(parts) do
        if p and p ~= "" then
            -- normalize Windows separators: curl config files treat '\' as an
            -- escape character, so every path we hand to a child process must
            -- use forward slashes
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

function M.mkdir(path)
    path = tostring(path):gsub("/", "\\")
    os.execute('mkdir "' .. path .. '" 2>nul')
end

function M.dirname(path)
    return (tostring(path):match("^(.*)[/\\][^/\\]*$")) or "."
end

function M.cwd()
    local f = io.popen("cd")
    local s = f:read("l") or "."
    f:close()
    return (s:gsub("%s+$", ""))
end

-- absolute, forward-slash path
function M.abs(path)
    path = tostring(path)
    if path:match("^%a:[/\\]") then
        return (path:gsub("\\", "/"))
    end
    return M.join(M.cwd(), path)
end

function M.basename(path)
    return (tostring(path):match("([^/\\]+)$")) or path
end

function M.quote(s)
    return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

function M.printf(fmt, ...)
    print(string.format(fmt, ...))
end

function M.now()
    return os.time()
end

return M
