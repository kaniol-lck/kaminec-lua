-- accounts.lua: tiny JSON account store (workdir/accounts.json).
local json = require("json")
local util = require("util")

local M = {}

function M.path(workdir)
    return util.join(workdir, "accounts.json")
end

function M.load(path)
    if not util.exists(path) then
        return { accounts = {}, selected = nil }
    end
    local ok, data = pcall(json.decode, util.read(path))
    if not ok or type(data) ~= "table" then
        return { accounts = {}, selected = nil }
    end
    data.accounts = data.accounts or {}
    return data
end

function M.save(path, data)
    util.write(path, json.encode(data) .. "\n")
end

function M.upsert(data, account)
    data.accounts = data.accounts or {}
    data.accounts[account.name] = account
    data.selected = account.name
    return account
end

function M.find(data, name)
    return data.accounts and data.accounts[name] or nil
end

function M.list(data)
    local names = {}
    for name in pairs(data.accounts or {}) do names[#names + 1] = name end
    table.sort(names)
    return names
end

return M
