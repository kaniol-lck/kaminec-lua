-- live_oauth.lua: legacy Microsoft account (login.live.com) OAuth.
--
-- Two properties matter here:
--   * no Azure app registration is needed (public Xbox Live client id)
--   * the device-code variant means the user only types a short code on
--     microsoft.com/link; nothing has to be copied back into the terminal
local json = require("json")

local M = {}

M.CLIENT_ID = "00000000402b5328"
M.SCOPE = "service::user.auth.xboxlive.com::MBI_SSL"
M.CONNECT_URL = "https://login.live.com/oauth20_connect.srf"
M.TOKEN_URL = "https://login.live.com/oauth20_token.srf"
M.DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"

local function decode(body)
    if not body or body == "" then return nil end
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

function M.decode(body) return decode(body) end

function M.error_message(status, data, body)
    if type(data) == "table" then
        local desc = data.error_description or data.error or data.message
        if desc then
            return string.format("Microsoft 登录失败 (%s): %s",
                tostring(data.error or status), tostring(desc))
        end
    end
    return string.format("Microsoft 登录失败 HTTP %s: %s",
        tostring(status), tostring(body or ""):sub(1, 200))
end

-- Step 1: ask live.com for a device code. The response contains user_code,
-- device_code, verification_uri (https://www.microsoft.com/link), interval.
function M.request_device_code(httpc)
    local status, body = httpc.post_form(M.CONNECT_URL, {
        client_id = M.CLIENT_ID,
        scope = M.SCOPE,
        response_type = "device_code",
    })
    local data = decode(body)
    if status ~= 200 or not data or not data.device_code then
        return nil, M.error_message(status, data, body)
    end
    return data
end

local function sleep_seconds(n)
    n = math.max(1, math.floor(tonumber(n) or 5))
    os.execute("ping -n " .. tostring(n + 1) .. " 127.0.0.1 >nul")
end

-- Step 2: poll until the user enters the code. opts.sleep is injectable.
function M.poll(httpc, device, opts)
    opts = opts or {}
    local interval = tonumber(device.interval) or 5
    local expires_in = tonumber(device.expires_in) or 900
    local deadline = os.time() + expires_in
    local sleeper = opts.sleep or sleep_seconds
    while os.time() < deadline do
        local status, body = httpc.post_form(M.TOKEN_URL, {
            client_id = M.CLIENT_ID,
            grant_type = M.DEVICE_GRANT,
            device_code = device.device_code,
            scope = M.SCOPE,
        })
        local data = decode(body)
        if status == 200 and data and data.access_token then
            return data
        end
        local err = data and data.error or nil
        if err == "authorization_pending" then
            if opts.on_pending then opts.on_pending("waiting") end
            sleeper(interval)
        elseif err == "slow_down" then
            interval = interval + 5
            if opts.on_pending then opts.on_pending("slow_down") end
            sleeper(interval)
        else
            return nil, M.error_message(status, data, body)
        end
    end
    return nil, "设备码已过期，请重新登录"
end

-- Refresh token (same token endpoint, different grant).
function M.refresh(httpc, refresh_token)
    local status, body = httpc.post_form(M.TOKEN_URL, {
        client_id = M.CLIENT_ID,
        grant_type = "refresh_token",
        refresh_token = refresh_token,
        scope = M.SCOPE,
    })
    local data = decode(body)
    if status ~= 200 or not data or not data.access_token then
        return nil, M.error_message(status, data, body)
    end
    return data
end

return M
