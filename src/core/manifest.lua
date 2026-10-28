-- manifest.lua: Mojang version manifest (v2)
local json = require("json")
local http = require("http")
local util = require("util")

local M = {}

local MANIFEST_URL = "https://launchermeta.mojang.com/mc/game/version_manifest_v2.json"

function M.load(workdir)
    local path = util.join(workdir, "version_manifest_v2.json")
    http.ensure(MANIFEST_URL, path)
    return json.decode(util.read(path))
end

function M.find(data, id)
    if not id or id == "" or id == "latest" then id = data.latest.release end
    for _, v in ipairs(data.versions) do
        if v.id == id then return v end
    end
    error("version not found: " .. tostring(id))
end

return M
