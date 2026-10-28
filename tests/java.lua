-- tests/java.lua: Java discovery/matching without a real JVM.
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local util = require("util")
local java = require("java")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local root = util.abs("tests/tmp-java")
local function fake_home(name, version)
    local home = util.join(root, name)
    util.mkdir(util.join(home, "bin"))
    util.write(util.join(home, "bin", java.EXE), "")
    util.write(util.join(home, "release"),
        'JAVA_VERSION="' .. version .. '"\nIMPLEMENTOR="TestVendor"\nOS_ARCH="x86_64"\n')
    return home
end

fake_home("jdk8", "1.8.0_392")
fake_home("jdk21", "21.0.1")

local list = java.discover({ roots = { root }, include_env = false })
check("discovered two runtimes", #list == 2, tostring(#list))
check("major 21 present", java.select(21, { roots = { root }, include_env = false }) ~= nil)
check("major 8 present", java.select(8, { roots = { root }, include_env = false }) ~= nil)

local j8 = java.select(8, { roots = { root }, include_env = false })
local ok8 = java.validate(j8.path, 8)
check("validate matching major", ok8 == true)
local bad, msg = java.validate(j8.path, 21)
check("detect lower mismatch", bad == false and msg:find("过低") ~= nil, msg)

local newer = java.select(17, { roots = { root }, include_env = false })
check("select newer fallback", newer ~= nil and newer.major == 21)
local oknew = java.validate(newer.path, 17)
check("validate newer major", oknew == true)

local info = java.detect(j8 and j8.path)
check("detect java path", info ~= nil and info.major == 8)
check("describe", java.describe(info):find("Java 1.8.0_392", 1, true) ~= nil)

util.rmtree(root)
print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
