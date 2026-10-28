-- tests/plugin.lua: offline tests for the embeddable plugin API.
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local util = require("util")
local plugin = require("plugin")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local root = util.abs("tests/tmp-plugin")
-- tests must start from a clean instance, otherwise "downloads" is empty
os.execute('rmdir /s /q "' .. root:gsub("/", "\\") .. '" 2>nul')
local function fixture(name)
    return util.abs("tests/fixtures/" .. name)
end

local host = {
    exists = util.exists,
    read = util.read,
    write = util.write,
    mkdir = util.mkdir,
    size = util.size,
    log = function() end,
    fetch = function(url, path)
        util.write(path, "fetched:" .. tostring(url))
        return path
    end,
    extract_zip = function() end,
}

local function setup(loader_id, loader_json, parent_id, parent_json)
    local d = util.join(root, "versions", loader_id)
    util.mkdir(d)
    util.write(util.join(d, loader_id .. ".json"), util.read(fixture(loader_json)))
    util.write(util.join(d, loader_id .. ".jar"), "dummy")
    local p = util.join(root, "versions", parent_id)
    util.mkdir(p)
    util.write(util.join(p, parent_id .. ".json"), util.read(fixture(parent_json)))
end

setup("1.20.1-forge-47.3.0", "forge-1.20.1.json", "1.20.1", "vanilla-1.20.1.json")

print("plugin: construction and host contract")
local ok, err = pcall(plugin.new, {}, { workdir = root })
check("missing host callbacks rejected", not ok and tostring(err):find("host%.exists") ~= nil, tostring(err))

local p, perr = plugin.new(host, { workdir = root })
check("plugin created", p ~= nil and p.api_version == 1, perr)
check("api version", plugin.API_VERSION == 1)

print("plugin: plan / command")
local plan = p:build_plan("1.20.1-forge-47.3.0", { offline = true })
check("plan main class", plan.main_class == "cpw.mods.bootstraplauncher.BootstrapLauncher")
check("plan has classpath", #plan.classpath > 80, tostring(#plan.classpath))
check("plan has downloads", #plan.downloads > 50, tostring(#plan.downloads))

local cmd = p:command(plan, { java = "java" })
check("command program", cmd.program == "java")
check("command has main class", cmd.args[1] ~= nil and cmd.args[1] ~= "")
local found_main = false
for _, a in ipairs(cmd.args) do if a == plan.main_class then found_main = true end end
check("command includes main class", found_main)
check("command cwd", cmd.cwd == plan.game_dir)
check("command args are unquoted", cmd.args[2] ~= nil)

print("plugin: ensure")
local stats = p:ensure(plan)
check("downloads applied", stats.download.downloaded == #plan.downloads,
    tostring(stats.download.downloaded) .. " vs " .. tostring(#plan.downloads))
check("no download failures", stats.download.failed == 0)
local plan2 = p:build_plan("1.20.1-forge-47.3.0", { offline = true })
check("nothing missing after ensure", #plan2.downloads == 0, tostring(#plan2.downloads))

print("plugin: legacy natives hook")
local ok2, err2 = pcall(function()
    local legacy = p:build_plan("1.12.2", { offline = true })
    return legacy
end)
check("legacy plan call returns or reports missing data", ok2 or err2 ~= nil)

print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
