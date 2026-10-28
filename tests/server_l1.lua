-- tests/server_l1.lua: CLI smoke for tools/server.lua L1 (no network/server start).
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local util = require("util")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local root = util.abs("tests/tmp-server-l1")
util.rmtree(root)
local lua = os.getenv("LUA") or arg[-1] or "lua"
local server = util.abs("tools/server.lua")
local devnull = util.IS_WINDOWS and ">nul 2>&1" or ">/dev/null 2>&1"
local function cli(args)
    local ok = os.execute(lua .. " " .. server .. " " .. args .. " " .. devnull)
    return ok == true or ok == 0
end

check("create", cli("create 1.21.8 --dir " .. util.quote(root) .. " --accept-eula --port 25566 --rcon-port 25576"))
check("server.json", util.exists(util.join(root, "server.json")))
check("eula accepted", util.read(util.join(root, "eula.txt")):find("eula=true", 1, true) ~= nil)
check("properties", util.exists(util.join(root, "server.properties")))
check("status", cli("status --dir " .. util.quote(root)))
util.mkdir(util.join(root, "world"))
util.write(util.join(root, "world", "level.dat"), "test")
check("backup", cli("backup --dir " .. util.quote(root)))
check("backup dir", util.isdir(util.join(root, "backups")))

util.rmtree(root)
print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
