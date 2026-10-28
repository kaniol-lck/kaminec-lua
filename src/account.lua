-- account.lua: offline account (no auth server needed)
local M = {}

local function hash32(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return h
end

local function hex(n, width)
    local s = string.format("%x", n)
    while #s < width do s = "0" .. s end
    return s:sub(-width)
end

-- deterministic pseudo UUID (v4-shaped) from playername
function M.offline(playername)
    local h1 = hash32(playername)
    local h2 = hash32("kaminec:" .. playername)
    local h3 = hash32(playername .. ":spike")
    local h4 = hash32("offline:" .. playername)
    local a = hex(h1, 8)
    local b = hex(h2 % 0x10000, 4)
    local c = "4" .. hex(h3 % 0x1000, 3)
    local y = 8 + (h4 % 4)
    local d = hex(y, 1) .. hex((h2 // 0x10000) % 0x1000, 3)
    local e = hex((h3 * 31 + h1) % 0x100000000, 8) .. hex(h4, 4)
    return {
        name = playername,
        uuid = string.format("%s-%s-%s-%s-%s", a, b, c, d, e),
        access_token = "0",
        user_type = "legacy",
    }
end

return M
