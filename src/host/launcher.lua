-- launcher.lua: compose the java command line and run the game
-- The command is written to run.bat and executed through `cmd /c call`,
-- which avoids cmd.exe's "command starts with a quote" stripping problem.
-- The access token is never printed in full; run.bat is removed afterwards.
local util = require("util")

local M = {}

function M.build(java, jvm, main_class, game)
    local t = { util.quote(java) }
    for _, a in ipairs(jvm) do t[#t + 1] = util.quote(a) end
    t[#t + 1] = util.quote(main_class)
    for _, a in ipairs(game) do t[#t + 1] = util.quote(a) end
    return table.concat(t, " ")
end

-- Replace the access token value in a command line with *** for display/logs.
function M.redact(cmd)
    return (tostring(cmd):gsub('("%-%-accessToken"%s+")[^"]*"', '%1***"'))
end

function M.run(cmd, workdir, gamedir, logpath)
    print("> " .. M.redact(cmd))
    print("")
    local bat = util.join(workdir, "run.bat")
    -- switch to the game directory so relative paths and logs/ land there,
    -- like the official launcher does
    util.write(bat, "@echo off\r\ncd /d \"" .. gamedir:gsub("/", "\\") .. "\"\r\n" .. cmd .. "\r\n")

    local ok, value = pcall(function()
        local f, err = io.popen('cmd /c call "' .. bat .. '" 2>&1', "r")
        if not f then error("failed to start java: " .. tostring(err)) end
        local log = io.open(logpath, "wb")
        for line in f:lines() do
            print(line)
            if log then
                log:write(line, "\n")
                log:flush()
            end
        end
        local closed, _, code = f:close()
        if log then log:close() end
        if closed == true or closed == 0 then
            return 0
        end
        return code or 1
    end)

    -- run.bat contains the raw access token; do not leave it on disk
    os.remove(bat)
    if not ok then error(value) end
    return value
end

return M
