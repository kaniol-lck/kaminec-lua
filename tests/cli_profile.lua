-- tests/cli_profile.lua: end-to-end CLI smoke for profile commands.
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local util = require("util")
local json = require("json")
local profile = require("profile")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local root = util.abs("tests/tmp-cli-profile")
util.rmtree(root)
util.mkdir(root)

local lua = os.getenv("LUA") or arg[-1] or "lua"
local main = util.abs("src/main.lua")
local devnull = util.IS_WINDOWS and ">nul 2>&1" or ">/dev/null 2>&1"
local function cli(args)
    local cmd = lua .. " " .. main .. " " .. args .. " " .. devnull
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end
local function q(s) return util.quote(s) end

check("defaults command", cli("profile defaults --dir " .. q(root)
    .. " --memory 2G --username Steve"))
local store = profile.load(root)
check("defaults saved", store.defaults.memory == "2G" and store.defaults.username == "Steve")

check("create command", cli("profile create 1.20.1 --dir " .. q(root)
    .. " --name " .. q("CLI Profile") .. " --memory 4G --username Steve"))
store = profile.load(root)
local created = store.profiles["cli-profile"]
check("profile created", created ~= nil and created.version == "1.20.1")
check("profile settings", created and created.settings.memory == "4G")

local src = util.join(root, "official")
util.mkdir(src)
util.write(util.join(src, "launcher_profiles.json"), json.encode({
    profiles = {
        abc = { name = "Official 1.20.1", lastVersionId = "1.20.1", gameDir = "D:/games/mc" },
    },
}))
check("import dry-run", cli("profile import --from official --source-dir " .. q(src)
    .. " --dir " .. q(root) .. " --dry-run"))
check("import dry-run does not write", profile.load(root).profiles["official-1.20.1"] == nil)
check("import apply", cli("profile import --from official --source-dir " .. q(src)
    .. " --dir " .. q(root) .. " --yes"))
check("import applied", profile.load(root).profiles["official-1.20.1"] ~= nil)

local exroot = util.join(root, "existing")
util.mkdir(util.join(exroot, "versions", "1.20.1"))
util.write(util.join(exroot, "versions", "1.20.1", "1.20.1.json"), "{}")
check("attach existing", cli("profile create --from-existing " .. q(exroot)
    .. " --dir " .. q(root) .. " --id attached"))
store = profile.load(root)
check("attached external", store.profiles.attached ~= nil and store.profiles.attached.external == true)

check("delete command", cli("profile delete cli-profile --dir " .. q(root) .. " --yes"))
check("deleted", profile.load(root).profiles["cli-profile"] == nil)

util.rmtree(root)
print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
