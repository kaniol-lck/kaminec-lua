-- accounts_import.lua: import a Minecraft access token from the official
-- Minecraft launcher. No Azure application is involved and no other launcher's
-- store is read.
--
-- Supported stores (plain JSON, official launcher only):
--   * official Java launcher: %APPDATA%\.minecraft\launcher_accounts.json
--   * official Store launcher: ...\Packages\Microsoft.4297127D64EC6_*\...\launcher_accounts.json
--
-- Only the short-lived access token is kept. Refresh tokens are deliberately
-- dropped: they are bound to the issuing launcher's client id, and storing
-- another app's refresh token would be pointless risk.
local json = require("json")
local util = require("util")

local M = {}

function M.store_paths()
    local appdata = os.getenv("APPDATA") or ""
    local localappdata = os.getenv("LOCALAPPDATA") or ""
    return {
        { source = "official", path = util.join(appdata, ".minecraft", "launcher_accounts.json") },
        { source = "official-store", path = util.join(localappdata, "Packages",
            "Microsoft.4297127D64EC6_8wekyb3d8bbwe", "LocalCache", "Local", "launcher_accounts.json") },
    }
end

local function parse_time(value)
    if type(value) == "number" then
        -- tolerate milliseconds
        if value > 1e12 then return math.floor(value / 1000) end
        return value
    end
    if type(value) ~= "string" or value == "" then return nil end
    local y, mo, d, h, mi, s = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then return tonumber(value) end
    -- treat as UTC; os.time interprets the table as local time, close enough
    -- for an expiry guard (we only need "roughly expired")
    return os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
end

local function normalize_uuid(id)
    if type(id) ~= "string" then return nil end
    local s = id:gsub("%-", "")
    if #s == 32 then
        return string.format("%s-%s-%s-%s-%s", s:sub(1, 8), s:sub(9, 12), s:sub(13, 16),
            s:sub(17, 20), s:sub(21, 32))
    end
    return id
end

local function pick_field(tbl, names)
    for _, name in ipairs(names) do
        local v = tbl[name]
        if type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

-- Recursively collect account-like objects (anything with an accessToken).
local function walk(node, source, out)
    if type(node) ~= "table" then return end
    local token = pick_field(node, { "accessToken", "access_token" })
    if token then
        local profile = node.minecraftProfile or node.profile or node
        local name = pick_field(profile, { "name", "playerName", "username", "displayName" })
            or pick_field(node, { "playerName", "name", "username" })
        local uuid = pick_field(profile, { "id", "uuid", "profileId" })
            or pick_field(node, { "uuid", "profileId" })
        if name then
            out[#out + 1] = {
                type = "msa",
                auth_mode = "imported",
                name = name,
                uuid = normalize_uuid(uuid),
                access_token = token,
                expires_at = parse_time(node.accessTokenExpiresAt or node.expiresAt or node.expires_at),
                user_type = "msa",
                imported_from = source,
            }
        end
    end
    for _, v in pairs(node) do
        if type(v) == "table" then walk(v, source, out) end
    end
end

-- Returns a list of { name, uuid, access_token, expires_at, source } candidates.
-- `paths` is injectable for tests; defaults to the real launcher stores.
function M.scan(paths)
    local found = {}
    for _, store in ipairs(paths or M.store_paths()) do
        if util.exists(store.path) then
            local ok, data = pcall(json.decode, util.read(store.path))
            if ok and type(data) == "table" then
                walk(data, store.source, found)
            end
        end
    end
    -- dedupe by name, preferring official stores (they come first)
    local seen, list = {}, {}
    for _, acct in ipairs(found) do
        if not seen[acct.name] then
            seen[acct.name] = true
            list[#list + 1] = acct
        end
    end
    return list
end

return M
