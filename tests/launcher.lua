-- tests/launcher.lua: command redaction (access token must never be printed).
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

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

local cmd = 'java "--accessToken" "eyJhbGciOiJSUzI1NiJ9.payload.signature" "--uuid" "abc"'
local redacted = launcher.redact(cmd)

check("token removed", not redacted:find("eyJhbGci", 1, true))
check("token masked", redacted:find('"--accessToken" "***"', 1, true) ~= nil)
check("other args kept", redacted:find('"--uuid" "abc"', 1, true) ~= nil)
check("no token keeps command", launcher.redact('java -version') == 'java -version')

print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
