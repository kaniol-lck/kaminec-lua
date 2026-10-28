-- pkce.lua: RFC 7636 PKCE verifier/challenge + base64url helper.
local sha256 = require("sha256")

local M = {}

local MAP = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

function M.b64url(data)
    local out, buf, bits = {}, 0, 0
    for i = 1, #data do
        buf = (buf << 8) | data:byte(i)
        bits = bits + 8
        while bits >= 6 do
            bits = bits - 6
            local idx = (buf >> bits) & 63
            out[#out + 1] = MAP:sub(idx + 1, idx + 1)
        end
        buf = buf & ((1 << bits) - 1)
    end
    if bits > 0 then
        local idx = (buf << (6 - bits)) & 63
        out[#out + 1] = MAP:sub(idx + 1, idx + 1)
    end
    return table.concat(out)
end

local UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

function M.random_string(n)
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    local out = {}
    for i = 1, n do
        local idx = math.random(1, #UNRESERVED)
        out[i] = UNRESERVED:sub(idx, idx)
    end
    return table.concat(out)
end

-- 43..128 chars, RFC 7636 unreserved set
function M.verifier()
    return M.random_string(64)
end

function M.challenge(verifier)
    return M.b64url(sha256.hex(verifier):gsub("..", function(hexpair)
        return string.char(tonumber(hexpair, 16))
    end))
end

return M
