--!strict
-- Entry point: picks the realm-appropriate implementation. Both Server/init.lua
-- and Client/init.lua build their own root GameState node from the same
-- SharedNode logic, so this is the only branch point callers need.

local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return require(script.Server)
else
	return require(script.Client)
end
