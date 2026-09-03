--!strict
local Node = require(script.ServerNode)
local Template = require(script.Template)
local GameState = Node.new("GameState", Template) :: Node.ServerNode<Template.Template>
GameState.NIL = Node.NIL
GameState.configure = Node.configure
return GameState
