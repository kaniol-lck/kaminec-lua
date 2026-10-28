-- tests/browser_login_smoke.lua: real loopback server + fake Microsoft HTTP.
-- Proves the launcher can receive the OAuth code by itself, with no manual
-- copy/paste: the fake "browser" just GETs the callback URL once.
package.path = package.path .. ";./src/?.lua;./src/core/?.lua;./src/net/?.lua;./src/auth/?.lua;./src/accounts/?.lua;./src/host/?.lua;./src/vendor/?.lua"

local json = require("json")
local util = require("util")
local login = require("login")
local loopback = require("loopback")

local state = "smoke-state"
local port = 51236
local outfile = util.abs("tests/tmp-browser-cb.txt")
os.remove(outfile)

local responses = {
    { 200, json.encode({ access_token = "msa-token", refresh_token = "rt" }) },
    { 200, json.encode({ Token = "xbl", DisplayClaims = { xui = { { uhs = "uhs" } } } }) },
    { 200, json.encode({ Token = "xsts", DisplayClaims = { xui = { { uhs = "uhs", xid = "99" } } } }) },
    { 200, json.encode({ access_token = "mc-token", expires_in = 86400 }) },
    { 200, json.encode({ id = "00112233445566778899aabbccddeeff", name = "SmokeUser" }) },
}
local calls, opened
local function make(kind)
    return function(url, payload, opts)
        calls[#calls + 1] = { kind = kind, url = url, payload = payload, opts = opts }
        local r = table.remove(responses, 1)
        if not r then error("unexpected " .. kind .. " call: " .. tostring(url)) end
        return r[1], r[2]
    end
end
local httpc = { calls = calls or {}, post_form = make("form"), post_json = make("json"), get_json = make("get") }
calls = httpc.calls

local loop = {
    start = loopback.start,
    wait = loopback.wait,
    open = function(url)
        opened = url
        -- act as the browser: hit the loopback callback with a valid code
        local cb = "http://localhost:" .. port .. "/?code=SMOKE-CODE&state=" .. state
        os.execute('curl -s -o NUL "' .. cb .. '"')
    end,
}

local acct, err = login.browser_login(httpc, "client-smoke", {
    state = state,
    verifier = "smoke-verifier",
    port = port,
    loopback = loop,
    outfile = outfile,
})

print("opened: " .. tostring(opened))
print("exchange: " .. tostring(calls[1] and calls[1].url))
print("account: " .. tostring(acct and acct.name) .. " / " .. tostring(acct and acct.uuid))

local ok = acct and acct.name == "SmokeUser"
    and acct.uuid == "00112233-4455-6677-8899-aabbccddeeff"
    and calls[1].payload.code == "SMOKE-CODE"
    and calls[1].payload.code_verifier == "smoke-verifier"
    and opened and opened:find("state=" .. state, 1, true) ~= nil

os.remove(outfile)
if ok then
    print("browser login smoke: PASS (no manual code copy)")
    os.exit(0)
end
print("browser login smoke: FAIL " .. tostring(err))
os.exit(1)
