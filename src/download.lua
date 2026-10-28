-- download.lua: apply a plan's `downloads` list with sha1 verification.
--
-- The planner only lists missing files, but a file can be present and still be
-- corrupt (interrupted copy, wrong version, manual tampering). This module adds
-- the verification half of the no-overwrite policy:
--
--   missing                                -> download
--   present, sha1 matches                  -> skip
--   present, sha1 differs, repair = false  -> keep it, count as mismatched + warn
--   present, sha1 differs, repair = true   -> download again
--
-- `decide` is a pure function so the policy is unit-testable without a disk,
-- a network, or a real host. `apply` never raises for a failed download: the
-- caller gets counters plus human-readable warnings (CLI or plugin UI decides
-- how to show them).

local sha1 = require("sha1")

local M = {}

local function norm(hash)
    if hash == nil then return nil end
    hash = tostring(hash):lower()
    if hash == "" then return nil end
    return hash
end

-- Pure policy function.
--   exists        file is already on disk
--   actual_sha1   digest of that file (nil when unknown/unreadable)
--   expected_sha1 digest from the plan (nil when the plan has none)
--   repair        allow replacing a file whose sha1 does not match
-- returns "download" | "skip" | "repair" | "mismatch"
function M.decide(exists, actual_sha1, expected_sha1, repair)
    if not exists then return "download" end
    local expected = norm(expected_sha1)
    if not expected then
        -- nothing to verify against: keep the existing file (no-overwrite policy)
        return "skip"
    end
    if norm(actual_sha1) == expected then return "skip" end
    if repair then return "repair" end
    return "mismatch"
end

-- Ask the host for a digest when it can provide one (plugin hosts may keep a
-- hash index); fall back to hashing the file directly for the CLI.
local function file_sha1(host, path)
    if type(host.sha1) == "function" then
        local ok, value = pcall(host.sha1, path)
        if ok then return norm(value) end
        return nil
    end
    local ok, value = pcall(sha1.file, path)
    if ok then return norm(value) end
    return nil
end

-- Apply every entry of plan.downloads.
-- opts.repair: replace files whose sha1 does not match (default false).
-- returns { total, downloaded, skipped, mismatched, failed, warnings }
-- A host.fetch that raises is recorded in `failed`/`warnings`; a fetch that
-- returns exactly false is treated as a failure too, anything else counts as
-- success (the CLI adapter returns the path).
function M.apply(host, plan, opts)
    opts = opts or {}
    local stats = {
        total = 0,
        downloaded = 0,
        skipped = 0,
        mismatched = 0,
        failed = 0,
        warnings = {},
    }
    for _, d in ipairs((plan and plan.downloads) or {}) do
        stats.total = stats.total + 1
        local exists = (host.exists ~= nil) and host.exists(d.path) or false
        local action
        if exists and not opts.verify and d.size and host.size then
            -- fast path: same size means almost certainly the same file, so a
            -- multi-hundred-megabyte install does not get re-hashed on every run
            local actual_size = host.size(d.path)
            if actual_size == d.size then
                action = "skip"
            else
                local actual = file_sha1(host, d.path)
                action = M.decide(exists, actual, d.sha1, opts.repair)
            end
        else
            local actual = exists and file_sha1(host, d.path) or nil
            action = M.decide(exists, actual, d.sha1, opts.repair)
        end

        if action == "skip" then
            stats.skipped = stats.skipped + 1
        elseif action == "mismatch" then
            stats.mismatched = stats.mismatched + 1
            stats.warnings[#stats.warnings + 1] = string.format(
                "sha1 mismatch (kept, use --repair to replace): %s", tostring(d.path))
        else
            local ok, err = pcall(host.fetch, d.url, d.path, {
                resume = true,
                sha1 = d.sha1,
                size = d.size,
            })
            if ok and err ~= false then
                stats.downloaded = stats.downloaded + 1
            else
                stats.failed = stats.failed + 1
                stats.warnings[#stats.warnings + 1] = string.format(
                    "download failed: %s (%s)", tostring(d.path),
                    ok and "fetch returned false" or tostring(err))
            end
        end
    end
    return stats
end

return M
