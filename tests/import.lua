-- tests/import.lua: offline tests for importing the official launcher token.
package.path = package.path .. ";./src/?.lua"

local util = require("util")
local json = require("json")
local importer = require("accounts_import")
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

print("import: official launcher only")
local stores = importer.store_paths()
local all_official = true
for _, s in ipairs(stores) do
    if s.source ~= "official" and s.source ~= "official-store" then all_official = false end
end
check("only official stores scanned", all_official)

local dir = util.abs("tests/tmp-import")
util.mkdir(dir)
local official = util.join(dir, "launcher_accounts.json")

util.write(official, json.encode({
    accounts = {
        ["u1"] = {
            accessToken = "tok-official",
            accessTokenExpiresAt = "2027-01-01T00:00:00Z",
            type = "Xbox",
            minecraftProfile = { id = "0123456789abcdef0123456789abcdef", name = "Steve" },
            refreshToken = "should-not-be-imported",
        },
    },
}))

local found = importer.scan({ { source = "official", path = official } })
check("found one account", #found == 1, tostring(#found))
local acct = found[1]
check("account name", acct and acct.name == "Steve")
check("access token", acct and acct.access_token == "tok-official")
check("uuid normalized", acct and acct.uuid == "01234567-89ab-cdef-0123-456789abcdef")
check("expiry parsed", acct and acct.expires_at and acct.expires_at > os.time())
check("auth mode imported", acct and acct.auth_mode == "imported")
check("refresh token dropped", acct and acct.refresh_token == nil, tostring(acct and acct.refresh_token))

local expired = { name = "Old", auth_mode = "imported", access_token = "x", expires_at = os.time() - 3600 }
local _, err = auth.resolve({}, expired, nil)
check("expired import explains refresh", err and err:find("已过期") ~= nil, err)

os.remove(official)
print("")
print(string.format("%d failure(s)", failures))
os.exit(failures > 0 and 1 or 0)
