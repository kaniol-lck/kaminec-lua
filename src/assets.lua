-- assets.lua: download asset objects (hash-addressed) with parallel curl
local json = require("json")
local http = require("http")
local util = require("util")

local M = {}

local OBJECTS_BASE = "https://resources.download.minecraft.net"

function M.missing(workdir, index)
    local base = util.join(workdir, "assets", "objects")
    local list = {}
    for _, obj in pairs(index.objects or {}) do
        local hash = obj.hash
        local path = util.join(base, hash:sub(1, 2), hash)
        if util.size(path) ~= obj.size then
            list[#list + 1] = { hash = hash, path = path, size = obj.size }
        end
    end
    table.sort(list, function(a, b) return a.hash < b.hash end)
    return list
end

-- returns number of files still missing after the attempt
function M.ensure(workdir, index, opts)
    opts = opts or {}
    local todo = M.missing(workdir, index)
    if #todo == 0 then
        print("  assets: all cached")
        return 0
    end
    local total = 0
    for _, o in pairs(index.objects or {}) do total = total + 1 end
    print(string.format("  assets: %d/%d missing, downloading ...", #todo, total))

    local cfg = util.join(workdir, "assets", "objects.curlrc")
    local lines = { "create-dirs" }
    local proxy = http.proxy()
    if proxy then
        lines[#lines + 1] = string.format('proxy = "%s"', proxy)
    end
    for _, item in ipairs(todo) do
        lines[#lines + 1] = string.format('url = "%s/%s/%s"', OBJECTS_BASE, item.hash:sub(1, 2), item.hash)
        -- curl interprets backslashes inside quoted config values as escapes
        lines[#lines + 1] = string.format('output = "%s"', item.path:gsub("\\", "/"))
    end
    util.write(cfg, table.concat(lines, "\n") .. "\n")

    local curl = http.curl()
    local cmd = table.concat({
        curl, "-sS", "-L", "--fail", "--retry", "3",
        "--parallel", "--parallel-max", "16",
        "-K", util.quote(cfg),
    }, " ")
    os.execute(cmd)

    local still = M.missing(workdir, index)
    print(string.format("  assets: %d downloaded, %d still missing", #todo - #still, #still))
    return #still
end

return M
