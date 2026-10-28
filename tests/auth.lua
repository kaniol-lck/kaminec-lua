-- tests/auth.lua: offline tests for the Microsoft login chain.
-- No network: every httpc is a scripted fake.
package.path = package.path .. ";./src/?.lua"

local util = require("util")
local json = require("json")
local msa = require("msa")
local xbox = require("xbox")
local accounts = require("accounts")
local auth = require("login")

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and (": " .. detail) or ""))
    end
end

local function fake(responses)
    local calls = {}
    local function make(kind)
        return function(url, payload, opts)
            calls[#calls + 1] = { kind = kind, url = url, payload = payload, opts = opts }
            local r = table.remove(responses, 1)
            if not r then error("unexpected " .. kind .. " call: " .. tostring(url)) end
            return r[1], r[2]
        end
    end
    return {
        calls = calls,
        post_form = make("form"),
        post_json = make("json"),
        get_json = make("get"),
    }
end

local function b64url(s)
    local map = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    local out, bits, n = {}, 0, 0
    for i = 1, #s do
        bits = bits * 256 + s:byte(i)
        n = n + 8
        while n >= 6 do
            local idx = math.floor(bits / (2 ^ (n - 6))) % 64
            out[#out + 1] = map:sub(idx + 1, idx + 1)
            n = n - 6
            bits = bits % (2 ^ n)
        end
    end
    if n > 0 then
        local idx = math.floor(bits * (2 ^ (6 - n))) % 64
        out[#out + 1] = map:sub(idx + 1, idx + 1)
    end
    return table.concat(out)
end

print("msa: device code + polling")
local f = fake({ { 200, json.encode({
    device_code = "dc-1", user_code = "UC-1",
    verification_uri = "https://microsoft.com/devicelogin",
    expires_in = 900, interval = 5,
}) } })
local dev, err = msa.request_device_code(f, "client-1")
check("device code parsed", dev and dev.device_code == "dc-1")
check("device code request url", f.calls[1].url == msa.DEVICE_CODE_URL)
check("device code scope", f.calls[1].payload.scope == msa.SCOPE)
check("device code client id", f.calls[1].payload.client_id == "client-1")

f = fake({
    { 400, json.encode({ error = "authorization_pending" }) },
    { 200, json.encode({ access_token = "msa-tok", refresh_token = "rt" }) },
})
local token
token, err = msa.poll(f, "client-1", { device_code = "dc", interval = 1, expires_in = 60 },
    { sleep = function() end })
check("poll pending then success", token and token.access_token == "msa-tok", err)
check("poll waited twice", #f.calls == 2)

f = fake({ { 400, json.encode({ error = "expired_token" }) } })
token, err = msa.poll(f, "client-1", { device_code = "dc", interval = 1, expires_in = 60 },
    { sleep = function() end })
check("poll expired returns error", token == nil and err ~= nil)

print("xbox: chain requests and errors")
f = fake({ { 200, json.encode({ Token = "xbl-tok", DisplayClaims = { xui = { { uhs = "uhs-1" } } } }) } })
local xbl, uhs = xbox.user_authenticate(f, "msa-tok")
check("xbl token", xbl == "xbl-tok" and uhs == "uhs-1")
check("xbl RpsTicket", f.calls[1].payload.Properties.RpsTicket == "d=msa-tok")
check("xbl RelyingParty", f.calls[1].payload.RelyingParty == "http://auth.xboxlive.com")
check("xbl SiteName", f.calls[1].payload.Properties.SiteName == "user.auth.xboxlive.com")

f = fake({ { 401, json.encode({ XErr = 2148916233 }) } })
local _, xerr = xbox.xsts_authorize(f, "xbl")
check("xsts error mapped", xerr and xerr:find("Xbox Live 档案") ~= nil, xerr)

f = fake({ { 200, json.encode({ Token = "xsts-tok", DisplayClaims = { xui = { { uhs = "uhs-2", xid = "123" } } } }) } })
local xsts, xuhs, xid = xbox.xsts_authorize(f, "xbl")
check("xsts token/uhs/xid", xsts == "xsts-tok" and xuhs == "uhs-2" and xid == "123")
check("xsts sandbox", f.calls[1].payload.Properties.SandboxId == "RETAIL")
check("xsts user token", f.calls[1].payload.Properties.UserTokens[1] == "xbl")

f = fake({ { 200, json.encode({ access_token = "mc-tok", expires_in = 86400 }) } })
local mc = xbox.login_with_xbox(f, "uhs-2", "xsts-tok")
check("mc token", mc and mc.access_token == "mc-tok")
check("mc identityToken", f.calls[1].payload.identityToken == "XBL3.0 x=uhs-2;xsts-tok")

f = fake({ { 404, "{}" } })
local prof, perr = xbox.profile(f, "mc-tok")
check("profile 404 -> no java edition", prof == nil and perr:find("Java Edition") ~= nil)
check("profile bearer header", f.calls[1].payload.headers.Authorization == "Bearer mc-tok")

check("uuid formatting", xbox.format_uuid("0123456789abcdef0123456789abcdef")
    == "01234567-89ab-cdef-0123-456789abcdef")

local jwt = "h." .. b64url(json.encode({ xid = "42", uhs = "u" })) .. ".s"
local claims = xbox.jwt_claims(jwt)
check("jwt claims decode", claims and claims.xid == "42")

print("accounts: store roundtrip")
local dir = util.abs("tests/tmp-auth")
util.mkdir(dir)
local path = accounts.path(dir)
os.remove(path)
local store = accounts.load(path)
check("empty store", #accounts.list(store) == 0)
accounts.upsert(store, {
    name = "Steve", uuid = "u-1", access_token = "a", refresh_token = "r",
    expires_at = os.time() + 3600, user_type = "msa",
})
accounts.save(path, store)
local store2 = accounts.load(path)
check("account persisted", store2.accounts.Steve and store2.accounts.Steve.access_token == "a")
check("selected set", store2.selected == "Steve")

print("login: refresh and full device flow")
local expired = { name = "Steve", access_token = "old", refresh_token = "rt-old", expires_at = os.time() - 10 }
f = fake({
    { 200, json.encode({ access_token = "msa-2", refresh_token = "rt-new" }) },
    { 200, json.encode({ Token = "xbl-2", DisplayClaims = { xui = { { uhs = "uhs-2" } } } }) },
    { 200, json.encode({ Token = "xsts-2", DisplayClaims = { xui = { { uhs = "uhs-2", xid = "77" } } } }) },
    { 200, json.encode({ access_token = "mc-2", expires_in = 86400 }) },
})
local refreshed, rerr = auth.resolve(f, expired, "cid")
check("refresh worked", refreshed and refreshed.access_token == "mc-2", rerr)
check("refresh token rotated", refreshed and refreshed.refresh_token == "rt-new")
check("refresh xuid", refreshed and refreshed.xuid == "77")
check("refresh grant type", f.calls[1].payload.grant_type == "refresh_token")

f = fake({
    { 200, json.encode({
        device_code = "dc", user_code = "UC", verification_uri = "https://x",
        expires_in = 900, interval = 5,
    }) },
    { 200, json.encode({ access_token = "msa", refresh_token = "rt" }) },
    { 200, json.encode({ Token = "xbl", DisplayClaims = { xui = { { uhs = "uhs" } } } }) },
    { 200, json.encode({ Token = "xsts", DisplayClaims = { xui = { { uhs = "uhs", xid = "9" } } } }) },
    { 200, json.encode({ access_token = "mc", expires_in = 86400 }) },
    { 200, json.encode({ id = "0123456789abcdef0123456789abcdef", name = "Steve" }) },
})
local acct, aerr = auth.device_login(f, "cid", { sleep = function() end })
check("device login account", acct and acct.name == "Steve" and acct.uuid == "01234567-89ab-cdef-0123-456789abcdef", aerr)
check("device login token chain", acct and acct.access_token == "mc" and acct.refresh_token == "rt")
check("device login user type", acct and acct.user_type == "msa")

print("browser flow: sha256 / pkce / authorize url")
local sha256 = require("sha256")
local pkce = require("pkce")
check("sha256 empty", sha256.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("sha256 abc", sha256.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("pkce challenge vector",
    pkce.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

local auth_url = msa.authorize_url("cid", "http://localhost:12345/", "st", "chal")
check("authorize endpoint", auth_url:find("login.microsoftonline.com/consumers/oauth2/v2.0/authorize", 1, true) ~= nil)
check("authorize client id", auth_url:find("client_id=cid", 1, true) ~= nil)
check("authorize redirect encoded", auth_url:find("redirect_uri=http%3A%2F%2Flocalhost%3A12345%2F", 1, true) ~= nil)
check("authorize pkce", auth_url:find("code_challenge=chal", 1, true) ~= nil and auth_url:find("code_challenge_method=S256", 1, true) ~= nil)
check("authorize state", auth_url:find("state=st", 1, true) ~= nil)

local code, perr = msa.parse_redirect("/auth?code=CODE-1&state=st", "st")
check("parse redirect code", code == "CODE-1", perr)
local _, serr = msa.parse_redirect("/auth?code=X&state=other", "st")
check("parse redirect state mismatch", serr and serr:find("state") ~= nil, serr)
local _, eerr = msa.parse_redirect("/auth?error=access_denied&error_description=denied", "st")
check("parse redirect error", eerr and eerr:find("denied") ~= nil, eerr)

f = fake({ { 200, json.encode({ access_token = "msa", refresh_token = "rt" }) } })
local toks = msa.exchange_code(f, "cid", "CODE", "http://localhost:1/auth", "ver")
check("exchange token", toks and toks.access_token == "msa")
check("exchange grant type", f.calls[1].payload.grant_type == "authorization_code")
check("exchange code verifier", f.calls[1].payload.code_verifier == "ver")
check("exchange redirect uri", f.calls[1].payload.redirect_uri == "http://localhost:1/auth")

print("browser flow: orchestration")
local opened_url
local loop = {
    start = function() end,
    open = function(url) opened_url = url end,
    wait = function() return "/auth?code=CODE-2&state=st-2" end,
}
f = fake({
    { 200, json.encode({ access_token = "msa-2", refresh_token = "rt-2" }) },
    { 200, json.encode({ Token = "xbl", DisplayClaims = { xui = { { uhs = "uhs" } } } }) },
    { 200, json.encode({ Token = "xsts", DisplayClaims = { xui = { { uhs = "uhs", xid = "55" } } } }) },
    { 200, json.encode({ access_token = "mc", expires_in = 86400 }) },
    { 200, json.encode({ id = "fedcba9876543210fedcba9876543210", name = "Alex" }) },
})
local browser_acct, berr = auth.browser_login(f, "cid-browser", {
    state = "st-2", verifier = "ver-2", port = 23456,
    loopback = loop, sleep = function() end, outfile = os.tmpname() .. ".cb",
})
check("browser login account", browser_acct and browser_acct.name == "Alex", berr)
check("browser login uuid", browser_acct and browser_acct.uuid == "fedcba98-7654-3210-fedc-ba9876543210")
check("browser login opened url", opened_url and opened_url:find("state=st-2", 1, true) ~= nil)
check("browser login pkce challenge", opened_url and opened_url:find("code_challenge=" .. pkce.challenge("ver-2"), 1, true) ~= nil)
check("browser login exchange body", f.calls[1].payload.code == "CODE-2")

print("live flow: no Azure registration (device code)")
local live = require("live_oauth")
f = fake({ { 200, json.encode({
    user_code = "UC-9", device_code = "DC-9",
    verification_uri = "https://www.microsoft.com/link",
    interval = 5, expires_in = 900,
}) } })
local ldev, lerr = live.request_device_code(f)
check("live device code", ldev and ldev.user_code == "UC-9", lerr)
check("live connect url", f.calls[1].url == live.CONNECT_URL)
check("live client id", f.calls[1].payload.client_id == "00000000402b5328")
check("live response type", f.calls[1].payload.response_type == "device_code")

f = fake({
    { 400, json.encode({ error = "authorization_pending" }) },
    { 200, json.encode({ access_token = "live-msa", refresh_token = "live-rt" }) },
})
local ltok
ltok, lerr = live.poll(f, { device_code = "DC", interval = 1, expires_in = 60 }, { sleep = function() end })
check("live poll pending then token", ltok and ltok.access_token == "live-msa", lerr)
check("live poll grant", f.calls[2].payload.grant_type == live.DEVICE_GRANT)

f = fake({ { 200, json.encode({ access_token = "live-msa", refresh_token = "live-rt" }) } })
local ltoks = live.refresh(f, "old-rt")
check("live refresh", ltoks and ltoks.access_token == "live-msa")
check("live refresh grant", f.calls[1].payload.grant_type == "refresh_token")

f = fake({
    { 200, json.encode({ user_code = "UC", device_code = "DC",
        verification_uri = "https://www.microsoft.com/link", interval = 1, expires_in = 900 }) },
    { 200, json.encode({ access_token = "live-msa", refresh_token = "live-rt" }) },
    { 200, json.encode({ Token = "xbl", DisplayClaims = { xui = { { uhs = "uhs" } } } }) },
    { 200, json.encode({ Token = "xsts", DisplayClaims = { xui = { { uhs = "uhs", xid = "88" } } } }) },
    { 200, json.encode({ access_token = "mc", expires_in = 86400 }) },
    { 200, json.encode({ id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name = "LiveUser" }) },
})
local live_acct, laerr = auth.live_device_login(f, { sleep = function() end })
check("live login account", live_acct and live_acct.name == "LiveUser", laerr)
check("live login auth_mode", live_acct and live_acct.auth_mode == "live")
check("live login client id", live_acct and live_acct.client_id == "00000000402b5328")

local live_expired = { name = "LiveUser", auth_mode = "live", refresh_token = "rt-live", expires_at = os.time() - 10 }
f = fake({
    { 200, json.encode({ access_token = "live-msa2", refresh_token = "rt-live2" }) },
    { 200, json.encode({ Token = "xbl", DisplayClaims = { xui = { { uhs = "uhs" } } } }) },
    { 200, json.encode({ Token = "xsts", DisplayClaims = { xui = { { uhs = "uhs", xid = "88" } } } }) },
    { 200, json.encode({ access_token = "mc2", expires_in = 86400 }) },
})
local lr, lrerr = auth.resolve(f, live_expired, "unused-cid")
check("live resolve refresh", lr and lr.access_token == "mc2", lrerr)
check("live resolve uses live endpoint", f.calls[1].url == live.TOKEN_URL)

os.remove(path)
print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
