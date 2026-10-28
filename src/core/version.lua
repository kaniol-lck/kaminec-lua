-- version.lua: version json download + inheritsFrom chain (child -> parent)
local json = require("json")
local http = require("http")
local util = require("util")
local manifest = require("manifest")

local M = {}

function M.fetch(workdir, entry)
    local dir = util.join(workdir, "versions", entry.id)
    local path = util.join(dir, entry.id .. ".json")
    http.ensure(entry.url, path)
    return json.decode(util.read(path))
end

function M.chain(workdir, manifest_data, entry)
    local docs = {}
    local cur = entry
    local guard = 0
    while cur do
        guard = guard + 1
        if guard > 10 then error("inheritsFrom chain too deep") end
        local doc = M.fetch(workdir, cur)
        docs[#docs + 1] = doc
        if doc.inheritsFrom and doc.inheritsFrom ~= "" then
            cur = manifest.find(manifest_data, doc.inheritsFrom)
        else
            cur = nil
        end
    end
    return docs
end

-- first non-nil value walking child -> parent
function M.pick(docs, fn)
    for _, doc in ipairs(docs) do
        local v = fn(doc)
        if v ~= nil then return v end
    end
    return nil
end

return M
