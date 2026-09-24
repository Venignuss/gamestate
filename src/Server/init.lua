--!strict
local Node = require(script.ServerNode)
local Template = require(script.Template)
local GameState = Node.new("GameState", Template) :: Node.ServerNode<Template.Template>
rawset(GameState, "NIL", Node.NIL)
rawset(GameState, "configure", Node.configure)
return GameState
