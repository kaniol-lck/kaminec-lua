-- tests/launcher_run.lua: POSIX launcher roundtrip with a fake java.
-- Validates run.sh creation/quoting/execution and script cleanup without a game.
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local util = require("util")
local launcher = require("launcher")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

if util.IS_WINDOWS then
    print("launcher_run: skipped on Windows")
    os.exit(0)
end

local root = util.abs("tests/tmp-launcher-run")
util.rmtree(root)
util.mkdir(root)

local fake_java = util.join(root, "fake-java.sh")
util.write(fake_java, "#!/bin/sh\necho \"fake-java:$@\"\nexit 0\n")
os.execute("chmod +x " .. util.quote(fake_java))

local logpath = util.join(root, "run.log")
local cmd = util.quote(fake_java) .. " '--version'"
local ok, code = pcall(launcher.run, cmd, root, root, logpath)

check("launcher.run exits 0", ok and code == 0, tostring(code))
check("fake java ran", util.exists(logpath) and util.read(logpath):find("fake%-java") ~= nil)
check("run.sh removed", not util.exists(util.join(root, "run.sh")))

util.rmtree(root)
print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
