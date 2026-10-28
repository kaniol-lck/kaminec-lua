-- profile.lua: profile store (defaults + per-profile settings) and official
-- launcher profile import. Third-party launcher import intentionally stays in
-- tools/ for later.
local util = require("util")
local json = require("json")

local M = {}

function M.path(root)
    return util.join(root, "profiles.json")
end

function M.empty()
    return { schema = 1, defaults = {}, profiles = {} }
end

function M.load(root)
    local path = M.path(root)
    if not util.exists(path) then return M.empty() end
    local ok, data = pcall(json.decode, util.read(path))
    if not ok or type(data) ~= "table" then error("invalid profiles.json: " .. path) end
    data.schema = data.schema or 1
    data.defaults = data.defaults or {}
    data.profiles = data.profiles or {}
    return data
end

function M.save(root, store)
    util.write(M.path(root), json.encode(store) .. "\n")
end

function M.find(store, id)
    if not id then return nil end
    return store.profiles[id]
end

function M.slug(name)
    local s = tostring(name or ""):lower():gsub("[^%w%._-]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if s == "" then s = "profile" end
    return s
end

-- Effective settings: built-in < defaults < profile settings < CLI flags.
function M.merge(defaults, settings)
    local out = { auto_download = true, show_console = false }
    for k, v in pairs(defaults or {}) do out[k] = v end
    for k, v in pairs(settings or {}) do out[k] = v end
    return out
end

function M.create(store, opts)
    local id = opts.id or M.slug(opts.name or opts.version)
    local base = id
    local n = 2
    while store.profiles[id] do
        id = base .. "-" .. tostring(n)
        n = n + 1
    end
    local profile_dir = util.join(opts.root, "profiles", id)
    local p = {
        name = opts.name or id,
        version = opts.version,
        root = opts.root,
        game_dir = opts.game_dir or util.join(profile_dir, "game"),
        natives_dir = opts.natives_dir or util.join(profile_dir, "natives"),
        external = opts.external or false,
        settings = opts.settings or {},
        created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    if opts.source then p.source = opts.source end
    store.profiles[id] = p
    if not p.external then
        util.mkdir(p.game_dir)
        util.mkdir(p.natives_dir)
    end
    return id, p
end

local function official_memory(java_args)
    if not java_args then return nil end
    return tostring(java_args):match("%-Xmx%s*([%w%.]+)")
end

-- Import official Java launcher profiles as read-only external profiles.
-- source_root defaults to %APPDATA%\.minecraft (Java launcher / CurseForge).
function M.import_official(store, source_root, opts)
    opts = opts or {}
    local root = source_root or util.join(os.getenv("APPDATA") or "", ".minecraft")
    local path = util.join(root, "launcher_profiles.json")
    if not util.exists(path) then
        return nil, "找不到官方启动器的 launcher_profiles.json: " .. path
    end
    local ok, data = pcall(json.decode, util.read(path))
    if not ok or type(data) ~= "table" then return nil, "launcher_profiles.json 解析失败" end
    local added, skipped, missing = {}, {}, {}
    for _, p in pairs(data.profiles or {}) do
        if type(p) == "table" and p.name then
            local version = p.lastVersionId or p.lastVersionID
            if not version or version == "" then
                missing[#missing + 1] = p.name .. " (no lastVersionId)"
            else
                local id = M.slug(p.name)
                if store.profiles[id] then
                    skipped[#skipped + 1] = p.name
                else
                    local settings = {}
                    if p.javaDir and p.javaDir ~= "" then settings.java = p.javaDir end
                    local memory = official_memory(p.javaArgs)
                    if memory then settings.memory = memory end
                    store.profiles[id] = {
                        name = p.name,
                        version = version,
                        root = root,
                        game_dir = p.gameDir and p.gameDir ~= "" and p.gameDir or root,
                        external = true,
                        settings = settings,
                        source = { launcher = opts.launcher or "official", profile = p.name },
                    }
                    added[#added + 1] = id
                end
            end
        end
    end
    return { added = added, skipped = skipped, missing = missing, root = root }
end

local function list_dirs(path)
    local cmd
    if util.IS_WINDOWS then
        cmd = 'dir /b /ad "' .. path:gsub("/", "\\") .. '" 2>nul'
    else
        cmd = 'ls -1 "' .. path .. '" 2>/dev/null'
    end
    local f = io.popen(cmd)
    local out = {}
    if f then
        for raw in f:lines() do
            local line = raw:gsub("%s+$", "")
            if line ~= "" then out[#out + 1] = line end
        end
        f:close()
    end
    return out
end

-- Discover an already-installed instance/version without copying it.
-- Accepts: a launcher root (contains versions/), a versions/<id> dir, or a
-- directory containing .minecraft/versions.
function M.detect_existing(src, version)
    src = util.abs(src)
    local root
    local base = util.basename(src)
    local parent = util.dirname(src)
    if util.basename(parent) == "versions" and util.exists(util.join(src, base .. ".json")) then
        root = util.dirname(parent)
        version = version or base
    elseif util.isdir(util.join(src, "versions")) then
        root = src
    elseif util.isdir(util.join(src, ".minecraft", "versions")) then
        root = util.join(src, ".minecraft")
    else
        return nil, "找不到 versions 目录: " .. src
    end

    local versions_dir = util.join(root, "versions")
    if version then
        if not util.exists(util.join(versions_dir, version, version .. ".json")) then
            return nil, "版本不存在: " .. version
        end
    else
        local candidates = {}
        for _, name in ipairs(list_dirs(versions_dir)) do
            if util.exists(util.join(versions_dir, name, name .. ".json")) then
                candidates[#candidates + 1] = name
            end
        end
        if #candidates == 0 then return nil, "versions 下没有可用的 version json" end
        if #candidates > 1 then
            table.sort(candidates)
            return nil, "多个版本，请用 --version 指定: " .. table.concat(candidates, ", ")
        end
        version = candidates[1]
    end

    local game_dir = util.join(root, "game")
    if not util.isdir(game_dir) then game_dir = root end
    return {
        root = root,
        version = version,
        game_dir = game_dir,
        natives_dir = util.join(root, "natives"),
    }
end

return M
