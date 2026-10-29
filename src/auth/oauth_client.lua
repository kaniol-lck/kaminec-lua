-- oauth_client.lua: built-in Azure public client for Microsoft login.
-- This application has passed the Minecraft API review (2026-10-29), so
-- `login` works without users registering their own Azure application.
-- It can still be overridden by --client-id, KAMINEC_MSA_CLIENT_ID, or
-- <launcher-root>/msa.json.
local M = {}

M.DEFAULT_CLIENT_ID = "236a2afc-b829-4da4-8d81-c22e637bded8"

return M
