-- planner.lua: build a pure-data launch plan.
-- No downloads, no process launch, no UI: the caller (CLI or a plugin host)
-- decides what to fetch and how to start the game.
local json = require("json")
local util = require("util")
local rules = require("rules")
local library = require("library")
local arguments = require("arguments")
local manifest = require("manifest")

local M = {}

local MANIFEST_URL = "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json"

local function get_manifest(host, workdir, opts)
    local path = util.join(workdir, "version_manifest_v2.json")
    if not host.exists(path) then
        if opts.offline then
            error("offline mode: version_manifest_v2.json is missing")
        end
        host.fetch(MANIFEST_URL, path)
    end
    return json.decode(host.read(path))
end

local function local_version(host, workdir, id)
    local path = util.join(workdir, "versions", id, id .. ".json")
    if host.exists(path) then
        return json.decode(host.read(path)), path
    end
    return nil
end

-- child -> parent. Local jsons win; the official manifest is only needed for
-- versions that are not installed locally.
local function resolve_docs(host, workdir, id, opts)
    local docs = {}
    local cur = id
    local guard = 0
    local mdata
    while cur do
        guard = guard + 1
        if guard > 10 then error("inheritsFrom chain too deep") end
        local doc = local_version(host, workdir, cur)
        if not doc then
            if opts.offline then
                error("offline mode: version json missing for " .. cur)
            end
            if not mdata then mdata = get_manifest(host, workdir, opts) end
            local entry = manifest.find(mdata, cur)
            local path = util.join(workdir, "versions", entry.id, entry.id .. ".json")
            if not host.exists(path) then
                host.fetch(entry.url, path)
            end
            doc = json.decode(host.read(path))
        end
        docs[#docs + 1] = doc
        if doc.inheritsFrom and doc.inheritsFrom ~= "" then
            cur = doc.inheritsFrom
        else
            cur = nil
        end
    end
    return docs
end

local function pick(docs, fn)
    for _, d in ipairs(docs) do
        local v = fn(d)
        if v ~= nil then return v end
    end
    return nil
end

-- Split libraries into classpath entries and legacy natives archives.
-- A library with a `natives` classifier (1.12.2 and older) contributes its
-- classifier jar to the natives directory instead of the classpath; LWJGL 2
-- does not unpack its own natives. The same coordinate may also appear once
-- as a plain artifact (1.12.2 text2speech does), so both lists are
-- deduplicated independently by their own key.
local function collect_libraries(docs, features)
    local seen, list = {}, {}
    local seen_natives, natives = {}, {}
    for _, doc in ipairs(docs) do
        for _, raw in ipairs(doc.libraries or {}) do
            local l = library.new(raw)
            if l:allowed(features) then
                if l:is_legacy_natives() then
                    local key = l:name() .. "|" .. tostring(l:natives_key()) .. "|" .. l:path()
                    if not seen_natives[key] then
                        seen_natives[key] = true
                        natives[#natives + 1] = l
                    end
                elseif not seen[l:name()] then
                    seen[l:name()] = true
                    list[#list + 1] = l
                end
            end
        end
    end
    return list, natives
end

-- Build a plan. host = adapters table; workdir must be absolute.
function M.build(host, workdir, version_id, opts)
    opts = opts or {}
    local docs = resolve_docs(host, workdir, version_id, opts)
    local id = docs[1].id or version_id

    local width, height = opts.width, opts.height
    local features = {
        is_demo_user = false,
        has_custom_resolution = (width ~= nil and height ~= nil),
        has_quick_plays_support = false,
        is_quick_play_singleplayer = false,
        is_quick_play_multiplayer = false,
        is_quick_play_realms = false,
    }

    local warnings = {}

    -- Client jar resolution:
    --   1. existing versions/<id>/<id>.jar wins: the official installer writes a
    --      patched/copied jar there and Forge's -DignoreList refers to it
    --   2. an explicit `jar` field points at another version's jar
    --   3. vanilla: its own versions/<id>/<id>.jar
    --   4. loader without an installed jar: fall back to the parent jar for the
    --      plan only and warn (a real launch still needs the installer)
    local owner_index, client
    for i, d in ipairs(docs) do
        if d.downloads and d.downloads.client then
            owner_index, client = i, d.downloads.client
            break
        end
    end
    if not client then error("version json has no client download") end

    local child_jar = util.join(workdir, "versions", id, id .. ".jar")
    local own_client = docs[1].downloads and docs[1].downloads.client
    local jar_override = pick(docs, function(d) return d.jar end)
    local client_path
    if host.exists(child_jar) then
        client_path = child_jar
    elseif jar_override and jar_override ~= "" then
        client_path = util.join(workdir, "versions", jar_override, jar_override .. ".jar")
    elseif own_client then
        client_path = child_jar
    else
        client_path = util.join(workdir, "versions", docs[owner_index].id, docs[owner_index].id .. ".jar")
        -- Fabric/Forge 1.12.2 load the parent jar directly; modern Forge and
        -- NeoForge rely on an installer-produced loader jar, so only warn there.
        local loader_main = tostring(pick(docs, function(d) return d.mainClass end) or "")
        if loader_main:find("^cpw%.mods") then
            warnings[#warnings + 1] = "loader instance is not installed: " .. id .. ".jar is missing"
        end
    end

    -- libraries: classpath jars and legacy natives archives are separate
    local libs, native_libs = collect_libraries(docs, features)
    local libroot = util.join(workdir, "libraries")
    local classpath = {}
    local natives = {}
    local downloads = {}

    local include_all = opts.include_existing and true or false
    for _, l in ipairs(libs) do
        local target = util.join(libroot, l:path())
        classpath[#classpath + 1] = target
        local present = host.exists(target)
        if include_all or not present then
            downloads[#downloads + 1] = {
                present = present,
                kind = "library",
                name = l:name(),
                url = l:url(),
                path = target,
                size = l:size(),
                sha1 = l:sha1(),
            }
        end
    end

    for _, l in ipairs(native_libs) do
        local target = util.join(libroot, l:path())
        natives[#natives + 1] = {
            kind = "natives",
            name = l:name(),
            url = l:url(),
            path = target,
            size = l:size(),
            sha1 = l:sha1(),
        }
        if include_all or not host.exists(target) then
            downloads[#downloads + 1] = {
                present = host.exists(target),
                kind = "natives",
                name = l:name(),
                url = l:url(),
                path = target,
                size = l:size(),
                sha1 = l:sha1(),
            }
        end
    end
    classpath[#classpath + 1] = client_path
    local client_present = host.exists(client_path)
    if include_all or not client_present then
        downloads[#downloads + 1] = {
            present = client_present,
            kind = "client",
            name = id .. ".jar",
            url = client.url,
            path = client_path,
            size = client.size,
            sha1 = client.sha1,
        }
    end

    -- asset index (objects are left to the host/CLI; see assets.lua)
    local asset_index = pick(docs, function(d) return d.assetIndex end)
    local assets_root = util.join(workdir, "assets")
    local assets = { index_id = nil, index_path = nil, index_present = false, objects_missing = nil }
    if asset_index then
        assets.index_id = asset_index.id
        assets.index_path = util.join(assets_root, "indexes", asset_index.id .. ".json")
        assets.index_present = host.exists(assets.index_path)
        if include_all or not assets.index_present then
            downloads[#downloads + 1] = {
                present = assets.index_present,
                kind = "asset_index",
                name = asset_index.id .. ".json",
                url = asset_index.url,
                path = assets.index_path,
                size = asset_index.size,
                sha1 = asset_index.sha1,
            }
        end
    end

    local natives_dir = util.join(workdir, "natives")
    local game_dir = util.join(workdir, "game")

    local main_class = pick(docs, function(d) return d.mainClass end)
    if not main_class then error("version json has no mainClass") end
    local version_type = docs[1].type or "release"
    local java_version = pick(docs, function(d) return d.javaVersion end)

    local launcher_name = opts.launcher_name or "Kaminec-Lua"
    local launcher_version = opts.launcher_version or "0.1"

    local ph = {
        auth_player_name = opts.name or "Steve",
        auth_uuid = opts.uuid or "00000000-0000-4000-8000-000000000000",
        auth_access_token = opts.access_token or "0",
        clientid = opts.clientid or "0",
        auth_xuid = opts.xuid or "0",
        user_type = opts.user_type or "legacy",
        version_name = id,
        version_type = version_type,
        game_directory = game_dir,
        assets_root = assets_root,
        assets_index_name = assets.index_id or "legacy",
        natives_directory = natives_dir,
        launcher_name = launcher_name,
        launcher_version = launcher_version,
        classpath = table.concat(classpath, ";"),
        classpath_separator = util.path_separator,
        library_directory = libroot,
        resolution_width = width or "854",
        resolution_height = height or "480",
    }

    local jvm, game, used_minecraft_arguments = arguments.build(docs, ph, features)

    local function jvm_has(value)
        for _, a in ipairs(jvm) do
            if a == value then return true end
        end
        return false
    end

    local function jvm_has_prefix(prefix)
        for _, a in ipairs(jvm) do
            if a:sub(1, #prefix) == prefix then return true end
        end
        return false
    end

    -- 1.12.2 and older vanilla jsons carry no jvm arguments at all: the
    -- launcher must supply the classpath and the natives directory itself.
    -- Only fill in what is missing, so modern jsons are left untouched.
    local has_classpath = jvm_has("-cp") or jvm_has("-classpath")
    local defaults_added = false
    if not has_classpath then
        if not jvm_has_prefix("-Djava.library.path=") then
            jvm[#jvm + 1] = "-Djava.library.path=" .. natives_dir
        end
        jvm[#jvm + 1] = "-cp"
        jvm[#jvm + 1] = table.concat(classpath, ";")
        if not jvm_has_prefix("-Dminecraft.launcher.brand=") then
            jvm[#jvm + 1] = "-Dminecraft.launcher.brand=" .. launcher_name
        end
        if not jvm_has_prefix("-Dminecraft.launcher.version=") then
            jvm[#jvm + 1] = "-Dminecraft.launcher.version=" .. launcher_version
        end
        defaults_added = true
    end

    local legacy = used_minecraft_arguments or not has_classpath

    if used_minecraft_arguments or defaults_added then
        local why = {}
        if used_minecraft_arguments then why[#why + 1] = "minecraftArguments" end
        if defaults_added then why[#why + 1] = "default JVM args" end
        warnings[#warnings + 1] = "legacy format (" .. table.concat(why, ", ") .. "); Java 8 required"
    end

    -- unresolved placeholders are a bug signal, keep them visible
    local unresolved = {}
    for _, a in ipairs(jvm) do
        for k in a:gmatch("%$%{([%w_]+)%}") do unresolved[k] = true end
    end
    for _, a in ipairs(game) do
        for k in a:gmatch("%$%{([%w_]+)%}") do unresolved[k] = true end
    end
    for k in pairs(unresolved) do
        warnings[#warnings + 1] = "unresolved placeholder: " .. k
    end

    return {
        schema = 1,
        version_id = id,
        inherits_from = docs[2] and docs[2].id or nil,
        version_type = version_type,
        main_class = main_class,
        java_version = java_version,
        game_dir = game_dir,
        assets_dir = assets_root,
        natives_dir = natives_dir,
        library_directory = libroot,
        classpath = classpath,
        classpath_separator = util.path_separator,
        jvm_args = jvm,
        game_args = game,
        assets = assets,
        downloads = downloads,
        natives = natives,
        legacy_format = legacy,
        warnings = warnings,
        docs = #docs,
    }
end

function M.manifest(host, workdir, opts)
    return get_manifest(host, workdir, opts or {})
end

return M
