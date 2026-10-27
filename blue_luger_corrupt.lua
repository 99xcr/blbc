print("[Blue Luger & Corrupt] loading...")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local LocalPlayer = Players.LocalPlayer

-- SETTINGS
local BLUE = Color3.fromRGB(20, 70, 255)      -- flat blue (used for shots + fallback)
local BLUE_LIGHT = Color3.fromRGB(110, 170, 255)
local GUN_NAMES = { "luger", "gun" }          -- tool names (lowercase, partial match) that count as the gun
local KNIFE_NAMES = { "corrupt", "knife" }    -- tool names that count as the knife
local SHOT_WINDOW = 1.0                       -- seconds after you fire during which new effects count as your shot
local SHOT_RADIUS = 30                        -- studs from you within which a new effect counts as your shot
local MAX_TEX = 512                           -- big textures are shrunk to this before editing (faster)

local env = (getgenv and getgenv()) or _G
if env.BlueLugerCleanup then pcall(env.BlueLugerCleanup) end

local masterOn = false
local gunOn = true
local knifeOn = true
local conns = {}
local hooked = setmetatable({}, { __mode = "k" })     -- tool -> "gun" / "knife"
local originals = setmetatable({}, { __mode = "k" })  -- inst -> { prop = value }
local painted = setmetatable({}, { __mode = "k" })    -- inst -> "gun" / "knife" (everything we recoloured)
local surfaces = setmetatable({}, { __mode = "k" })   -- meshPart -> SurfaceAppearance we added
local watchedTargets = setmetatable({}, { __mode = "k" })
local guardedFx = setmetatable({}, { __mode = "k" })
local gui
local updateGui

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

local function kindOfName(name)
	local n = string.lower(name)
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

------------------------------------------------------------------
-- BLUE TEXTURE: keeps the weapon's own shading, repaints it in the
-- blue palette from your picture (deep navy > bright blue > icy white)
------------------------------------------------------------------
local STOPS = {
	{ 0.00, 3, 10, 60 },
	{ 0.30, 12, 45, 200 },
	{ 0.60, 30, 100, 255 },
	{ 0.85, 110, 175, 255 },
	{ 1.00, 225, 240, 255 },
}
local LUT_R, LUT_G, LUT_B = {}, {}, {}
for k = 1, 256 do
	local s = (k - 1) / 255
	for i = 1, #STOPS - 1 do
		local a, b = STOPS[i], STOPS[i + 1]
		if s >= a[1] and s <= b[1] then
			local f = (s - a[1]) / (b[1] - a[1])
			LUT_R[k] = a[2] + (b[2] - a[2]) * f
			LUT_G[k] = a[3] + (b[3] - a[3]) * f
			LUT_B[k] = a[4] + (b[4] - a[4]) * f
			break
		end
	end
end

local sources = {}   -- texture id -> { w, h, buf, lum, hist, seen }
local blueTex = {}   -- texture id -> { state, image, waiters }
local jobs, working = {}, false

local function makeBreather()
	local mark = os.clock()
	return function()
		if os.clock() - mark > 0.004 then
			task.wait()
			mark = os.clock()
		end
	end
end

local function loadSource(tex)
	local ei
	local okLoad = pcall(function()
		ei = AssetService:CreateEditableImageAsync(Content.fromUri(tex))
	end)
	if not (okLoad and ei) then return nil end
	local src
	local okRead = pcall(function()
		local size = ei.Size
		local sw, sh = size.X, size.Y
		local step = math.max(math.ceil(math.max(sw, sh) / MAX_TEX), 1)
		local w, h = math.max(math.floor(sw / step), 1), math.max(math.floor(sh / step), 1)
		local raw = ei:ReadPixelsBuffer(Vector2.zero, size)
		local readu8, writeu8 = buffer.readu8, buffer.writeu8
		local readu32, writeu32 = buffer.readu32, buffer.writeu32
		local breathe = makeBreather()
		local buf = raw
		if step > 1 then
			buf = buffer.create(w * h * 4)
			for y = 0, h - 1 do
				local srow, drow = y * step * sw, y * w
				for x = 0, w - 1 do
					writeu32(buf, (drow + x) * 4, readu32(raw, (srow + x * step) * 4))
				end
				breathe()
			end
		end
		local lumBuf = buffer.create(w * h)
		local hist, seen = {}, 0
		for k = 0, 255 do hist[k] = 0 end
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local i = y * w + x
				local o = i * 4
				local l = math.floor(0.299 * readu8(buf, o) + 0.587 * readu8(buf, o + 1) + 0.114 * readu8(buf, o + 2) + 0.5)
				writeu8(lumBuf, i, l)
				if readu8(buf, o + 3) > 10 then
					hist[l] += 1
					seen += 1
				end
			end
			breathe()
		end
		src = { w = w, h = h, buf = buf, lum = lumBuf, hist = hist, seen = seen }
	end)
	pcall(function() ei:Destroy() end)
	if not okRead then return nil end
	return src
end

local function percentile(hist, total, p)
	if total == 0 then return p end
	local target, run = p * total, 0
	for k = 0, 255 do
		run += hist[k]
		if run >= target then return k / 255 end
	end
	return 1
end

local function paintBlue(src)
	local image
	local ok = pcall(function()
		local w, h = src.w, src.h
		local readu8, writeu8 = buffer.readu8, buffer.writeu8
		local breathe = makeBreather()
		local lo, hi = percentile(src.hist, src.seen, 0.05), percentile(src.hist, src.seen, 0.95)
		local span = math.max(hi - lo, 0.05)
		local out = buffer.create(w * h * 4)
		buffer.copy(out, 0, src.buf, 0, w * h * 4) -- keeps see-through (alpha) pixels
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local i = y * w + x
				local rel = (readu8(src.lum, i) / 255 - lo) / span
				if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
				local k = math.floor(rel * 255) + 1
				local o = i * 4
				writeu8(out, o, math.floor(LUT_R[k]))
				writeu8(out, o + 1, math.floor(LUT_G[k]))
				writeu8(out, o + 2, math.floor(LUT_B[k]))
			end
			breathe()
		end
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), out)
		image = img
	end)
	return ok and image or nil
end

local paintPart -- forward declaration

local function runJobs()
	if working then return end
	working = true
	task.spawn(function()
		while #jobs > 0 do
			local job = table.remove(jobs, 1)
			local entry = job.entry
			local src = sources[job.tex]
			if not src then
				src = loadSource(job.tex)
				if src then sources[job.tex] = src end
			end
			local image = src and paintBlue(src)
			if image then
				entry.state = "done"
				entry.image = image
			else
				entry.state = "failed"
				entry.at = os.clock()
				warn("[Blue Luger & Corrupt] couldn't build the blue texture, using flat blue")
			end
			local waiting = entry.waiters
			entry.waiters = {}
			for mp in pairs(waiting) do
				if mp.Parent and painted[mp] and wanted(painted[mp]) then
					pcall(paintPart, mp)
				end
			end
		end
		working = false
	end)
end

local function ensureTexture(tex)
	local entry = blueTex[tex]
	if entry and entry.state == "failed" and os.clock() - (entry.at or 0) > 5 then entry = nil end
	if entry then return entry end
	entry = { state = "working", waiters = {} }
	blueTex[tex] = entry
	table.insert(jobs, { tex = tex, entry = entry })
	runJobs()
	return entry
end

------------------------------------------------------------------
-- PAINT / RESTORE
------------------------------------------------------------------
local function ourSurface(mp)
	local sa = surfaces[mp]
	if sa and sa.Parent then return sa end
	local existing = mp:FindFirstChild("BLSurface")
	if existing and existing:IsA("SurfaceAppearance") then
		surfaces[mp] = existing
		return existing
	end
	return nil
end

local function nativeSurface(mp)
	for _, c in ipairs(mp:GetChildren()) do
		if c:IsA("SurfaceAppearance") and c.Name ~= "BLSurface" then return c end
	end
	return nil
end

local function tintMesh(mp)
	local native = nativeSurface(mp)
	local sa = native
	if not sa then
		sa = ourSurface(mp)
		if not sa then
			sa = Instance.new("SurfaceAppearance")
			sa.Name = "BLSurface"
			sa.Parent = mp
			surfaces[mp] = sa
		end
	end
	local tex = ""
	local okT, t = pcall(function() return mp.TextureID end)
	if okT and type(t) == "string" then tex = t end
	if tex == "" and native then
		local okN, n = pcall(function() return native.ColorMap end)
		if okN and type(n) == "string" then tex = n end
	end
	local function flat()
		if native then
			save(native, "ColorMap", "")
			save(native, "Color", BLUE)
		else
			pcall(function() sa.ColorMap = "" sa.Color = BLUE end)
		end
	end
	if tex == "" then
		flat()
		return
	end
	local entry = ensureTexture(tex)
	if entry.state == "done" and entry.image then
		if native then
			save(native, "ColorMap", "")
		end
		local ok = pcall(function()
			sa.ColorMapContent = Content.fromObject(entry.image)
			sa.Color = Color3.new(1, 1, 1)
		end)
		if not ok then flat() end
	else
		flat()
		if entry.state == "working" then entry.waiters[mp] = true end
	end
end

function paintPart(inst, kind)
	kind = kind or painted[inst]
	if not kind then return end
	if inst:IsA("BasePart") then
		if inst.Transparency >= 1 then return end
		painted[inst] = kind
		save(inst, "Color", BLUE)
		if inst:IsA("MeshPart") then tintMesh(inst) end
	elseif inst:IsA("SpecialMesh") then
		painted[inst] = kind
		save(inst, "VertexColor", Vector3.new(BLUE.R, BLUE.G, BLUE.B))
	end
end

local function restoreInst(inst)
	painted[inst] = nil
	if inst:IsA("MeshPart") then
		local sa = surfaces[inst]
		if sa then pcall(function() sa:Destroy() end) surfaces[inst] = nil end
		local ex = inst:FindFirstChild("BLSurface")
		if ex then pcall(function() ex:Destroy() end) end
		local native = nativeSurface(inst)
		local saved = native and originals[native]
		if saved then
			for prop, v in pairs(saved) do pcall(function() native[prop] = v end) end
			originals[native] = nil
		end
	end
	local saved = originals[inst]
	if saved then
		for prop, v in pairs(saved) do pcall(function() inst[prop] = v end) end
		originals[inst] = nil
	end
end

local function paintTree(root, kind)
	if root:IsA("BasePart") or root:IsA("SpecialMesh") then paintPart(root, kind) end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") or d:IsA("SpecialMesh") then paintPart(d, kind) end
	end
end

------------------------------------------------------------------
-- HIP / BACK COPY OF THE WEAPON
------------------------------------------------------------------
local function assetIds()
	local ids = {}
	for tool, kind in pairs(hooked) do
		for _, d in ipairs(tool:GetDescendants()) do
			if d:IsA("MeshPart") then
				local okt, tex = pcall(function() return d.TextureID end)
				if okt and type(tex) == "string" and tex ~= "" then ids[tex] = kind end
				local okm, mesh = pcall(function() return d.MeshId end)
				if okm and type(mesh) == "string" and mesh ~= "" then ids[mesh] = kind end
			end
		end
	end
	return ids
end

local function hipTarget(char)
	local ref = char:FindFirstChild("DisplayRefGun")
	if not (ref and ref:IsA("ObjectValue")) then return nil end
	local t = ref.Value
	if not t then return nil end
	if t == char or char:IsDescendantOf(t) then return nil end
	if t:IsA("Humanoid") or t:FindFirstChildOfClass("Humanoid") then return nil end
	return t
end

local function refreshHip()
	local char = LocalPlayer.Character
	if not char then return end
	local ids = assetIds()
	local target = hipTarget(char)
	if target then
		if not watchedTargets[target] then
			watchedTargets[target] = true
			connect(target.DescendantAdded, function(d)
				task.defer(function()
					if d.Parent and wanted("gun") then paintPart(d, "gun") end
				end)
			end)
		end
		if wanted("gun") then paintTree(target, "gun") end
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("MeshPart") and not d:FindFirstAncestorOfClass("Tool") then
			local okt, tex = pcall(function() return d.TextureID end)
			local okm, mesh = pcall(function() return d.MeshId end)
			local kind = (okt and tex ~= "" and ids[tex]) or (okm and mesh ~= "" and ids[mesh]) or nil
			if kind and wanted(kind) then paintPart(d, kind) end
		end
	end
end

------------------------------------------------------------------
-- REFRESH
------------------------------------------------------------------
local function refreshAll()
	for tool, kind in pairs(hooked) do
		if tool.Parent and wanted(kind) then paintTree(tool, kind) end
	end
	for inst, kind in pairs(painted) do
		if not wanted(kind) then restoreInst(inst) end
	end
	if masterOn then refreshHip() end
	if updateGui then updateGui() end
end

local function hook(tool)
	if not tool:IsA("Tool") then return end
	local kind = kindOfName(tool.Name)
	if not kind or hooked[tool] then return end
	hooked[tool] = kind
	print("[Blue Luger & Corrupt] found " .. kind .. ": " .. tool:GetFullName())
	connect(tool.DescendantAdded, function(d)
		task.defer(function()
			if d.Parent and wanted(kind) then paintPart(d, kind) end
		end)
	end)
	if wanted(kind) then paintTree(tool, kind) end
end

local function scan(container)
	if not container then return end
	for _, c in ipairs(container:GetChildren()) do hook(c) end
	connect(container.ChildAdded, hook)
end

local function watchCharacter(char)
	if not char then return end
	connect(char.DescendantAdded, function(d)
		if masterOn and (d:IsA("MeshPart") or d.Name == "DisplayRefGun") then
			task.defer(refreshHip)
		end
	end)
end

scan(LocalPlayer.Character)
scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
watchCharacter(LocalPlayer.Character)
connect(LocalPlayer.CharacterAdded, function(c) scan(c) watchCharacter(c) end)
connect(LocalPlayer.ChildAdded, function(c)
	if c:IsA("Backpack") then scan(c) end
end)

-- keeps everything blue if the game rebuilds / resets the weapon, and prints what you're holding
local lastCheck, lastNames = 0, ""
connect(RunService.Heartbeat, function()
	local now = os.clock()
	if now - lastCheck < 0.5 then return end
	lastCheck = now
	if masterOn then
		for tool, kind in pairs(hooked) do
			if tool.Parent and wanted(kind) then
				for _, d in ipairs(tool:GetDescendants()) do
					if d:IsA("BasePart") and not painted[d] then paintPart(d, kind) end
				end
			end
		end
		refreshHip()
	end
	local char = LocalPlayer.Character
	if char then
		local names = {}
		for _, t in ipairs(char:GetChildren()) do
			if t:IsA("Tool") then table.insert(names, t.Name) end
		end
		local joined = table.concat(names, ", ")
		if joined ~= lastNames then
			lastNames = joined
			print("[Blue Luger & Corrupt] tools in hand: " .. (joined ~= "" and joined or "none"))
		end
	end
end)

------------------------------------------------------------------
-- BLUE SHOTS
------------------------------------------------------------------
local shotUntil = 0
local function holdingWanted()
	local char = LocalPlayer.Character
	if not char then return false end
	for _, c in ipairs(char:GetChildren()) do
		local kind = hooked[c]
		if kind and wanted(kind) then return true end
	end
	return false
end
local function openShot()
	if holdingWanted() then shotUntil = os.clock() + SHOT_WINDOW end
end
connect(UserInputService.InputBegan, function(input, processed)
	if processed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		openShot()
	end
end)

local function isEffect(inst)
	return inst:IsA("Beam") or inst:IsA("Trail") or inst:IsA("ParticleEmitter")
end
local function characterOf(inst)
	local m = inst:FindFirstAncestorOfClass("Model")
	while m do
		if m:FindFirstChildOfClass("Humanoid") then return m end
		m = m:FindFirstAncestorOfClass("Model")
	end
	return nil
end
local function partOf(inst)
	if inst:IsA("BasePart") then return inst end
	local p = inst.Parent
	if p and p:IsA("Attachment") then p = p.Parent end
	if p and p:IsA("BasePart") then return p end
	return nil
end
local function nearYou(d)
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return true end
	local points = {}
	local part = partOf(d)
	if part then table.insert(points, part.Position) end
	if d:IsA("Beam") then
		if d.Attachment0 then table.insert(points, d.Attachment0.WorldPosition) end
		if d.Attachment1 then table.insert(points, d.Attachment1.WorldPosition) end
	end
	if #points == 0 then return true end
	for _, p in ipairs(points) do
		if (p - root.Position).Magnitude <= SHOT_RADIUS then return true end
	end
	return false
end

local BLUE_SEQ = ColorSequence.new(BLUE)
local function paintShot(d)
	if d:IsA("BasePart") then
		pcall(function() d.Color = BLUE end)
		pcall(function() d.Material = Enum.Material.Neon end)
		if d:IsA("MeshPart") then pcall(function() d.TextureID = "" end) end
		return true
	elseif isEffect(d) then
		if not guardedFx[d] then
			guardedFx[d] = true
			connect(d:GetPropertyChangedSignal("Color"), function()
				if masterOn then pcall(function() d.Color = BLUE_SEQ end) end
			end)
		end
		pcall(function() d.Color = BLUE_SEQ end)
		return true
	elseif d:IsA("SpecialMesh") then
		pcall(function() d.TextureId = "" d.VertexColor = Vector3.new(BLUE.R, BLUE.G, BLUE.B) end)
		return true
	elseif d:IsA("Decal") or d:IsA("Texture") then
		pcall(function() d.Color3 = BLUE end)
		return true
	elseif d:IsA("Light") then
		pcall(function() d.Color = BLUE end)
		return true
	elseif d:IsA("Fire") then
		pcall(function() d.Color = BLUE d.SecondaryColor = BLUE end)
		return true
	end
	return false
end

connect(Workspace.DescendantAdded, function(d)
	if not masterOn then return end
	if os.clock() > shotUntil then return end
	local char = characterOf(d)
	if char then
		if char ~= LocalPlayer.Character then return end
		if not (isEffect(d) or d:IsA("Light")) then return end
	end
	task.defer(function()
		if not d.Parent or not masterOn then return end
		if not nearYou(d) then return end
		paintShot(d)
	end)
end)

------------------------------------------------------------------
-- GUI
------------------------------------------------------------------
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

	local function smallToggle(x, onClick)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.5, -18, 0, 38)
		b.Position = UDim2.new(x, x == 0 and 12 or 6, 0, 124)
		b.AutoButtonColor = false
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Text = ""
		b.Parent = frame
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 10)
		local s = Instance.new("UIStroke", b)
		s.Color = BLUE_LIGHT
		s.Thickness = 1.5
		b.MouseButton1Click:Connect(onClick)
		return b
	end

	local gunBtn = smallToggle(0, function() gunOn = not gunOn refreshAll() end)
	local knifeBtn = smallToggle(0.5, function() knifeOn = not knifeOn refreshAll() end)

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
	for inst in pairs(painted) do restoreInst(inst) end
	if gui then gui:Destroy() end
	env.BlueLugerCleanup = nil
end
print("[Blue Luger & Corrupt] loaded")
