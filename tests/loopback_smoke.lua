-- tests/loopback_smoke.lua: live smoke test for the local callback server.
-- Starts the PowerShell listener, sends one fake callback with curl, checks it.
package.path = package.path .. ";./src/?.lua"

local loopback = require("loopback")
local util = require("util")

local outfile = util.abs("tests/tmp-cb.txt")
os.remove(outfile)

local port = 51234
loopback.start(port, outfile, { timeout_ms = 20000 })
os.execute("ping -n 2 127.0.0.1 >nul")

local url = "http://localhost:" .. port .. "/auth?code=TEST-1&state=S-1"
os.execute('curl -s -o NUL "' .. url .. '"')

local raw = loopback.wait(outfile, 10)
print("callback path: " .. tostring(raw))
os.remove(outfile)

if raw and raw:find("code=TEST%-1") and raw:find("state=S%-1") then
    print("loopback smoke: PASS")
    os.exit(0)
end
print("loopback smoke: FAIL")
os.exit(1)
