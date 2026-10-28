-- tests/graph_setup.lua: offline tests for the Azure-app auto-creation helper.
package.path = package.path .. ";./src/?.lua"

local json = require("json")
local graph = require("graph_setup")

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
    return { calls = calls, post_form = make("form"), post_json = make("json") }
end

print("graph setup: device code + app creation")
local f = fake({
    { 200, json.encode({
        device_code = "gdc", user_code = "GUC",
        verification_uri = "https://microsoft.com/devicelogin",
        interval = 1, expires_in = 900,
    }) },
    { 200, json.encode({ access_token = "graph-token" }) },
    { 201, json.encode({ appId = "app-123", id = "obj-1", displayName = "Kaminec-Spike" }) },
})
local app, err = graph.setup(f, { sleep = function() end, name = "Kaminec-Spike" })
check("device code request", f.calls[1].url == graph.DEVICE_URL)
check("graph scope", f.calls[1].payload.scope == graph.SCOPE)
check("token request", f.calls[2].url == graph.TOKEN_URL)
check("app created", app and app.app_id == "app-123", err)
check("app request url", f.calls[3].url == graph.APP_URL)
check("app bearer token", f.calls[3].opts.headers.Authorization == "Bearer graph-token")
check("app public client redirect", f.calls[3].payload.publicClient.redirectUris[1] == "http://localhost")
check("app fallback public client", f.calls[3].payload.isFallbackPublicClient == true)
check("app sign-in audience", f.calls[3].payload.signInAudience == "AzureADandPersonalMicrosoftAccount")

print("graph setup: permission denied")
f = fake({
    { 200, json.encode({
        device_code = "gdc", user_code = "GUC",
        verification_uri = "https://microsoft.com/devicelogin",
        interval = 1, expires_in = 900,
    }) },
    { 200, json.encode({ access_token = "graph-token" }) },
    { 403, json.encode({ error = "Authorization_RequestDenied" }) },
})
local app2, err2 = graph.setup(f, { sleep = function() end })
check("permission error surfaced", app2 == nil and err2 ~= nil and err2:find("权限") ~= nil, err2)

print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
