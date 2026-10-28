-- graph_setup.lua: create a personal Azure application without the Azure portal.
--
-- It uses Microsoft's Graph PowerShell public client id to sign the user in
-- (device code), then POSTs /v1.0/applications to create a public client app
-- with a http://localhost redirect URI. The resulting appId is written to
-- <workdir>/msa.json and can be used by the normal browser login flow.
--
-- The Graph token is used once and never stored.
local json = require("json")

local M = {}

-- Microsoft Graph PowerShell: public client, can request Application.ReadWrite.All
M.CLIENT_ID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
M.SCOPE = "https://graph.microsoft.com/Application.ReadWrite.All offline_access"
M.DEVICE_URL = "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode"
M.TOKEN_URL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
M.APP_URL = "https://graph.microsoft.com/v1.0/applications"
M.DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"

local function decode(body)
    if not body or body == "" then return nil end
    local ok, data = pcall(json.decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

function M.error_message(status, data, body)
    if type(data) == "table" then
        local desc = data.error_description or data.error or data.message
        if desc then
            return string.format("Graph 请求失败 (%s): %s",
                tostring(data.error or status), tostring(desc))
        end
    end
    return string.format("Graph 请求失败 HTTP %s: %s", tostring(status), tostring(body or ""):sub(1, 200))
end

function M.request_device_code(httpc)
    local status, body = httpc.post_form(M.DEVICE_URL, {
        client_id = M.CLIENT_ID,
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
    os.execute("ping -n " .. tostring(n + 1) .. " 127.0.0.1 >nul")
end

function M.poll(httpc, device, opts)
    opts = opts or {}
    local interval = tonumber(device.interval) or 5
    local deadline = os.time() + (tonumber(device.expires_in) or 900)
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
        local err = data and data.error
        if err == "authorization_pending" then
            sleeper(interval)
        elseif err == "slow_down" then
            interval = interval + 5
            sleeper(interval)
        else
            return nil, M.error_message(status, data, body)
        end
    end
    return nil, "设备码已过期，请重试"
end

-- Create a public client app with a http://localhost redirect URI.
function M.create_app(httpc, access_token, display_name)
    local payload = {
        displayName = display_name or "Kaminec-Lua",
        signInAudience = "AzureADandPersonalMicrosoftAccount",
        publicClient = { redirectUris = { "http://localhost" } },
        isFallbackPublicClient = true,
    }
    local status, body = httpc.post_json(M.APP_URL, payload, {
        headers = { Authorization = "Bearer " .. tostring(access_token) },
    })
    local data = decode(body)
    if status == 401 or status == 403 then
        local detail = data and data.error
        if type(detail) == "table" then
            detail = tostring(detail.code or "") .. ": " .. tostring(detail.message or "")
        elseif detail == nil and type(data) == "table" then
            detail = data.error_description or data.message
        end
        return nil, "没有创建应用的权限（Application.ReadWrite.All 需要目录管理员批准）: "
            .. tostring(detail or body):sub(1, 400)
    end
    if status ~= 200 and status ~= 201 then
        return nil, M.error_message(status, data, body)
    end
    if not data or not data.appId then
        return nil, "Graph 没有返回 appId: " .. tostring(body):sub(1, 300)
    end
    return { app_id = data.appId, object_id = data.id, display_name = data.displayName }
end

-- Full flow: device code -> app creation. Returns { app_id, object_id }.
function M.setup(httpc, opts)
    opts = opts or {}
    local device, err = M.request_device_code(httpc)
    if not device then return nil, err end
    local uri = device.verification_uri
        or (device.verification_uri_complete and device.verification_uri_complete:match("^[^?]+"))
        or "https://microsoft.com/devicelogin"
    print("")
    print("== 自动创建 Azure 应用（一次性）==")
    print("1. 打开: " .. tostring(uri))
    print("2. 输入代码: " .. tostring(device.user_code))
    print("授权范围: Application.ReadWrite.All（仅用于创建应用，token 不会保存）")
    print("等待授权 ...")

    local token
    token, err = M.poll(httpc, device, { sleep = opts.sleep })
    if not token then return nil, err end
    return M.create_app(httpc, token.access_token, opts.name)
end

return M
