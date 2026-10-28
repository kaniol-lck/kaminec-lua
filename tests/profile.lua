-- tests/profile.lua: profile store, defaults merge, official import.
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

local root = util.abs("tests/tmp-profile-test")
util.rmtree(root)
util.mkdir(root)

local store = profile.load(root)
check("empty store", next(store.profiles) == nil)
local id, p = profile.create(store, {
    root = root,
    version = "1.21.8",
    name = "Test Profile",
    settings = { java = "J", memory = "4G" },
})
check("created id", id == "test-profile", id)
check("game dir under profile", p.game_dir:find("/profiles/test-profile/game", 1, true) ~= nil)
profile.save(root, store)

local loaded = profile.load(root)
check("saved and reloaded", loaded.profiles[id] ~= nil)
check("settings kept", loaded.profiles[id].settings.memory == "4G")

local eff = profile.merge({ java = "D", memory = "2G", account = "A" }, { memory = "5G" })
check("defaults inherited", eff.java == "D" and eff.account == "A")
check("profile overrides defaults", eff.memory == "5G")

local src = util.join(root, "official")
util.mkdir(src)
util.write(util.join(src, "launcher_profiles.json"), json.encode({
    profiles = {
        abc = {
            name = "Official 1.21.8",
            lastVersionId = "1.21.8",
            gameDir = "D:/games/mc121",
            javaDir = "C:/Java/bin/java.exe",
            javaArgs = "-Xmx6G -XX:+UseG1GC",
        },
    },
}))
local imported = profile.empty()
local result, err = profile.import_official(imported, src, {})
check("import succeeded", result ~= nil, err)
check("one profile added", result and #result.added == 1)
local ip = imported.profiles["official-1.21.8"]
check("external imported", ip and ip.external == true)
check("version mapped", ip and ip.version == "1.21.8")
check("game_dir mapped", ip and ip.game_dir == "D:/games/mc121")
check("java mapped", ip and ip.settings.java == "C:/Java/bin/java.exe")
check("memory parsed", ip and ip.settings.memory == "6G")

local result2 = profile.import_official(imported, src, {})
check("duplicate import skipped", result2 and #result2.added == 0 and #result2.skipped == 1)

util.rmtree(root)
print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
