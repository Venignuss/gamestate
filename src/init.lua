--!strict
-- PLACEHOLDER / INFERRED: I don't have your actual root GameState.lua, so this
-- is the standard "pick the right realm" pattern. Replace with your real file
-- if it differs (e.g. if you also handle Studio edit-mode, plugins, etc).

local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return require(script.Server)
else
	return require(script.Client)
end
