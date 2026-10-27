print("[Blue Luger & Corrupt] loading...")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

-- SETTINGS
local BLUE = Color3.fromRGB(20, 70, 255)      -- main blue (matches the pic)
local BLUE_LIGHT = Color3.fromRGB(110, 170, 255)
-- Tool names that count as each weapon (lowercase, partial match). Add yours if the game names them differently.
local GUN_NAMES = { "luger", "gun" }
local KNIFE_NAMES = { "corrupt", "knife" }

local env = (getgenv and getgenv()) or _G
if env.BlueLugerCleanup then pcall(env.BlueLugerCleanup) end

local masterOn = false
local gunOn = true
local knifeOn = true
local conns = {}
local hooked = setmetatable({}, { __mode = "k" })     -- tool -> "gun" / "knife"
local originals = setmetatable({}, { __mode = "k" })  -- inst -> { prop = value }
local surfaces = setmetatable({}, { __mode = "k" })   -- meshPart -> SurfaceAppearance we added
local gui

local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(conns, c)
	return c
end

local function save(inst, prop, value)
	local saved = originals[inst]
	if not saved then saved = {} originals[inst] = saved end
	if saved[prop] == nil then
		local ok, v = pcall(function() return inst[prop] end)
		if ok then saved[prop] = v end
	end
	pcall(function() inst[prop] = value end)
end

local function kindOf(tool)
	if not tool:IsA("Tool") then return nil end
	local n = string.lower(tool.Name)
	for _, w in ipairs(KNIFE_NAMES) do
		if string.find(n, w, 1, true) then return "knife" end
	end
	for _, w in ipairs(GUN_NAMES) do
		if string.find(n, w, 1, true) then return "gun" end
	end
	return nil
end

local function wanted(kind)
	return masterOn and ((kind == "gun" and gunOn) or (kind == "knife" and knifeOn))
end

local function removeSurface(mp)
	local sa = surfaces[mp]
	if sa then pcall(function() sa:Destroy() end) surfaces[mp] = nil end
end

local function paintPart(inst)
	if inst:IsA("BasePart") then
		save(inst, "Color", BLUE)
		if inst:IsA("MeshPart") then
			local ok, tex = pcall(function() return inst.TextureID end)
			if ok and type(tex) == "string" and tex ~= "" then
				local sa = surfaces[inst]
				if not sa or not sa.Parent then
					sa = Instance.new("SurfaceAppearance")
					sa.Name = "BLSurface"
					if pcall(function() sa.ColorMap = tex end) then
						sa.Parent = inst
						surfaces[inst] = sa
					else
						sa:Destroy()
						sa = nil
					end
				end
				if sa then pcall(function() sa.Color = BLUE_LIGHT end) end
			end
		end
	elseif inst:IsA("SpecialMesh") then
		save(inst, "VertexColor", Vector3.new(BLUE.R, BLUE.G, BLUE.B))
	end
end

local function restoreTool(tool)
	for _, d in ipairs(tool:GetDescendants()) do
		if d:IsA("MeshPart") then removeSurface(d) end
		local saved = originals[d]
		if saved then
			for prop, v in pairs(saved) do pcall(function() d[prop] = v end) end
			originals[d] = nil
		end
	end
end

local function refreshTool(tool)
	local kind = hooked[tool]
	if not kind then return end
	if wanted(kind) then
		for _, d in ipairs(tool:GetDescendants()) do paintPart(d) end
	else
		restoreTool(tool)
	end
end

local updateGui
local function refreshAll()
	for tool in pairs(hooked) do
		if tool.Parent then refreshTool(tool) end
	end
	if updateGui then updateGui() end
end

local function hook(tool)
	local kind = kindOf(tool)
	if not kind or hooked[tool] then return end
	hooked[tool] = kind
	print("[Blue Luger & Corrupt] found " .. kind .. ": " .. tool:GetFullName())
	connect(tool.DescendantAdded, function(d)
		task.defer(function()
			if d.Parent and wanted(kind) then paintPart(d) end
		end)
	end)
	refreshTool(tool)
end

local function scan(container)
	if not container then return end
	for _, c in ipairs(container:GetChildren()) do hook(c) end
	connect(container.ChildAdded, hook)
end
scan(LocalPlayer.Character)
scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
connect(LocalPlayer.CharacterAdded, scan)
connect(LocalPlayer.ChildAdded, function(c)
	if c:IsA("Backpack") then scan(c) end
end)

-- GUI
local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "BlueLugerCorrupt"
	gui.ResetOnSpawn = false
	local ok = pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
	if not ok or not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(0, 260, 0, 190)
	frame.Position = UDim2.new(0, 20, 0.3, 0)
	frame.BackgroundColor3 = Color3.fromRGB(8, 10, 22)
	frame.BorderSizePixel = 0
	frame.Active = true
	pcall(function() frame.Draggable = true end)
	frame.Parent = gui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 14)
	local fs = Instance.new("UIStroke", frame)
	fs.Color = BLUE
	fs.Thickness = 2
	local fg = Instance.new("UIGradient", frame)
	fg.Rotation = 90
	fg.Color = ColorSequence.new(Color3.fromRGB(26, 34, 70), Color3.fromRGB(6, 8, 18))

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -50, 0, 28)
	title.Position = UDim2.new(0, 12, 0, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = BLUE_LIGHT
	title.Text = "BLUE LUGER & CORRUPT"
	title.Parent = frame

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0, 26, 0, 26)
	closeBtn.Position = UDim2.new(1, -34, 0, 7)
	closeBtn.BackgroundColor3 = Color3.fromRGB(110, 25, 25)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.Text = "X"
	closeBtn.Parent = frame
	Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 8)

	-- one big blue button
	local big = Instance.new("TextButton")
	big.Size = UDim2.new(1, -24, 0, 70)
	big.Position = UDim2.new(0, 12, 0, 42)
	big.AutoButtonColor = false
	big.Font = Enum.Font.GothamBlack
	big.TextSize = 24
	big.TextColor3 = Color3.new(1, 1, 1)
	big.TextStrokeTransparency = 0.4
	big.Parent = frame
	Instance.new("UICorner", big).CornerRadius = UDim.new(0, 12)
	local bs = Instance.new("UIStroke", big)
	bs.Color = BLUE_LIGHT
	bs.Thickness = 2
	local bg = Instance.new("UIGradient", big)
	bg.Rotation = 90
	bg.Color = ColorSequence.new(Color3.fromRGB(70, 130, 255), Color3.fromRGB(10, 40, 200))

	local function smallToggle(x, text, onClick)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.5, -18, 0, 38)
		b.Position = UDim2.new(x, x == 0 and 12 or 6, 0, 124)
		b.AutoButtonColor = false
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Text = text
		b.Parent = frame
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
		local s = Instance.new("UIStroke", b)
		s.Color = BLUE_LIGHT
		s.Thickness = 1.5
		b.MouseButton1Click:Connect(onClick)
		return b, s
	end

	local gunBtn = smallToggle(0, "", function() gunOn = not gunOn refreshAll() end)
	local knifeBtn = smallToggle(0.5, "", function() knifeOn = not knifeOn refreshAll() end)

	local hint = Instance.new("TextLabel")
	hint.Size = UDim2.new(1, -24, 0, 18)
	hint.Position = UDim2.new(0, 12, 1, -24)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 11
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = Color3.fromRGB(140, 150, 185)
	hint.Text = "RightShift = hide / show"
	hint.Parent = frame

	local ON_COLOR, OFF_COLOR = Color3.fromRGB(0, 90, 230), Color3.fromRGB(45, 48, 62)
	big.MouseButton1Click:Connect(function()
		masterOn = not masterOn
		refreshAll()
	end)

	updateGui = function()
		big.Text = masterOn and "BLUE: ON" or "BLUE: OFF"
		big.BackgroundColor3 = masterOn and Color3.new(1, 1, 1) or Color3.fromRGB(120, 120, 130)
		gunBtn.Text = gunOn and "LUGER: ON" or "LUGER: OFF"
		gunBtn.BackgroundColor3 = gunOn and ON_COLOR or OFF_COLOR
		knifeBtn.Text = knifeOn and "CORRUPT: ON" or "CORRUPT: OFF"
		knifeBtn.BackgroundColor3 = knifeOn and ON_COLOR or OFF_COLOR
	end
	updateGui()

	closeBtn.MouseButton1Click:Connect(function()
		if env.BlueLugerCleanup then pcall(env.BlueLugerCleanup) end
	end)
	connect(UserInputService.InputBegan, function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.RightShift then frame.Visible = not frame.Visible end
	end)
end

local built, err = pcall(buildGui)
if not built then warn("[Blue Luger & Corrupt] menu failed: " .. tostring(err)) end

env.BlueLugerCleanup = function()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for tool in pairs(hooked) do restoreTool(tool) end
	if gui then gui:Destroy() end
	env.BlueLugerCleanup = nil
end
print("[Blue Luger & Corrupt] loaded")
