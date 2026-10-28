-- launcher.lua: compose the java command line and run the game.
-- Windows writes run.bat and uses `cmd /c call`; POSIX writes run.sh and uses
-- `sh`. The access token is never printed in full and the script is removed
-- after the game exits.
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
    cmd = tostring(cmd)
    cmd = cmd:gsub('("%-%-accessToken"%s+")[^"]*"', '%1***"')
    cmd = cmd:gsub("('%-%-accessToken'%s+')[^']*'", "%1***'")
    return cmd
end

function M.run(cmd, workdir, gamedir, logpath)
    print("> " .. M.redact(cmd))
    print("")

    local script, shell
    if util.IS_WINDOWS then
        script = util.join(workdir, "run.bat")
        -- switch to the game directory so relative paths and logs/ land there,
        -- like the official launcher does
        util.write(script, "@echo off\r\ncd /d \"" .. gamedir:gsub("/", "\\") .. "\"\r\n" .. cmd .. "\r\n")
        shell = 'cmd /c call "' .. script .. '" 2>&1'
    else
        script = util.join(workdir, "run.sh")
        util.write(script, "#!/bin/sh\ncd " .. util.quote(gamedir) .. " || exit 1\nexec " .. cmd .. "\n")
        shell = "sh " .. util.quote(script) .. " 2>&1"
    end

    local ok, value = pcall(function()
        local f, err = io.popen(shell, "r")
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

    -- the script contains the raw access token; do not leave it on disk
    os.remove(script)
    if not ok then error(value) end
    return value
end

return M
