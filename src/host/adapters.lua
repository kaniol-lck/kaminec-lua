-- adapters.lua: the host boundary.
-- The CLI implementation uses util + curl; a plugin host (Qt/Python/Rust) can
-- provide its own table with the same functions and pass it to planner.lua.
local util = require("util")
local http = require("http")

local M = {}

local function shell_ok(cmd)
    local ok = os.execute(cmd)
    return ok == true
end

-- cmd.exe has a "command starts with a quote" quirk: it strips the first and
-- last quote, so every command built here starts with an executable name.
local function cmd_quote(path)
    return '"' .. tostring(path):gsub('"', "") .. '"'
end

-- PowerShell single-quoted literal: embedded single quotes are doubled.
local function ps_quote(path)
    return "'" .. tostring(path):gsub("'", "''") .. "'"
end

local function extract_zip(zip, dest)
    util.mkdir(dest)
    if util.IS_WINDOWS then
        -- Windows 10+ ships bsdtar, which reads zip archives.
        local tar_cmd = "tar -xf " .. cmd_quote(zip) .. " -C " .. cmd_quote(dest)
        if shell_ok(tar_cmd) then
            return true
        end
        -- Fallback for hosts without tar/libarchive.
        local ps_cmd = "powershell -NoProfile -NonInteractive -Command \"Expand-Archive -LiteralPath "
            .. ps_quote(zip) .. " -DestinationPath " .. ps_quote(dest) .. " -Force\""
        return shell_ok(ps_cmd)
    end

    -- POSIX: unzip is the common case; bsdtar can read zip on macOS; python3
    -- is a last resort for minimal containers.
    if shell_ok("unzip -q -o " .. util.quote(zip) .. " -d " .. util.quote(dest)) then
        return true
    end
    if shell_ok("tar -xf " .. util.quote(zip) .. " -C " .. util.quote(dest)) then
        return true
    end
    return shell_ok("python3 -m zipfile -e " .. util.quote(zip) .. " " .. util.quote(dest))
end

M.extract_zip = extract_zip

function M.cli()
    return {
        exists = function(path) return util.exists(path) end,
        size = function(path) return util.size(path) end,
        read = function(path) return util.read(path) end,
        write = function(path, data) return util.write(path, data) end,
        mkdir = function(path) return util.mkdir(path) end,
        log = function(msg) print(msg) end,
        fetch = function(url, path, opts) return http.download(url, path, opts) end,
        extract_zip = function(zip, dest) return extract_zip(zip, dest) end,
    }
end

return M
