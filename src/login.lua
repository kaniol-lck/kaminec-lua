-- login.lua: Microsoft device-code login orchestration + token refresh.
-- The whole chain:
--   device code -> MSA token -> XBL user token -> XSTS token
--   -> login_with_xbox -> Minecraft profile (uuid + name)
local msa = require("msa")
local xbox = require("xbox")
local pkce = require("pkce")
local live = require("live_oauth")
local util = require("util")

local M = {}

local function print_device_prompt(device)
    print("")
    print("== Microsoft 登录 ==")
    print("1. 打开: " .. tostring(device.verification_uri))
    print("2. 输入代码: " .. tostring(device.user_code))
    if device.message then print("   " .. tostring(device.message)) end
    print("等待授权 ...")
end

local function chain_to_minecraft(httpc, msa_access_token)
    local xbl, uhs = xbox.user_authenticate(httpc, msa_access_token)
    if not xbl then return nil, uhs end
    local xsts, xuhs, xid = xbox.xsts_authorize(httpc, xbl)
    if not xsts then return nil, xuhs end
    local mc, err = xbox.login_with_xbox(httpc, xuhs, xsts)
    if not mc then return nil, err end
    return mc, nil, xid
end

-- opts.sleep is injectable for tests.
function M.device_login(httpc, client_id, opts)
    opts = opts or {}
    local device, err = msa.request_device_code(httpc, client_id)
    if not device then return nil, err end
    print_device_prompt(device)

    local token
    token, err = msa.poll(httpc, client_id, device, { sleep = opts.sleep })
    if not token then return nil, err end

    local mc, cerr, xid = chain_to_minecraft(httpc, token.access_token)
    if not mc then return nil, cerr end
    local profile
    profile, err = xbox.profile(httpc, mc.access_token)
    if not profile then return nil, err end

    return {
        type = "msa",
        name = profile.name,
        uuid = xbox.format_uuid(profile.id),
        access_token = mc.access_token,
        refresh_token = token.refresh_token,
        expires_at = os.time() + (tonumber(mc.expires_in) or 86400) - 120,
        user_type = "msa",
        xuid = xid,
        client_id = client_id,
        auth_mode = "azure",
    }
end

-- forward declaration: defined after the login flows below
local account_from_token

-- Legacy Live Connect device-code flow: no Azure app registration, user only
-- types a short code on https://www.microsoft.com/link.
-- opts.sleep is injectable for tests.
function M.live_device_login(httpc, opts)
    opts = opts or {}
    local device, err = live.request_device_code(httpc)
    if not device then return nil, err end
    print("")
    print("== Microsoft 登录（免 Azure 注册）==")
    print("1. 打开: " .. tostring(device.verification_uri or "https://www.microsoft.com/link"))
    print("2. 输入代码: " .. tostring(device.user_code))
    print("等待授权 ...")

    local token
    token, err = live.poll(httpc, device, { sleep = opts.sleep })
    if not token then return nil, err end

    local acct, aerr = account_from_token(httpc, token, live.CLIENT_ID, "live")
    if not acct then return nil, aerr end
    return acct
end

-- Ensure the account has a usable Minecraft token, refreshing the whole chain
-- when the access token is about to expire.
function M.resolve(httpc, account, client_id)
    if account.expires_at and tonumber(account.expires_at) > os.time() + 120 then
        return account
    end
    if not account.refresh_token then
        if account.auth_mode == "imported" then
            return nil, "导入的 token 已过期，请打开来源启动器刷新后重新运行 import"
        end
        return nil, "账号没有 refresh token，请重新执行 login"
    end
    local token, err
    if account.auth_mode == "live" then
        token, err = live.refresh(httpc, account.refresh_token)
    else
        token, err = msa.refresh(httpc, client_id, account.refresh_token)
    end
    if not token then return nil, err end
    local mc, cerr, xid = chain_to_minecraft(httpc, token.access_token)
    if not mc then return nil, cerr end
    account.access_token = mc.access_token
    account.refresh_token = token.refresh_token or account.refresh_token
    account.expires_at = os.time() + (tonumber(mc.expires_in) or 86400) - 120
    account.xuid = xid or account.xuid
    if account.auth_mode ~= "live" then
        account.client_id = client_id
    end
    return account
end

function account_from_token(httpc, token, client_id, auth_mode)
    local mc, err, xid = chain_to_minecraft(httpc, token.access_token)
    if not mc then return nil, err end
    local profile, perr = xbox.profile(httpc, mc.access_token)
    if not profile then return nil, perr end
    return {
        type = "msa",
        name = profile.name,
        uuid = xbox.format_uuid(profile.id),
        access_token = mc.access_token,
        refresh_token = token.refresh_token,
        expires_at = os.time() + (tonumber(mc.expires_in) or 86400) - 120,
        user_type = "msa",
        xuid = xid,
        client_id = client_id,
        auth_mode = auth_mode or "azure",
    }
end

-- Browser authorization-code flow with a local loopback redirect + PKCE.
-- opts.loopback / opts.sleep are injectable for tests; opts.port pins a port.
function M.browser_login(httpc, client_id, opts)
    opts = opts or {}
    local loop = opts.loopback or require("loopback")
    local state = opts.state or pkce.random_string(24)
    local verifier = opts.verifier or pkce.verifier()
    local challenge = pkce.challenge(verifier)
    local outfile = opts.outfile or os.tmpname()
    local timeout = tonumber(opts.timeout) or 180

    local started, port, redirect, url
    for _ = 1, 3 do
        port = tonumber(opts.port) or (50000 + math.random(0, 9000))
        redirect = "http://localhost:" .. port .. "/"
        url = msa.authorize_url(client_id, redirect, state, challenge)
        loop.start(port, outfile, { timeout_ms = timeout * 1000 })
        if opts.sleep then opts.sleep(1) else os.execute("ping -n 2 127.0.0.1 >nul") end
        if util.exists(outfile) then
            local peek = util.read(outfile)
            if peek:match("^ERROR") then
                os.remove(outfile)
            else
                started = true
                break
            end
        else
            started = true
            break
        end
    end
    if not started then return nil, "无法启动本地回调服务器（端口被占用）" end

    print("已在浏览器打开 Microsoft 登录页；本地回调端口 " .. tostring(port))
    loop.open(url)
    local raw = loop.wait(outfile, timeout)
    if not raw then return nil, "等待浏览器授权超时" end
    if raw:match("^ERROR") then return nil, "本地回调服务器错误: " .. raw end

    local code, cerr = msa.parse_redirect(raw, state)
    if not code then return nil, cerr end
    local token, terr = msa.exchange_code(httpc, client_id, code, redirect, verifier)
    if not token then return nil, terr end
    return account_from_token(httpc, token, client_id)
end

return M
