-- tests/run.lua: offline tests for planner / rules / arguments
-- run from the project root: lua tests/run.lua
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local util = require("util")
local planner = require("planner")
local rules = require("rules")
local arguments = require("arguments")
local adapters = require("adapters")
local natives_extract = require("natives")

local root = util.abs("tests/tmp")
local function fixture(name)
    return util.abs("tests/fixtures/" .. name)
end

-- real filesystem, no network
local host = {
    exists = util.exists,
    size = util.size,
    read = util.read,
    write = util.write,
    mkdir = util.mkdir,
    log = function() end,
    fetch = function(url)
        error("network disabled in tests: " .. tostring(url))
    end,
}

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local function has_substring(list, needle)
    for _, v in ipairs(list) do
        if v:find(needle, 1, true) then return true end
    end
    return false
end

local function count_exact(list, needle)
    local n = 0
    for _, v in ipairs(list) do
        if v == needle then n = n + 1 end
    end
    return n
end

local function count_prefix(list, prefix)
    local n = 0
    for _, v in ipairs(list) do
        if v:sub(1, #prefix) == prefix then n = n + 1 end
    end
    return n
end

local function no_placeholder_warnings(plan)
    for _, w in ipairs(plan.warnings) do
        if w:find("unresolved placeholder", 1, true) then return false end
    end
    return true
end

local function setup(loader_id, loader_json, parent_id, parent_json)
    local d = util.join(root, "versions", loader_id)
    util.mkdir(d)
    util.write(util.join(d, loader_id .. ".json"), util.read(fixture(loader_json)))
    util.write(util.join(d, loader_id .. ".jar"), "dummy-client-jar")
    local p = util.join(root, "versions", parent_id)
    util.mkdir(p)
    util.write(util.join(p, parent_id .. ".json"), util.read(fixture(parent_json)))
end

print("planner: local loader instances (offline)")
setup("1.20.1-forge-47.3.0", "forge-1.20.1.json", "1.20.1", "vanilla-1.20.1.json")
setup("fabric-loader-0.20.1-1.20.1", "fabric-1.20.1.json", "1.20.1", "vanilla-1.20.1.json")

local forge = planner.build(host, root, "1.20.1-forge-47.3.0", { offline = true })
check("forge: main class", forge.main_class == "cpw.mods.bootstraplauncher.BootstrapLauncher")
check("forge: inherits 1.20.1", forge.inherits_from == "1.20.1")
check("forge: module path present", has_substring(forge.jvm_args, "-p"))
check("forge: launch target present", has_substring(forge.game_args, "--launchTarget"))
check("forge: no warnings (installed instance)", #forge.warnings == 0, table.concat(forge.warnings, ", "))
check("forge: classpath entries > 80", #forge.classpath > 80, tostring(#forge.classpath))
check("forge: missing downloads listed", #forge.downloads > 50, tostring(#forge.downloads))

local forge_urls = {}
for _, d in ipairs(forge.downloads) do forge_urls[#forge_urls + 1] = d.url end
check("forge: maven.minecraftforge.net used", has_substring(forge_urls, "maven.minecraftforge.net"))
check("forge: every download has sha1", (function()
    for _, d in ipairs(forge.downloads) do
        if d.kind == "library" and not d.sha1 then return false end
    end
    return true
end)())

local fabric = planner.build(host, root, "fabric-loader-0.20.1-1.20.1", { offline = true })
check("fabric: main class", fabric.main_class == "net.fabricmc.loader.impl.launch.knot.KnotClient")
check("fabric: no warnings", #fabric.warnings == 0, table.concat(fabric.warnings, ", "))
local fabric_urls = {}
for _, d in ipairs(fabric.downloads) do fabric_urls[#fabric_urls + 1] = d.url end
check("fabric: maven.fabricmc.net used", has_substring(fabric_urls, "maven.fabricmc.net"))

print("planner: no-overwrite policy")
local existing = forge.downloads[1].path
util.write(existing, "existing-file")
local forge2 = planner.build(host, root, "1.20.1-forge-47.3.0", { offline = true })
check("no-overwrite: count decreased", #forge2.downloads == #forge.downloads - 1,
    tostring(#forge2.downloads) .. " vs " .. tostring(#forge.downloads))
local still_listed = false
for _, d in ipairs(forge2.downloads) do
    if d.path == existing then still_listed = true end
end
check("no-overwrite: existing file kept", not still_listed)

print("planner: legacy versions (<= 1.12.2)")
setup("1.12.2-forge-14.23.5.2860", "forge-1.12.2.json", "1.12.2", "vanilla-1.12.2.json")

-- vanilla 1.12.2: no `arguments` object at all, only `minecraftArguments`
local vanilla112 = planner.build(host, root, "1.12.2", { offline = true })
check("1.12.2 vanilla: identified as legacy", vanilla112.legacy_format == true)
check("1.12.2 vanilla: jvm has -cp", has_substring(vanilla112.jvm_args, "-cp"))
check("1.12.2 vanilla: jvm has java.library.path", has_substring(vanilla112.jvm_args, "java.library.path="))
check("1.12.2 vanilla: -cp followed by full classpath", (function()
    for i, a in ipairs(vanilla112.jvm_args) do
        if a == "-cp" then
            return vanilla112.jvm_args[i + 1] == table.concat(vanilla112.classpath, ";")
        end
    end
    return false
end)())
check("1.12.2 vanilla: game args from minecraftArguments",
    has_substring(vanilla112.game_args, "--username")
    and has_substring(vanilla112.game_args, "--assetIndex")
    and has_substring(vanilla112.game_args, "1.12"))
check("1.12.2 vanilla: no unresolved placeholders", no_placeholder_warnings(vanilla112))
check("1.12.2 vanilla: launcher brand/version injected once",
    count_prefix(vanilla112.jvm_args, "-Dminecraft.launcher.brand=") == 1
    and count_prefix(vanilla112.jvm_args, "-Dminecraft.launcher.version=") == 1)
check("1.12.2 vanilla: natives found", #vanilla112.natives > 0, tostring(#vanilla112.natives))
check("1.12.2 vanilla: natives are windows classifier jars", (function()
    local paths = {}
    for _, n in ipairs(vanilla112.natives) do paths[#paths + 1] = n.path end
    return #paths > 0 and has_substring(paths, "-natives-windows.jar")
end)())

-- a previous run may have left the classifier jars behind; clean them so the
-- "missing natives are listed for download" assertion stays deterministic
for _, n in ipairs(vanilla112.natives) do os.remove(n.path) end
vanilla112 = planner.build(host, root, "1.12.2", { offline = true })
check("1.12.2 vanilla: missing natives listed for download", (function()
    for _, n in ipairs(vanilla112.natives) do
        local found = false
        for _, d in ipairs(vanilla112.downloads) do
            if d.path == n.path and d.kind == "natives" and d.url and d.url ~= "" and d.sha1 then
                found = true
            end
        end
        if not found then return false end
    end
    return true
end)())
check("1.12.2 vanilla: natives kept out of classpath", (function()
    local classpath = {}
    for _, c in ipairs(vanilla112.classpath) do classpath[c] = true end
    for _, n in ipairs(vanilla112.natives) do
        if classpath[n.path] then return false end
    end
    return true
end)())

-- Forge 1.12.2 inherits 1.12.2 and adds --tweakClass FMLTweaker to the legacy
-- argument string; its jvm args are still empty, so defaults must be injected.
local forge112 = planner.build(host, root, "1.12.2-forge-14.23.5.2860", { offline = true })
check("1.12.2 forge: main class", forge112.main_class == "net.minecraft.launchwrapper.Launch")
check("1.12.2 forge: inherits 1.12.2", forge112.inherits_from == "1.12.2")
check("1.12.2 forge: FMLTweaker in game args",
    has_substring(forge112.game_args, "net.minecraftforge.fml.common.launcher.FMLTweaker"))
check("1.12.2 forge: --tweakClass present", has_substring(forge112.game_args, "--tweakClass"))
check("1.12.2 forge: jvm has -cp and java.library.path",
    has_substring(forge112.jvm_args, "-cp") and has_substring(forge112.jvm_args, "java.library.path="))
check("1.12.2 forge: no unresolved placeholders", no_placeholder_warnings(forge112))
check("1.12.2 forge: natives inherited from parent", #forge112.natives == #vanilla112.natives,
    tostring(#forge112.natives) .. " vs " .. tostring(#vanilla112.natives))

-- modern jsons must not get default JVM args injected on top of their own
check("forge 1.20.1: single -cp (defaults not injected)", count_exact(forge.jvm_args, "-cp") == 1,
    tostring(count_exact(forge.jvm_args, "-cp")))
check("forge 1.20.1: single launcher brand (defaults not injected)",
    count_prefix(forge.jvm_args, "-Dminecraft.launcher.brand=") == 1,
    tostring(count_prefix(forge.jvm_args, "-Dminecraft.launcher.brand=")))
check("modern jsons: no legacy natives", #forge.natives == 0 and #fabric.natives == 0)

print("natives: extraction")
local native_calls = {}
local extract_host = {
    exists = util.exists,
    mkdir = function() end,
    extract_zip = function(zip, dest)
        native_calls[#native_calls + 1] = { zip = zip, dest = dest }
        return true
    end,
}
for _, n in ipairs(vanilla112.natives) do util.write(n.path, "dummy-natives-jar") end
local extracted, missing = natives_extract.ensure(extract_host, vanilla112)
check("natives.ensure: all archives extracted",
    extracted == #vanilla112.natives and #missing == 0,
    tostring(extracted) .. "/" .. tostring(#vanilla112.natives) .. " missing=" .. tostring(#missing))
check("natives.ensure: extracted into natives_dir",
    native_calls[1] ~= nil and native_calls[1].dest == vanilla112.natives_dir)
check("natives.ensure: no natives is a no-op",
    select(1, natives_extract.ensure(extract_host, { natives = {}, natives_dir = "unused" })) == 0)
for _, n in ipairs(vanilla112.natives) do os.remove(n.path) end

print("adapters: extract_zip")
local zipdir = util.join(root, "zip-roundtrip")
util.mkdir(zipdir)
util.write(util.join(zipdir, "dummy.dll"), "natives")
os.remove(util.join(zipdir, "natives.zip"))
local made_zip
if util.IS_WINDOWS then
    made_zip = os.execute('cd /d "' .. zipdir:gsub("/", "\\") .. '" && tar -a -cf natives.zip dummy.dll')
else
    made_zip = os.execute('cd ' .. util.quote(zipdir)
        .. ' && (zip -q natives.zip dummy.dll || python3 -m zipfile -c natives.zip dummy.dll)')
end
if made_zip == true then
    local dest = util.join(root, "zip-roundtrip-out")
    local ok = adapters.cli().extract_zip(util.join(zipdir, "natives.zip"), dest)
    check("extract_zip: zip -> dest", ok == true and util.exists(util.join(dest, "dummy.dll")))
else
    print("  skip extract_zip roundtrip (tar cannot create a zip on this host)")
end

print("rules")
check("nil rules allow", rules.allowed(nil, {}) == true)
local this_os = rules.OS_NAME
check("allow osx only -> " .. tostring(this_os == "osx"),
    rules.allowed({ { action = "allow", os = { name = "osx" } } }, {}) == (this_os == "osx"))
check("allow windows -> " .. tostring(this_os == "windows"),
    rules.allowed({ { action = "allow", os = { name = "windows" } } }, {}) == (this_os == "windows"))
check("disallow osx -> " .. tostring(this_os ~= "osx"), rules.allowed({
    { action = "allow" },
    { action = "disallow", os = { name = "osx" } },
}, {}) == (this_os ~= "osx"))
check("feature off filters arg", rules.allowed({ { action = "allow", features = { is_demo_user = true } } }, {}) == false)
check("feature on keeps arg", rules.allowed({ { action = "allow", features = { is_demo_user = true } } }, { is_demo_user = true }) == true)

print("arguments")
local docs = { {
    arguments = {
        jvm = { "-DlibraryDirectory=${library_directory}" },
        game = {
            "--username", "${auth_player_name}",
            { rules = { { action = "allow", features = { is_demo_user = true } } }, value = "--demo" },
            { rules = { { action = "allow" } }, value = { "--width", "${resolution_width}" } },
        },
    },
} }
local jvm, game = arguments.build(docs, {
    library_directory = "LIB",
    auth_player_name = "Steve",
    resolution_width = "854",
    resolution_height = "480",
}, {})
check("jvm placeholder replaced", jvm[1] == "-DlibraryDirectory=LIB", tostring(jvm[1]))
check("game username substituted", game[2] == "Steve", tostring(game[2]))
check("feature-gated arg skipped", not has_substring(game, "--demo"))
check("rule arg kept and substituted", has_substring(game, "--width") and has_substring(game, "854"))

print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
