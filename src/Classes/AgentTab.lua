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
	-- Provider Selection (Ollama / Google / OpenAI)
	self.controls.provider = new("DropDownControl", {"TOPLEFT",self,"TOPLEFT"}, {10, 10, 100, 20}, {"Ollama", "Google", "OpenAI"}, function(index, value)
		self.agentService:SetProvider(value, self.controls.endpoint.buf, self.controls.model.buf, self.controls.apiKey.buf)
		self:UpdateControlsVisibility()
	end)
	self.controls.provider.selIndex = 1
	
	-- API Key (Hidden for Ollama)
	self.controls.apiKey = new("EditControl", {"LEFT",self.controls.provider,"RIGHT"}, {5, 0, 180, 20}, "", "API Key", nil, nil, nil, nil, function(buf)
		self.agentService.apiKey = buf
	end)
	
	-- Model / Endpoint (Advanced)
	self.controls.model = new("EditControl", {"TOPLEFT",self.controls.provider,"BOTTOMLEFT"}, {0, 5, 285, 20}, "llama3", "Model Name", nil, nil, nil, nil, function(buf)
		self.agentService.model = buf
	end)
	
	self.controls.endpoint = new("EditControl", {"TOPLEFT",self.controls.model,"BOTTOMLEFT"}, {0, 5, 285, 20}, "http://localhost:11434/api/generate", "Endpoint Base URL", nil, nil, nil, nil, function(buf)
		self.agentService.endpoint = buf
	end)

	-- Output Display (History)
	self.controls.display = new("EditControl", {"TOPLEFT",self,"TOPLEFT"}, {10, 90, 0, 0}, "", "Histórico da conversa aparecerá aqui...", "^%C\t\n", nil, nil, 14, nil)
	
	-- Input (Dynamic Height)
	self.inputHeight = 20
	self.controls.input = new("EditControl", {"BOTTOMLEFT",self,"BOTTOMLEFT"}, {10, -10, 0, 20}, "", "Pergunte ao Agente...", "^%C\t\n", nil, function(buf)
        -- Dynamic resizing logic
        local lineCount = 1
        -- Approx lines based on characters (Average char width ~7px, minimal calc)
        if #buf > 0 then
            local width = self.controls.input.width
            if type(width) == "function" then
                width = width()
            end
            local charWidth = 7 
            local charsPerLine = math.max(1, math.floor(width / charWidth))
            lineCount = math.ceil(#buf / charsPerLine)
            -- Count explicit newlines too
            local _, newlines = buf:gsub("\n", "")
            lineCount = math.max(lineCount, newlines + 1)
        end
        
        local newHeight = math.min(100, math.max(30, lineCount * 20)) -- Min 30px, Max 100px (5 lines)
        if self.inputHeight ~= newHeight then
            self.inputHeight = newHeight
            self.controls.input.height = newHeight
        end
    end, 14, nil) -- nil code ensures wrapping

	-- Override OnKeyDown to capture Enter
	local superOnKeyDown = self.controls.input.OnKeyDown
	self.controls.input.OnKeyDown = function(control, key)
		if key == "RETURN" then
			if IsKeyDown("SHIFT") then
				-- Insert newline on Shift+Enter
				control:Insert("\n")
			else
				self:OnSend()
			end
			return control
		end
		if superOnKeyDown then
			return superOnKeyDown(control, key)
		end
		return control
	end
	
	-- Send Button (Aligned with Input Bottom) 
	self.controls.send = new("ButtonControl", {"BOTTOMRIGHT",self,"BOTTOMRIGHT"}, {-10, -10, 60, 20}, "Enviar", function()
		self:OnSend()
	end)
	
	-- Clear Button (Left of Send)
	self.controls.clear = new("ButtonControl", {"RIGHT",self.controls.send,"LEFT"}, {-5, 0, 60, 20}, "Limpar", function()
		self.controls.display:SetText("")
		self.history = {}
	end)
	
	-- Layout adjustments
	self.controls.display.width = function() return self.width - 20 end
    -- Display height accounts for Input height dynamic + Top controls (90) + Padding (20)
	self.controls.display.height = function() return self.height - 90 - self.inputHeight - 20 end 
	
    -- Input Width: Full width minus buttons (60*2 + padding)
	self.controls.input.width = function() return self.width - 20 - 130 end
	
	self:UpdateControlsVisibility()
end)

function AgentTabClass:UpdateControlsVisibility()
	local provider = self.controls.provider.list[self.controls.provider.selIndex]
	if provider == "Ollama" then
		self.controls.apiKey.shown = false
		self.controls.endpoint.buf = "http://localhost:11434/api/generate"
		if self.controls.model.buf == "" or self.controls.model.buf == "gemini-2.0-flash" then
			self.controls.model:SetText("llama3")
			self.agentService.model = "llama3"
		end
	elseif provider == "Google" then
		self.controls.apiKey.shown = true
		self.controls.endpoint.buf = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
		self.controls.model:SetText("gemini-2.0-flash")
		self.agentService.model = "gemini-2.0-flash"
	elseif provider == "OpenAI" then
		self.controls.apiKey.shown = true
		self.controls.endpoint.buf = "https://api.openai.com/v1/chat/completions"
		self.controls.model:SetText("gpt-3.5-turbo")
	end
	
	self.agentService.provider = provider
	self.agentService.endpoint = self.controls.endpoint.buf
end


function AgentTabClass:OnSend()
	local text = self.controls.input.buf
	if not text or text:match("^%s*$") then return end
	
	self:AppendMessage("Voc\234", text) -- Use ANSI for "Você" explicitly to avoid encoding issues
	self.controls.input:SetText("")
	
	-- Settings from Controls
	local provider = self.controls.provider.list[self.controls.provider.selIndex]
	local endpoint = self.controls.endpoint.buf
	local model = self.controls.model.buf
	local apiKey = self.controls.apiKey.buf
	
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
	if role == "Voc\234" or role == "Voce" or role == "User" then
		prefix = "Voc\234: "
	elseif role == "Agente" then
		prefix = "Agente: "
	elseif role == "Sistema" then
		prefix = "Sistema: "
	end
	
	-- Fallback for content if nil
	if not content then content = "" end
	
	-- Try direct append first (if supported) using SetText with concatenation
	local currentText = self.controls.display.buf or ""
	local newEntry = prefix .. content
	
	if #currentText > 0 then
		self.controls.display:SetText(currentText .. "\n\n" .. newEntry)
	else
		self.controls.display:SetText(newEntry)
	end
	
	-- Scroll to bottom (Set careful position if EditControl allows)
	-- self.controls.display.selS = #self.controls.display.buf + 1
	-- self.controls.display:ScrollCaretIntoView()
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
