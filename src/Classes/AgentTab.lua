-- Path of Building
--
-- Module: Agent Tab
-- Tab for the LLM Agent.
--

local t_insert = table.insert
local t_remove = table.remove
local dkjson = require "dkjson"

local AgentTabClass = newClass("AgentTab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()

	self.build = build
	
	-- Agent Service
	self.agentService = new("AgentService", build)

	self.history = { } 
	
	-- Controls
	-- Display (History) - Editable for copy-paste/modification by user
	-- code=nil to enable wrapping and variable width font
	self.controls.display = new("EditControl", {"TOPLEFT",self,"TOPLEFT"}, {10, 10, 0, 0}, "", "Histórico da conversa aparecerá aqui...", "^%C\t\n", nil, nil, 14, nil)
	
	-- Input
	self.controls.input = new("EditControl", {"BOTTOMLEFT",self,"BOTTOMLEFT"}, {10, -10, 0, 80}, "", "Pergunte ao Agente sobre sua build...", "^%C\t\n", nil, nil, 14, true)
	
	-- Override OnKeyDown to capture Enter (since lineHeight makes it multiline by default)
	local superOnKeyDown = self.controls.input.OnKeyDown
	self.controls.input.OnKeyDown = function(control, key)
		if key == "RETURN" then
			self:OnSend()
			-- Reset cursor/scroll if needed, but OnSend clears text
			return control
		end
		if superOnKeyDown then
			return superOnKeyDown(control, key)
		end
		return control
	end
	
	-- Send Button
	self.controls.send = new("ButtonControl", {"LEFT",self.controls.input,"RIGHT"}, {10, 0, 80, 80}, "Enviar", function()
		self:OnSend()
	end)
	
	-- Log Init
	local file, err = io.open("AgentActions.log", "a")
	if file then
		file:write(string.format("[%s] AgentTab Initialized\n", os.date("%Y-%m-%d %H:%M:%S")))
		file:close()
	end
	
	-- Clear Button
	self.controls.clear = new("ButtonControl", {"TOPRIGHT",self,"TOPRIGHT"}, {-10, 10, 60, 20}, "Limpar", function()
		self.controls.display:SetText("")
		self.history = {}
	end)

	-- Layout adjustments
	self.controls.display.width = function() return self.width - 20 end
	self.controls.display.height = function() return self.height - 110 end
	self.controls.input.width = function() return self.width - 120 end

end)

function AgentTabClass:OnSend()
	local text = self.controls.input.buf
	if not text or text:match("^%s*$") then return end
	
	self:AppendMessage("Você", text)
	self.controls.input:SetText("")
	
	-- Settings from Config 
	local provider = self.build.configTab.input["LLM_Provider"] or "Ollama"
	local endpoint = self.build.configTab.input["LLM_Endpoint"] or "http://localhost:11434/api/generate"
	local model = self.build.configTab.input["LLM_Model"] or "llama3"
	local apiKey = self.build.configTab.input["LLM_ApiKey"] or ""
	
	self.agentService:SetProvider(provider, endpoint, model, apiKey)
	
	self:AppendMessage("Agente", "Pensando...")
	
	-- Prepare history for context
	-- Ideally we parse self.controls.display.buf back into history, but simplistic approach first
	local requestHistory = {} 
	-- TODO: populate requestHistory from self.history if needed for multi-turn
	
	self.agentService:SendPrompt(text, requestHistory, function(response, err)
		-- Remove "Thinking..."
		local currentText = self.controls.display.buf
		local s, e = currentText:find("\nAgente: Pensando...$")
		if s then
			self.controls.display:SetText(currentText:sub(1, s-1))
		end
		
		if err then
			self:AppendMessage("Sistema", "Erro: " .. err)
			return
		end
		
		-- Try to parse as JSON action (Extract JSON if embedded in text)
		-- Look for { "action": ... } pattern or just the first { ... } block
		local jsonStart, jsonEnd = response:find("%b{}")
		local actionData
		
		if jsonStart then
			local possibleJson = response:sub(jsonStart, jsonEnd)
			local decoded, jsonErr = dkjson.decode(possibleJson)
			if decoded and decoded.action then
				actionData = decoded
			end
		end

		if actionData and actionData.action then
			self:AppendMessage("Agente", "Executando a\231\227o: " .. actionData.action .. "...")
			local success, result = self.agentService:ExecuteAction(actionData.action, actionData.params)
			if success then
				self:AppendMessage("Sistema", "Sucesso: " .. tostring(result))
			else
				self:AppendMessage("Sistema", "Falha: " .. tostring(result))
			end
		else
			self:AppendMessage("Agente", response)
		end
	end)
end

-- Helper to convert UTF-8 to ANSI (Windows-1252 approximation) for PoB display
local function utf8_to_ansi(str)
	if not str then return "" end
	return str:gsub("[\194-\244][\128-\191]*", function(c)
		local b1, b2 = c:byte(1, 2)
		-- Extended Latin1/Windows-1252 mapping
		if b1 == 194 then
			if b2 == 160 then return " " end -- Non-breaking space
		elseif b1 == 195 then
			if b2 == 128 then return "\192" -- À
			elseif b2 == 129 then return "\193" -- Á
			elseif b2 == 130 then return "\194" -- Â
			elseif b2 == 131 then return "\195" -- Ã
			elseif b2 == 135 then return "\199" -- Ç
			elseif b2 == 137 then return "\201" -- É
			elseif b2 == 138 then return "\202" -- Ê
			elseif b2 == 141 then return "\205" -- Í
			elseif b2 == 147 then return "\211" -- Ó
			elseif b2 == 148 then return "\212" -- Ô
			elseif b2 == 149 then return "\213" -- Õ
			elseif b2 == 154 then return "\218" -- Ú
			elseif b2 == 156 then return "\220" -- Ü
			elseif b2 == 160 then return "\224" -- à
			elseif b2 == 161 then return "\225" -- á
			elseif b2 == 162 then return "\226" -- â
			elseif b2 == 163 then return "\227" -- ã
			elseif b2 == 167 then return "\231" -- ç
			elseif b2 == 169 then return "\233" -- é
			elseif b2 == 170 then return "\234" -- ê
			elseif b2 == 173 then return "\237" -- í
			elseif b2 == 179 then return "\243" -- ó
			elseif b2 == 180 then return "\244" -- ô
			elseif b2 == 181 then return "\245" -- õ
			elseif b2 == 186 then return "\250" -- ú
			elseif b2 == 188 then return "\252" -- ü
			end
		end
		return "?" -- Fallback for unsupported chars
	end)
end

function AgentTabClass:AppendMessage(role, content)
	local prefix = ""
	if role == "Você" then
		prefix = "Você: "
	elseif role == "Agente" then
		prefix = "Agente: "
	elseif role == "Sistema" then
		prefix = "Sistema: "
	end
	
	local ansiContent = utf8_to_ansi(content)
	local currentText = self.controls.display.buf
	if currentText and #currentText > 0 then
		self.controls.display:SetText(currentText .. "\n\n" .. prefix .. ansiContent)
	else
		self.controls.display:SetText(prefix .. ansiContent)
	end
end

function AgentTabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height
	
	self:ProcessControlsInput(inputEvents, viewPort)
	-- main:DrawBackground(viewPort) -- Using footer background from Build.lua
	self:DrawControls(viewPort)
end

return AgentTabClass
