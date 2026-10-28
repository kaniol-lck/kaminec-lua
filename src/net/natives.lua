-- natives.lua: extract legacy natives archives into the plan's natives dir.
-- 1.12.2 and older rely on LWJGL 2, which does not unpack its own natives, so
-- the launcher has to extract every classifier jar listed in plan.natives
-- (produced by planner.lua) before java starts.
--
-- host must provide: exists(path), mkdir(path), extract_zip(zip, dest)
-- returns: extracted_count, missing_paths
local M = {}

function M.ensure(host, plan)
    local list = plan.natives or {}
    local extracted, missing = 0, {}
    if #list == 0 then
        return extracted, missing
    end
    if type(host.extract_zip) ~= "function" then
        error("host does not provide extract_zip")
    end
    host.mkdir(plan.natives_dir)
    for _, archive in ipairs(list) do
        if host.exists(archive.path) then
            host.extract_zip(archive.path, plan.natives_dir)
            extracted = extracted + 1
        else
            missing[#missing + 1] = archive.path
        end
    end
    return extracted, missing
end

return M
