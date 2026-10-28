-- library.lua: modern library model (classifier + downloads.artifact.path)
local rules = require("rules")

local M = {}

function M.new(obj)
    return setmetatable({ obj = obj }, { __index = M })
end

function M:name() return self.obj.name end

function M:parts()
    local p = {}
    for seg in self.obj.name:gmatch("[^:]+") do p[#p + 1] = seg end
    return p
end

function M:is_legacy_natives()
    local n = self.obj.natives
    return (n ~= nil) and (n.windows ~= nil)
end

function M:natives_key()
    local n = self.obj.natives
    if not n then return nil end
    return n.windows
end

-- relative path under libraries/
function M:path()
    local d = self.obj.downloads or {}
    if self:is_legacy_natives() then
        local c = d.classifiers and d.classifiers[self:natives_key()]
        if c and c.path then return c.path end
    end
    if d.artifact and d.artifact.path then
        return d.artifact.path
    end
    -- fallback: derive from name (group:artifact:version[:classifier])
    local p = self:parts()
    local group, artifact, ver, classifier = p[1], p[2], p[3], p[4]
    local file = artifact .. "-" .. ver .. (classifier and ("-" .. classifier) or "") .. ".jar"
    return group:gsub("%.", "/") .. "/" .. artifact .. "/" .. ver .. "/" .. file
end

function M:url()
    local d = self.obj.downloads or {}
    if self:is_legacy_natives() then
        local c = d.classifiers and d.classifiers[self:natives_key()]
        if c and c.url then return c.url end
    end
    if d.artifact and d.artifact.url then
        return d.artifact.url
    end
    -- Maven-style library entries (Fabric/Quilt and some Forge libs) only carry
    -- a base repository url plus the coordinate in `name`.
    if self.obj.url and self.obj.url ~= "" then
        local base = self.obj.url
        if base:sub(-1) ~= "/" then base = base .. "/" end
        return base .. self:path()
    end
    return "https://libraries.minecraft.net/" .. self:path()
end

function M:sha1()
    local d = self.obj.downloads or {}
    if self:is_legacy_natives() then
        local c = d.classifiers and d.classifiers[self:natives_key()]
        if c then return c.sha1 end
    end
    if d.artifact then return d.artifact.sha1 end
    return nil
end

function M:size()
    local d = self.obj.downloads or {}
    if self:is_legacy_natives() then
        local c = d.classifiers and d.classifiers[self:natives_key()]
        if c then return c.size end
    end
    if d.artifact then return d.artifact.size end
    return nil
end

function M:allowed(features)
    return rules.allowed(self.obj.rules, features)
end

return M
