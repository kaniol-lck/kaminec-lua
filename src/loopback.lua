-- loopback.lua: local HTTP callback for the browser OAuth flow.
-- Uses the built-in Windows PowerShell TcpListener so the CLI needs no extra
-- runtime; hosts embedding the launcher can inject their own callbacks.
local util = require("util")

local M = {}

function M.script()
    return util.abs("src/loopback_server.ps1")
end

-- Start a one-shot listener. It writes the request path to `outfile` and then
-- serves a small "you can close this page" HTML response.
function M.start(port, outfile, opts)
    opts = opts or {}
    local cmd = string.format(
        'start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s" -Port %d -OutFile "%s" -TimeoutMs %d',
        M.script(), port, outfile, opts.timeout_ms or 180000)
    os.execute(cmd)
end

function M.open(url)
    os.execute('start "" "' .. tostring(url) .. '"')
end

-- Poll for the callback line. Returns the raw request path or nil on timeout.
function M.wait(outfile, timeout_seconds)
    local deadline = os.time() + (timeout_seconds or 180)
    while os.time() < deadline do
        if util.exists(outfile) then
            local content = util.read(outfile)
            os.remove(outfile)
            -- PowerShell's Set-Content utf8 adds a BOM; strip it so "^ERROR"
            -- detection and path parsing stay simple
            content = content:gsub("^\239\187\191", "")
            return (content:gsub("%s+$", ""))
        end
        os.execute("ping -n 2 127.0.0.1 >nul")
    end
    return nil
end

return M
