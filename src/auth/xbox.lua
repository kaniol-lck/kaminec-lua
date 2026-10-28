-- xbox.lua: Xbox Live / XSTS / Minecraft Services login chain.
local json = require("json")

local M = {}

M.XBL_URL = "https://user.auth.xboxlive.com/user/authenticate"
M.XSTS_URL = "https://xsts.auth.xboxlive.com/xsts/authorize"
M.MC_LOGIN_URL = "https://api.minecraftservices.com/authentication/login_with_xbox"
M.MC_PROFILE_URL = "https://api.minecraftservices.com/minecraft/profile"
M.MC_ENTITLEMENTS_URL = "https://api.minecraftservices.com/entitlements/mcstore"

local XSTS_ERRORS = {
    [2148916233] = "该 Microsoft 账号没有 Xbox Live 档案（需要先创建 Xbox 账号）",
    [2148916235] = "Xbox Live 在你所在的国家/地区不可用",
    [2148916236] = "该账号需要在 Xbox 页面完成成人验证",
    [2148916237] = "该账号需要在 Xbox 页面完成成人验证",
    [2148916238] = "该账号是未成年人账号，需要家长加入 Microsoft 家庭组",
}

local function decode(body)
    if not body or body == "" then return nil end
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

local function first_xui(data)
    local xui = data and data.DisplayClaims and data.DisplayClaims.xui
    return xui and xui[1] or nil
end

-- base64url decode without padding (JWT payloads)
local function b64url_decode(s)
    if not s then return nil end
    s = s:gsub("%-", "+"):gsub("_", "/")
    local pad = #s % 4
    if pad > 0 then s = s .. string.rep("=", 4 - pad) end
    local map = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out, buf, bits = {}, 0, 0
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == "=" then break end
        local v = map:find(c, 1, true)
        if not v then return nil end
        buf = (buf << 6) | (v - 1)
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            out[#out + 1] = string.char((buf >> bits) & 0xFF)
            buf = buf & ((1 << bits) - 1)
        end
    end
    return table.concat(out)
end

-- Claims of a JWT (XSTS token). Returns a table or nil.
function M.jwt_claims(token)
    if not token then return nil end
    local payload = token:match("^[^%.]+%.([^%.]+)%.")
    if not payload then return nil end
    local raw = b64url_decode(payload)
    if not raw then return nil end
    local ok, claims = pcall(json.decode, raw)
    if ok and type(claims) == "table" then return claims end
    return nil
end

-- Step 1: MSA access token -> Xbox Live user token + user hash.
function M.user_authenticate(httpc, msa_access_token)
    local status, body = httpc.post_json(M.XBL_URL, {
        Properties = {
            AuthMethod = "RPS",
            SiteName = "user.auth.xboxlive.com",
            RpsTicket = "d=" .. tostring(msa_access_token),
        },
        RelyingParty = "http://auth.xboxlive.com",
        TokenType = "JWT",
    })
    local data = decode(body)
    if status ~= 200 or not data or not data.Token then
        return nil, "Xbox Live 认证失败 HTTP " .. tostring(status) .. ": " .. tostring(body or ""):sub(1, 200)
    end
    local uhs = first_xui(data) and first_xui(data).uhs
    if not uhs then return nil, "Xbox Live 响应缺少 user hash" end
    return data.Token, uhs
end

-- Step 2: Xbox Live user token -> XSTS token (+ user hash, xuid).
function M.xsts_authorize(httpc, xbl_token)
    local status, body = httpc.post_json(M.XSTS_URL, {
        Properties = {
            SandboxId = "RETAIL",
            UserTokens = { xbl_token },
        },
        RelyingParty = "rp://api.minecraftservices.com/",
        TokenType = "JWT",
    })
    local data = decode(body)
    if status == 401 and data and data.XErr then
        local msg = XSTS_ERRORS[tonumber(data.XErr)]
        return nil, string.format("XSTS 授权失败 (XErr %s): %s", tostring(data.XErr),
            msg or "未知的账号状态")
    end
    if status ~= 200 or not data or not data.Token then
        return nil, "XSTS 授权失败 HTTP " .. tostring(status) .. ": " .. tostring(body or ""):sub(1, 200)
    end
    local xui = first_xui(data)
    if not xui or not xui.uhs then return nil, "XSTS 响应缺少 user hash" end
    return data.Token, xui.uhs, xui.xid
end

-- Step 3: XSTS token -> Minecraft access token.
function M.login_with_xbox(httpc, uhs, xsts_token)
    local status, body = httpc.post_json(M.MC_LOGIN_URL, {
        identityToken = "XBL3.0 x=" .. tostring(uhs) .. ";" .. tostring(xsts_token),
    })
    local data = decode(body)
    if status ~= 200 or not data or not data.access_token then
        return nil, "Minecraft 登录失败 HTTP " .. tostring(status) .. ": " .. tostring(body or ""):sub(1, 200)
    end
    return data
end

-- Step 4: Minecraft access token -> profile (uuid + name).
function M.profile(httpc, mc_access_token)
    local status, body = httpc.get_json(M.MC_PROFILE_URL, {
        headers = { Authorization = "Bearer " .. tostring(mc_access_token) },
    })
    local data = decode(body)
    if status == 404 then
        return nil, "该账号没有 Minecraft Java Edition（profile 404）"
    end
    if status ~= 200 or not data or not data.id then
        return nil, "获取 Minecraft 档案失败 HTTP " .. tostring(status) .. ": " .. tostring(body or ""):sub(1, 200)
    end
    return data
end

-- 32 hex chars -> 8-4-4-4-12
function M.format_uuid(id)
    if not id then return nil end
    local s = tostring(id):gsub("%-", "")
    if #s ~= 32 then return s end
    return string.format("%s-%s-%s-%s-%s", s:sub(1, 8), s:sub(9, 12), s:sub(13, 16),
        s:sub(17, 20), s:sub(21, 32))
end

return M
