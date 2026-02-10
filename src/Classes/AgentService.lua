-- Path of Building
--
-- Module: Agent Service
-- Service to handle LLM Agent logic (Ollama/OpenAI)
--
local dkjson = require "dkjson"

local AgentServiceClass = newClass("AgentService", function(self, build)
	self.build = build
	self.provider = "Ollama" 
	self.endpoint = "http://localhost:11434/api/generate"
	self.model = "llama3"
	self.apiKey = ""
	
	self:InitDefaultActions()
end)

function AgentServiceClass:SetProvider(provider, endpoint, model, apiKey)
	self.provider = provider
	self.endpoint = endpoint
	self.model = model
	self.apiKey = apiKey
end

function AgentServiceClass:GenerateContext()
	local output = self.build.calcsTab.mainEnv.output or {}
	local spec = self.build.spec
	
	local context = {
		class = spec.curClassName,
		ascendancy = spec.curAscendClassName,
		level = self.build.characterLevel,
		stats = {
			life = output.Life,
			es = output.EnergyShield,
			mana = output.Mana,
			dps = output.TotalDPS or output.CombinedDPS or 0,
			str = output.Str,
			dex = output.Dex,
			int = output.Int,
			res_fire = output.FireResist,
			res_cold = output.ColdResist,
			res_light = output.LightningResist,
			res_chaos = output.ChaosResist,
		},
		mainSkill = "Unknown"
	}
	
	-- Main Skill Name
	if self.build.calcsTab.mainEnv.player.mainSkill then
	   context.mainSkill = self.build.calcsTab.mainEnv.player.mainSkill.activeEffect.grantedEffect.name
	end

	-- Items (Simplified)
	context.items = {}
	if self.build.itemsTab and self.build.itemsTab.slots then
		for slotName, slot in pairs(self.build.itemsTab.slots) do
			if (slot.weapon or slotName:match("Helmet") or slotName:match("Body") or slotName:match("Gloves") or slotName:match("Boots") or slotName:match("Amulet") or slotName:match("Ring") or slotName:match("Belt")) and slot.selItemId ~= 0 then
				 local item = self.build.itemsTab.items[slot.selItemId]
				 if item then
					 table.insert(context.items, { slot = slotName, name = item.name, base = item.baseName })
				 end
			end
		end
	end

	return context
end

function AgentServiceClass:SendPrompt(userPrompt, history, callback)
	local context = self:GenerateContext()
	
	local systemPrompt = "Você é um especialista em builds do Path of Exile 2. " ..
						 "Build Atual: " .. dkjson.encode(context) .. ". " ..
						 self:GetActionsDescription() .. "\n" ..
						 "Analise a build e responda \224 pergunta do usu\225rio em Portugu\234s. " ..
						 "O contexto da build J\193 EST\193 nesta mensagem. N\195O tente usar a\231\245es de 'An\225lise', apenas leia o JSON acima. " ..
						 "Se precisar executar uma a\231\227o de MODIFICA\199\195O (ex: AllocNode), retorne APENAS o JSON da a\231\227o. " ..
						 "NUNCA invente a\231\245es que n\227o estejam na lista (como AnalyzeTree ou WaitForAnalysis). " ..
						 "Se for apenas conversar, responda em texto normal."
	
	local bodyData
	local headers = ""

	if self.provider == "Ollama" then
		-- Ollama API (generate endpoint)
		local request = {
			model = self.model,
			prompt = systemPrompt .. "\nUser: " .. userPrompt,
			stream = false
		}
		bodyData = dkjson.encode(request)
		headers = "Content-Type: application/json"
	elseif self.provider == "OpenAI" then
		-- OpenAI API (chat completions)
		local messages = {
			{ role = "system", content = systemPrompt },
		}
		-- Append history
		if history then
			for _, msg in ipairs(history) do
				 table.insert(messages, { role = msg.role, content = msg.content })
			end
		end
		table.insert(messages, { role = "user", content = userPrompt })

		local request = {
			model = self.model,
			messages = messages
		}
		bodyData = dkjson.encode(request)
		headers = "Content-Type: application/json\nAuthorization: Bearer " .. self.apiKey
	end

	self:LogAction("SendPrompt", "Sending", "URL: " .. self.endpoint .. " | Model: " .. self.model .. " | BodyLen: " .. #bodyData)

	launch:DownloadPage(self.endpoint, function(response, errMsg)
		if errMsg then
			self:LogAction("SendPrompt", "Error", "Msg: " .. tostring(errMsg) .. " | Response: " .. tostring(response))
			callback(nil, "Error: " .. errMsg)
			return
		end
		
		self:LogAction("SendPrompt", "Success", "ResponseLen: " .. #(response.body or ""))
		
		local responseData, err = dkjson.decode(response.body)
		if not responseData then
			 callback(nil, "Error decoding JSON: " .. (err or "unknown"))
			 return
		end

		local text = ""
		if self.provider == "Ollama" then
			 text = responseData.response
		elseif self.provider == "OpenAI" then
			 if responseData.error then
				callback(nil, "API Error: " .. (responseData.error.message or "Unknown"))
				return
			 end
			 if responseData.choices and responseData.choices[1] then
				 text = responseData.choices[1].message.content
			 end
		end
		
		if not text or text == "" then
			 callback(nil, "Empty response from LLM")
		else
			 callback(text, nil)
		end

		end, { body = bodyData, header = headers })
end

-- Action Registry
function AgentServiceClass:RegisterAction(name, func, description)
	self.actions = self.actions or {}
	self.actions[name] = { func = func, description = description }
end

function AgentServiceClass:ExecuteAction(actionName, params)
	if not self.actions or not self.actions[actionName] then
		return false, "A\231\227o n\227o encontrada: " .. tostring(actionName)
	end
	
	local success, result = pcall(self.actions[actionName].func, params)
	if success then
		return true, result
	else
		return false, "Erro na execu\231\227o: " .. tostring(result)
	end
end

function AgentServiceClass:GetActionsDescription()
	if not self.actions then return "" end
	local desc = "Ferramentas dispon\161veis (use JSON para executar):\n"
	for name, data in pairs(self.actions) do
		desc = desc .. "- " .. name .. ": " .. data.description .. "\n"
	end
	desc = desc .. "Formato de resposta para a\231\227o: {\"action\": \"NomeDaAcao\", \"params\": { ... }}"
	return desc
end

-- Helper to log actions to file
function AgentServiceClass:LogAction(actionName, status, details)
	local file, err = io.open("AgentActions.log", "a")
	if file then
		file:write(string.format("[%s] Action: %s | Status: %s | Details: %s\n", os.date("%Y-%m-%d %H:%M:%S"), actionName, status, details))
		file:close()
	end
end

-- Initialize default actions
function AgentServiceClass:InitDefaultActions()
	self:RegisterAction("AllocNode", function(params)
		local node
		if params.nodeId then
			node = self.build.spec.tree.nodes[tonumber(params.nodeId)]
		elseif params.name then
			-- Helper to check if string is numeric ID
			if string.match(params.name, "^%d+$") then
				node = self.build.spec.tree.nodes[tonumber(params.name)]
				self:LogAction("AllocNode", "Debug", "Using numeric name as ID: " .. params.name)
			else
				-- Search by name (case insensitive)
				self:LogAction("AllocNode", "Debug", "Searching for name: " .. tostring(params.name))
				local targetName = params.name:lower()
				for _, n in pairs(self.build.spec.tree.nodes) do
					if n.dn and n.dn:lower() == targetName then
						node = n
						break
					end
				end
			end
		else
			return "Erro: nodeId ou name necess\225rio"
		end

		if not node then 
			self:LogAction("AllocNode", "Error", "Node not found: " .. tostring(params.name or params.nodeId))
			return "Erro: No nao encontrado (" .. tostring(params.name or params.nodeId) .. ")" 
		end
		
		self:LogAction("AllocNode", "Debug", "Found node: " .. node.dn .. " (ID: " .. node.id .. ")")

		-- Switch to Tree View
		if self.build.viewMode ~= "TREE" then
			self.build.viewMode = "TREE"
		end
		
		-- Check if already allocated
		if self.build.spec.allocNodes[node.id] then
			self:LogAction("AllocNode", "Skipped", "Already allocated: " .. node.dn)
			return "No ja alocado: " .. node.dn
		end
		
		self.build.spec:AllocNode(node, self.build.spec.curGraphNode ~= nil)
		self.build.spec:AddUndoState()
		self.build.spec:SetWindowTitleWithBuildClass()
		self.build.buildFlag = true
		if self.build.treeTab and self.build.treeTab.viewer then
            self.build.treeTab.viewer.searchNeedsForceUpdate = true
        end
		
		self:LogAction("AllocNode", "Success", "Allocated: " .. node.dn .. " (ID: " .. node.id .. ")")
		return "No alocado com sucesso: " .. node.dn
	end, "Aloca um no na arvore de passivas. Params: { nodeId: number } ou { name: string }")

	self:RegisterAction("DeallocNode", function(params)
		if not params.nodeId then return "Erro: nodeId necessario" end
		local node = self.build.spec.tree.nodes[tonumber(params.nodeId)]
		if not node then return "Erro: No nao encontrado" end
		
		-- Switch to Tree View
		if self.build.viewMode ~= "TREE" then
			self.build.viewMode = "TREE"
		end
		
		if not self.build.spec.allocNodes[node.id] then
			return "No nao estah alocado"
		end
		
		self.build.spec:DeallocNode(node)
		self.build.spec:AddUndoState()
		self.build.buildFlag = true
		
		self:LogAction("DeallocNode", "Success", "Deallocated: " .. node.dn)
		return "No desalocado com sucesso: " .. node.dn
	end, "Desaloca um no na arvore de passivas. Params: { nodeId: number }")

	self:RegisterAction("SwitchClass", function(params)
		if not params.classId then return "Erro: classId necessario" end
		local classId = tonumber(params.classId)
		if not self.build.spec.tree.classes[classId] then return "Erro: ID de classe invalido" end
		
		-- Switch to Tree View (Class selection is usually there)
		if self.build.viewMode ~= "TREE" then
			self.build.viewMode = "TREE"
		end
		
		local className = self.build.spec.tree.classes[classId].name
		self.build.spec:SelectClass(classId)
		self.build.spec:AddUndoState()
		self.build.buildFlag = true
		
		self:LogAction("SwitchClass", "Success", "Switched to: " .. className)
		return "Classe alterada para: " .. className
	end, "Altera a classe do personagem. Params: { classId: number }")

	self:RegisterAction("SwitchAscendancy", function(params)
		if not params.ascendClassId then return "Erro: ascendClassId necessario" end
		local ascendClassId = tonumber(params.ascendClassId)
		
		-- Switch to Tree View
		if self.build.viewMode ~= "TREE" then
			self.build.viewMode = "TREE"
		end

		self.build.spec:SelectAscendClass(ascendClassId)
		self.build.spec:AddUndoState()
		self.build.buildFlag = true
		
		self:LogAction("SwitchAscendancy", "Success", "Switched to ID: " .. ascendClassId)
		return "Ascendencia alterada para ID: " .. ascendClassId
	end, "Altera a ascendencia do personagem. Params: { ascendClassId: number }")

	self:RegisterAction("SetLevel", function(params)
		if not params.level then return "Erro: level necessario" end
		local level = tonumber(params.level)
		if level < 1 or level > 100 then return "Erro: Nivel deve ser entre 1 e 100" end
		
		self.build.characterLevel = level
		self.build.buildFlag = true
		
		self:LogAction("SetLevel", "Success", "Level set to: " .. level)
		return "Nivel do personagem alterado para: " .. level
	end, "Define o nivel do personagem. Params: { level: number }")
end


return AgentServiceClass
