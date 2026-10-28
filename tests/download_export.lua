-- tests/download_export.lua: CLI export of download tasks (aria2 + JSON).
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local util = require("util")
local json = require("json")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local root = util.abs("tests/tmp-download-export")
util.rmtree(root)
util.mkdir(util.join(root, "versions", "1.20.1"))
util.write(util.join(root, "versions", "1.20.1", "1.20.1.json"),
    util.read(util.abs("tests/fixtures/vanilla-1.20.1.json")))

local lua = os.getenv("LUA") or arg[-1] or "lua"
local main = util.abs("src/main.lua")
local tasks = util.join(root, "tasks.txt")
local meta = util.join(root, "tasks.json")
local devnull = util.IS_WINDOWS and ">nul 2>&1" or ">/dev/null 2>&1"
local cmd = lua .. " " .. main .. " download 1.20.1 --dir " .. util.quote(root)
    .. " --export-aria2 " .. util.quote(tasks)
    .. " --export-json " .. util.quote(meta) .. " " .. devnull
local ok = os.execute(cmd)
check("export command", ok == true or ok == 0)
check("aria2 tasks file", util.exists(tasks))
check("json tasks file", util.exists(meta))

local data = json.decode(util.read(meta))
check("json has tasks", type(data.tasks) == "table" and #data.tasks > 0)
check("json root", data.root ~= nil)
local text = util.read(tasks)
check("aria2 dir", text:find("^dir=", 1) ~= nil or text:find("\ndir=", 1, true) ~= nil)
check("aria2 checksum", text:find("checksum=sha-1=", 1, true) ~= nil)
check("aria2 relative out", text:find("out=libraries/", 1, true) ~= nil)

util.rmtree(root)
print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
