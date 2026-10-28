-- msa.lua: Microsoft account OAuth (public client flow).
-- Default authority is the consumer tenant (personal Microsoft accounts).
-- KAMINEC_MSA_AUTHORITY can override it with a tenant domain/ID for testing
-- (some app registrations live in a default directory and are not visible on
-- the consumers endpoint).
local json = require("json")

local M = {}

local AUTHORITY = os.getenv("KAMINEC_MSA_AUTHORITY")
if not AUTHORITY or AUTHORITY == "" then AUTHORITY = "consumers" end
local AUTH_BASE = "https://login.microsoftonline.com/" .. AUTHORITY .. "/oauth2/v2.0/"
M.AUTHORITY = AUTHORITY
M.DEVICE_CODE_URL = AUTH_BASE .. "devicecode"
M.TOKEN_URL = AUTH_BASE .. "token"
M.SCOPE = "XboxLive.signin offline_access"

local function decode(body)
    if not body or body == "" then return nil end
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

function M.decode(body) return decode(body) end

function M.error_message(status, data, body)
    if type(data) == "table" then
        local desc = data.error_description or data.message or data.error
        if desc then
            return string.format("Microsoft 登录失败 (%s): %s",
                tostring(data.error or status), tostring(desc))
        end
    end
    return string.format("Microsoft 登录失败 HTTP %s: %s",
        tostring(status), tostring(body or ""):sub(1, 200))
end

-- Ask Microsoft for a device code. Returns the parsed response or nil, error.
function M.request_device_code(httpc, client_id)
    local status, body = httpc.post_form(M.DEVICE_CODE_URL, {
        client_id = client_id,
        scope = M.SCOPE,
    })
    local data = decode(body)
    if status ~= 200 or not data or not data.device_code then
        return nil, M.error_message(status, data, body)
    end
    return data
end

local function sleep_seconds(n)
    n = math.max(1, math.floor(tonumber(n) or 5))
    -- ping is a portable sleep on Windows and keeps the CLI dependency-free
    os.execute("ping -n " .. tostring(n + 1) .. " 127.0.0.1 >nul")
end

-- Poll the token endpoint until the user finishes the browser step.
-- opts.sleep can be injected by tests; opts.on_pending is called on each wait.
function M.poll(httpc, client_id, device, opts)
    opts = opts or {}
    local interval = tonumber(device.interval) or 5
    local expires_in = tonumber(device.expires_in) or 900
    local deadline = os.time() + expires_in
    local sleeper = opts.sleep or sleep_seconds
    while os.time() < deadline do
        local status, body = httpc.post_form(M.TOKEN_URL, {
            grant_type = "urn:ietf:params:oauth:grant-type:device_code",
            client_id = client_id,
            device_code = device.device_code,
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

-- Exchange a refresh token for a fresh access token.
function M.refresh(httpc, client_id, refresh_token)
    local status, body = httpc.post_form(M.TOKEN_URL, {
        grant_type = "refresh_token",
        client_id = client_id,
        refresh_token = refresh_token,
        scope = M.SCOPE,
    })
    local data = decode(body)
    if status ~= 200 or not data or not data.access_token then
        return nil, M.error_message(status, data, body)
    end
    return data
end

local function url_encode(s)
    return (tostring(s):gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function url_decode(s)
    s = tostring(s):gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

M.url_encode = url_encode
M.url_decode = url_decode

-- Browser authorization-code URL (PKCE, loopback redirect).
function M.authorize_url(client_id, redirect_uri, state, code_challenge)
    return "https://login.microsoftonline.com/" .. AUTHORITY .. "/oauth2/v2.0/authorize"
        .. "?client_id=" .. url_encode(client_id)
        .. "&response_type=code"
        .. "&redirect_uri=" .. url_encode(redirect_uri)
        .. "&response_mode=query"
        .. "&scope=" .. url_encode(M.SCOPE)
        .. "&state=" .. url_encode(state)
        .. "&code_challenge=" .. url_encode(code_challenge)
        .. "&code_challenge_method=S256"
end

-- Parse "/auth?code=...&state=..." from the loopback callback.
function M.parse_redirect(value, expected_state)
    local query = tostring(value):match("%?(.*)$") or ""
    local params = {}
    for k, v in query:gmatch("([^&=]+)=([^&]*)") do
        params[url_decode(k)] = url_decode(v)
    end
    if params.error then
        return nil, "登录被取消或失败: " .. tostring(params.error_description or params.error)
    end
    if expected_state and params.state ~= expected_state then
        return nil, "state 不匹配，拒绝该回调"
    end
    if not params.code or params.code == "" then
        return nil, "回调中没有 code"
    end
    return params.code
end

-- Exchange the authorization code for tokens (PKCE verifier required).
function M.exchange_code(httpc, client_id, code, redirect_uri, code_verifier)
    local status, body = httpc.post_form(M.TOKEN_URL, {
        grant_type = "authorization_code",
        client_id = client_id,
        code = code,
        redirect_uri = redirect_uri,
        code_verifier = code_verifier,
    })
    local data = decode(body)
    if status ~= 200 or not data or not data.access_token then
        return nil, M.error_message(status, data, body)
    end
    return data
end

return M
