-- tools/plan_local.lua: build a launch plan from an already-installed
-- loader version json + its vanilla parent, without downloading anything.
-- usage: lua tools/plan_local.lua <child.json> <parent.json> [<loader-id>]
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local json = require("json")
local util = require("util")
local library = require("library")
local arguments = require("arguments")

local child_path, parent_path, forced_id = arg[1], arg[2], arg[3]
if not child_path or not parent_path then
    print("usage: lua tools/plan_local.lua <child.json> <parent.json> [<loader-id>]")
    os.exit(1)
end

local child = json.decode(util.read(child_path))
local parent = json.decode(util.read(parent_path))
local docs = { child, parent }

local features = {
    is_demo_user = false,
    has_custom_resolution = false,
    has_quick_plays_support = false,
    is_quick_play_singleplayer = false,
    is_quick_play_multiplayer = false,
    is_quick_play_realms = false,
}

-- same collection rule as main.lua: child first, dedupe by full name
local seen, libs = {}, {}
for _, doc in ipairs(docs) do
    for _, raw in ipairs(doc.libraries or {}) do
        local l = library.new(raw)
        if not seen[l:name()] and l:allowed(features) then
            seen[l:name()] = true
            libs[#libs + 1] = l
        end
    end
end

local id = forced_id or child.id
local cp = {}
for _, l in ipairs(libs) do cp[#cp + 1] = "<libraries>/" .. l:path() end
cp[#cp + 1] = "<versions>/" .. id .. "/" .. id .. ".jar"

local ph = {
    auth_player_name = "Steve",
    auth_uuid = "00000000-0000-4000-8000-000000000000",
    auth_access_token = "0",
    clientid = "0",
    auth_xuid = "0",
    user_type = "legacy",
    version_name = id,
    version_type = child.type or "release",
    game_directory = "<game>",
    assets_root = "<assets>",
    assets_index_name = (child.assetIndex or parent.assetIndex or {}).id or "legacy",
    natives_directory = "<natives>",
    launcher_name = "Kaminec-Spike",
    launcher_version = "0.1",
    classpath = table.concat(cp, ";"),
    classpath_separator = ";",
    library_directory = "<libraries>",
    resolution_width = "854",
    resolution_height = "480",
}

local jvm, game = arguments.build(docs, ph, features)

local function unresolved(list, label)
    local bad = {}
    for _, a in ipairs(list) do
        for k in a:gmatch("%$%{([%w_]+)%}") do bad[k] = true end
    end
    local keys = {}
    for k in pairs(bad) do keys[#keys + 1] = k end
    table.sort(keys)
    print(label .. " unresolved placeholders: " .. (#keys > 0 and table.concat(keys, ", ") or "(none)"))
end

print(string.format("child=%s parent=%s libraries=%d", id, parent.id, #libs))
print(string.format("jvm args=%d game args=%d", #jvm, #game))
print("mainClass=" .. tostring(child.mainClass))
unresolved(jvm, "jvm")
unresolved(game, "game")
print("has -cp: " .. tostring(table.concat(jvm, " "):find("%-cp") ~= nil))
print("has -p : " .. tostring(table.concat(jvm, " "):find("%-p ") ~= nil))
print("has launchTarget: " .. tostring(table.concat(game, " "):find("launchTarget") ~= nil))
print("game tail: " .. table.concat(game, " "):sub(-200))
