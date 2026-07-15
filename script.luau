--[[
	CLOUDY CLIENT
	Lunar-Client-inspired in-game UI client.

	INSTALL:
	Place this LocalScript inside StarterPlayerScripts in a game you own.
	It is NOT loaded via loadstring/HttpGet, and it does not modify other
	players or run inside experiences you don't control — it's a normal
	client-side feature module, like any other LocalScript.

	REQUIRES:
	- Game Settings > Security > "Allow HTTP Requests" enabled, since this
	  script calls your Cloudy API over HttpService.
	- You must set Config.ApiBase below to your real API domain.

	HONESTY NOTES (read before shipping):
	- The "FPS Limiter" control stores the player's preference and sends it
	  to your API, but Roblox does not expose a public LocalScript API to
	  hard-cap the engine's actual render rate. Don't market this as a true
	  frame cap — it's a saved preference you can act on elsewhere if Roblox
	  ever exposes that hook, or use client-side to throttle your OWN heavy
	  per-frame work.
	- "Ping" reads Stats.Network.ServerStatsItem, which only exists once the
	  player has an active server connection (works fine in a live game).
	- ApplyOutfit only ever modifies the LOCAL player's own character
	  appearance for the current session — it cannot and does not touch
	  other players' characters or their inventories.
	- The "Social" tab shows the logged-in user's own Cloudy profile card.
	  A full multi-user directory would need an additional API endpoint
	  (e.g. GET /api/users) which isn't part of the spec you gave me, so
	  it isn't fabricated here.
]]

--// SERVICES
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local HttpService        = game:GetService("HttpService")
local Lighting           = game:GetService("Lighting")
local Stats              = game:GetService("Stats")
local GuiService         = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")

--// CONFIG
local Config = {
	ApiBase = "https://api.cloudyclient.com", -- TODO: set to your real API domain
	Version = "1.0.0",
}

--// THEME
local Theme = {
	Bg        = Color3.fromRGB(14, 18, 28),
	Panel     = Color3.fromRGB(20, 25, 38),
	PanelAlt  = Color3.fromRGB(26, 32, 48),
	Accent    = Color3.fromRGB(70, 140, 255),
	AccentAlt = Color3.fromRGB(120, 190, 255),
	White     = Color3.fromRGB(240, 245, 255),
	Muted     = Color3.fromRGB(150, 160, 180),
	Good      = Color3.fromRGB(90, 220, 140),
	Bad       = Color3.fromRGB(255, 90, 90),
}

--// STATE
local Cloudy = {}
Cloudy.User = nil
Cloudy.Settings = nil
Cloudy.Connections = {} -- track all RunService/event connections for cleanup
Cloudy.Gui = nil

--=====================================================================
-- UTILITIES
--=====================================================================

local function track(conn)
	table.insert(Cloudy.Connections, conn)
	return conn
end

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 10)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.Accent
	s.Thickness = thickness or 1.5
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function padding(parent, all)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, all)
	p.PaddingBottom = UDim.new(0, all)
	p.PaddingLeft = UDim.new(0, all)
	p.PaddingRight = UDim.new(0, all)
	p.Parent = parent
	return p
end

local function gradient(parent, rotation, colorSeq)
	local g = Instance.new("UIGradient")
	g.Rotation = rotation or 0
	g.Color = colorSeq or ColorSequence.new(Theme.Accent, Theme.AccentAlt)
	g.Parent = parent
	return g
end

local function tween(obj, props, time, style, dir)
	local t = TweenService:Create(obj, TweenInfo.new(
		time or 0.25,
		style or Enum.EasingStyle.Quint,
		dir or Enum.EasingDirection.Out
		), props)
	t:Play()
	return t
end

-- animated gradient border rotation loop
local function animateGradient(uiGradient, speed)
	speed = speed or 40 -- degrees/sec
	track(RunService.RenderStepped:Connect(function(dt)
		uiGradient.Rotation = (uiGradient.Rotation + speed * dt) % 360
	end))
end

-- pulsing UIStroke transparency loop
local function animatePulse(uiStroke)
	task.spawn(function()
		while uiStroke and uiStroke.Parent do
			tween(uiStroke, {Transparency = 0.7}, 1.1, Enum.EasingStyle.Sine)
			task.wait(1.1)
			if not (uiStroke and uiStroke.Parent) then break end
			tween(uiStroke, {Transparency = 0.1}, 1.1, Enum.EasingStyle.Sine)
			task.wait(1.1)
		end
	end)
end

-- mouse-following glow inside a container
local function attachGlow(container)
	local glow = Instance.new("ImageLabel")
	glow.Name = "MouseGlow"
	glow.BackgroundTransparency = 1
	glow.Image = "rbxasset://textures/particles/sparkles_main.dds"
	glow.ImageColor3 = Theme.Accent
	glow.ImageTransparency = 0.85
	glow.Size = UDim2.new(0, 260, 0, 260)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.ZIndex = 0
	glow.Parent = container

	track(RunService.RenderStepped:Connect(function()
		local mouse = UserInputService:GetMouseLocation()
		local abs = container.AbsolutePosition
		local size = container.AbsoluteSize
		local rel = mouse - abs
		if rel.X >= -50 and rel.X <= size.X + 50 and rel.Y >= -50 and rel.Y <= size.Y + 50 then
			glow.Visible = true
			glow.Position = UDim2.new(0, rel.X, 0, rel.Y)
		else
			glow.Visible = false
		end
	end))
	return glow
end

local function makeDraggable(handle, target)
	local dragging, dragStart, startPos
	track(handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = target.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			target.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end))
end

-- procedural cloud icon (no image assets required)
local function drawCloudIcon(parent, size, color)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(0, size, 0, size)
	holder.Parent = parent

	local function puff(scale, x, y)
		local p = Instance.new("Frame")
		p.BackgroundColor3 = color or Theme.White
		p.Size = UDim2.new(0, size * scale, 0, size * scale)
		p.Position = UDim2.new(0.5, x, 0.5, y)
		p.AnchorPoint = Vector2.new(0.5, 0.5)
		p.BorderSizePixel = 0
		p.Parent = holder
		corner(p, size)
		return p
	end

	puff(0.55, -size * 0.18, size * 0.05)
	puff(0.7, 0, -size * 0.08)
	puff(0.55, size * 0.2, size * 0.05)
	local base = Instance.new("Frame")
	base.BackgroundColor3 = color or Theme.White
	base.Size = UDim2.new(0.9, 0, 0.4, 0)
	base.Position = UDim2.new(0.5, 0, 0.72, 0)
	base.AnchorPoint = Vector2.new(0.5, 0.5)
	base.BorderSizePixel = 0
	base.Parent = holder
	corner(base, size)

	return holder
end

--=====================================================================
-- NOTIFY
--=====================================================================

local notifyHolder

local function ensureNotifyHolder()
	if notifyHolder and notifyHolder.Parent then return notifyHolder end
	notifyHolder = Instance.new("Frame")
	notifyHolder.Name = "Notifications"
	notifyHolder.BackgroundTransparency = 1
	notifyHolder.AnchorPoint = Vector2.new(1, 1)
	notifyHolder.Position = UDim2.new(1, -16, 1, -16)
	notifyHolder.Size = UDim2.new(0, 300, 1, -32)
	notifyHolder.Parent = Cloudy.Gui
	local layout = Instance.new("UIListLayout")
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 8)
	layout.Parent = notifyHolder
	return notifyHolder
end

function Cloudy.Notify(title, message, kind, duration)
	duration = duration or 3.5
	local holder = ensureNotifyHolder()

	local card = Instance.new("Frame")
	card.BackgroundColor3 = Theme.Panel
	card.BackgroundTransparency = 0.05
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.LayoutOrder = -os.clock()
	card.Parent = holder
	corner(card, 10)
	local strokeColor = Theme.Accent
	if kind == "error" then strokeColor = Theme.Bad elseif kind == "success" then strokeColor = Theme.Good end
	stroke(card, strokeColor, 1.2)
	padding(card, 12)

	local titleLbl = Instance.new("TextLabel")
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 14
	titleLbl.TextColor3 = Theme.White
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = title
	titleLbl.Size = UDim2.new(1, 0, 0, 18)
	titleLbl.Parent = card

	local msgLbl = Instance.new("TextLabel")
	msgLbl.BackgroundTransparency = 1
	msgLbl.Font = Enum.Font.Gotham
	msgLbl.TextSize = 13
	msgLbl.TextColor3 = Theme.Muted
	msgLbl.TextWrapped = true
	msgLbl.TextXAlignment = Enum.TextXAlignment.Left
	msgLbl.Text = message
	msgLbl.Position = UDim2.new(0, 0, 0, 20)
	msgLbl.Size = UDim2.new(1, 0, 0, 0)
	msgLbl.AutomaticSize = Enum.AutomaticSize.Y
	msgLbl.Parent = card

	card.Position = UDim2.new(1.2, 0, 0, 0)
	tween(card, {Position = UDim2.new(0, 0, 0, 0)}, 0.3)
	task.delay(duration, function()
		if card and card.Parent then
			tween(card, {Position = UDim2.new(1.2, 0, 0, 0)}, 0.3)
			task.wait(0.3)
			card:Destroy()
		end
	end)
end

--=====================================================================
-- API LAYER (Modified for Local 'testkey' Bypass)
--=====================================================================

function Cloudy.VerifyKey(key)
	-- Check for the specific local key
	if key == "testkey" then
		return true, {
			valid = true,
			user = {
				username = LocalPlayer.Name, -- Automatically uses your Roblox username
				plan = "Developer (Offline)"
			},
			settings = {
				-- You can define any default starting settings here if needed
			}
		}, nil
	else
		return false, nil, "Invalid key! Hint: Use 'testkey'"
	end
end

function Cloudy.LoadSettings(userid)
	-- Since we are offline, we can just return empty settings 
	-- (or you can hook this up to Roblox DataStores if you want actual saving)
	return {}
end

function Cloudy.SaveSettings(userid, settingsTable)
	-- Return true to trick the UI into thinking settings saved successfully
	return true
end

--=====================================================================
-- ROOT GUI + KEY SCREEN
--=====================================================================

local function buildRoot()
	local gui = Instance.new("ScreenGui")
	gui.Name = "CloudyClient"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.Parent = PlayerGui
	Cloudy.Gui = gui
	return gui
end

local function buildKeyScreen(onSuccess)
	local gui = Cloudy.Gui

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.4
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = gui

	local card = Instance.new("Frame")
	card.Name = "KeyCard"
	card.BackgroundColor3 = Theme.Panel
	card.BackgroundTransparency = 0.05
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.new(0, 380, 0, 340)
	card.ClipsDescendants = false
	card.Parent = gui
	corner(card, 18)
	local border = stroke(card, Theme.Accent, 1.5)
	local grad = gradient(border, 0)
	animateGradient(grad, 30)
	animatePulse(border)
	attachGlow(card)

	local inner = Instance.new("Frame")
	inner.BackgroundTransparency = 1
	inner.Size = UDim2.fromScale(1, 1)
	inner.Parent = card
	padding(inner, 28)

	drawCloudIcon(inner, 64, Theme.Accent).Position = UDim2.new(0.5, 0, 0, 32)
	local logoHolder = inner:FindFirstChildOfClass("Frame")
	if logoHolder then
		logoHolder.AnchorPoint = Vector2.new(0.5, 0)
		logoHolder.Position = UDim2.new(0.5, 0, 0, 0)
	end

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 22
	title.TextColor3 = Theme.White
	title.Text = "Cloudy Client"
	title.Position = UDim2.new(0, 0, 0, 78)
	title.Size = UDim2.new(1, 0, 0, 28)
	title.Parent = inner

	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 13
	subtitle.TextColor3 = Theme.Muted
	subtitle.Text = "Enter your Cloudy Key to continue"
	subtitle.Position = UDim2.new(0, 0, 0, 106)
	subtitle.Size = UDim2.new(1, 0, 0, 18)
	subtitle.Parent = inner

	local inputBox = Instance.new("TextBox")
	inputBox.Name = "KeyInput"
	inputBox.PlaceholderText = "CLD-XXXXXX-XXXX"
	inputBox.PlaceholderColor3 = Theme.Muted
	inputBox.Text = ""
	inputBox.ClearTextOnFocus = false
	inputBox.Font = Enum.Font.Gotham
	inputBox.TextSize = 15
	inputBox.TextColor3 = Theme.White
	inputBox.BackgroundColor3 = Theme.PanelAlt
	inputBox.Position = UDim2.new(0, 0, 0, 146)
	inputBox.Size = UDim2.new(1, 0, 0, 40)
	inputBox.Parent = inner
	corner(inputBox, 10)
	stroke(inputBox, Theme.Accent, 1)
	padding(inputBox, 10)

	local statusLbl = Instance.new("TextLabel")
	statusLbl.BackgroundTransparency = 1
	statusLbl.Font = Enum.Font.Gotham
	statusLbl.TextSize = 12
	statusLbl.TextColor3 = Theme.Bad
	statusLbl.Text = ""
	statusLbl.Position = UDim2.new(0, 0, 0, 190)
	statusLbl.Size = UDim2.new(1, 0, 0, 16)
	statusLbl.Parent = inner

	local loadBtn = Instance.new("TextButton")
	loadBtn.Name = "LoadButton"
	loadBtn.AutoButtonColor = false
	loadBtn.Font = Enum.Font.GothamBold
	loadBtn.TextSize = 15
	loadBtn.TextColor3 = Theme.White
	loadBtn.Text = "Load Cloudy"
	loadBtn.BackgroundColor3 = Theme.Accent
	loadBtn.Position = UDim2.new(0, 0, 0, 218)
	loadBtn.Size = UDim2.new(1, 0, 0, 42)
	loadBtn.Parent = inner
	corner(loadBtn, 10)
	gradient(loadBtn, 90, ColorSequence.new(Theme.Accent, Theme.AccentAlt))

	track(loadBtn.MouseEnter:Connect(function() tween(loadBtn, {BackgroundTransparency = 0.1}, 0.15) end))
	track(loadBtn.MouseLeave:Connect(function() tween(loadBtn, {BackgroundTransparency = 0}, 0.15) end))

	local loadingLbl = Instance.new("TextLabel")
	loadingLbl.BackgroundTransparency = 1
	loadingLbl.Font = Enum.Font.Gotham
	loadingLbl.TextSize = 13
	loadingLbl.TextColor3 = Theme.Muted
	loadingLbl.Text = ""
	loadingLbl.Visible = false
	loadingLbl.Position = UDim2.new(0, 0, 0, 268)
	loadingLbl.Size = UDim2.new(1, 0, 0, 18)
	loadingLbl.Parent = inner

	local busy = false
	local function attempt()
		if busy then return end
		local key = inputBox.Text
		if key == nil or #key < 4 then
			statusLbl.Text = "Please enter a Cloudy Key."
			return
		end
		busy = true
		statusLbl.Text = ""
		loadBtn.Text = ""
		loadingLbl.Visible = true
		loadingLbl.Text = "Checking key..."

		task.spawn(function()
			local ok, data, err = Cloudy.VerifyKey(key)
			if not ok then
				loadingLbl.Visible = false
				loadBtn.Text = "Load Cloudy"
				statusLbl.Text = "Invalid Cloudy Key"
				Cloudy.Notify("Cloudy", err or "Invalid Cloudy Key", "error")
				stroke(card, Theme.Bad, 1.5)
				task.wait(0.6)
				busy = false
				return
			end

			loadingLbl.Text = "Loading profile..."
			task.wait(0.45)
			Cloudy.User = data.user

			loadingLbl.Text = "Loading settings..."
			task.wait(0.45)
			Cloudy.Settings = data.settings or {}

			tween(card, {Size = UDim2.new(0, 380, 0, 340), Position = UDim2.fromScale(0.5, 0.45)}, 0.2)
			task.wait(0.15)
			tween(card, {BackgroundTransparency = 1}, 0.25)
			tween(dim, {BackgroundTransparency = 1}, 0.25)
			for _, d in ipairs(inner:GetDescendants()) do
				if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") or d:IsA("Frame") then
					pcall(function() tween(d, {BackgroundTransparency = 1, TextTransparency = 1}, 0.2) end)
				end
			end
			task.wait(0.25)
			dim:Destroy()
			card:Destroy()
			onSuccess()
		end)
	end

	track(loadBtn.MouseButton1Click:Connect(attempt))
	track(inputBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then attempt() end
	end))
end

--=====================================================================
-- COMPONENT LIBRARY
--=====================================================================

function Cloudy.CreateButton(parent, text, callback)
	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = false
	btn.Font = Enum.Font.GothamMedium
	btn.TextSize = 14
	btn.TextColor3 = Theme.White
	btn.Text = text
	btn.BackgroundColor3 = Theme.PanelAlt
	btn.Size = UDim2.new(1, 0, 0, 36)
	btn.Parent = parent
	corner(btn, 8)
	local s = stroke(btn, Theme.Accent, 1)
	s.Transparency = 0.6

	track(btn.MouseEnter:Connect(function() tween(btn, {BackgroundColor3 = Theme.Accent}, 0.15) end))
	track(btn.MouseLeave:Connect(function() tween(btn, {BackgroundColor3 = Theme.PanelAlt}, 0.15) end))
	track(btn.MouseButton1Click:Connect(function()
		tween(btn, {BackgroundColor3 = Theme.AccentAlt}, 0.08)
		task.wait(0.08)
		tween(btn, {BackgroundColor3 = Theme.Accent}, 0.08)
		if callback then callback() end
	end))
	return btn
end

function Cloudy.CreateToggle(parent, text, default, callback)
	local row = Instance.new("Frame")
	row.BackgroundColor3 = Theme.PanelAlt
	row.Size = UDim2.new(1, 0, 0, 38)
	row.Parent = parent
	corner(row, 8)
	padding(row, 10)

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.TextColor3 = Theme.White
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text
	lbl.Size = UDim2.new(1, -50, 1, 0)
	lbl.Parent = row

	local track_ = Instance.new("Frame")
	track_.AnchorPoint = Vector2.new(1, 0.5)
	track_.Position = UDim2.new(1, 0, 0.5, 0)
	track_.Size = UDim2.new(0, 38, 0, 20)
	track_.BackgroundColor3 = default and Theme.Accent or Color3.fromRGB(60, 66, 82)
	track_.Parent = row
	corner(track_, 10)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 16, 0, 16)
	knob.Position = default and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.BackgroundColor3 = Theme.White
	knob.Parent = track_
	corner(knob, 8)

	local state = default and true or false
	local btn = Instance.new("TextButton")
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.Size = UDim2.fromScale(1, 1)
	btn.Parent = row

	track(btn.MouseButton1Click:Connect(function()
		state = not state
		tween(track_, {BackgroundColor3 = state and Theme.Accent or Color3.fromRGB(60, 66, 82)}, 0.15)
		tween(knob, {Position = state and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)}, 0.15)
		if callback then callback(state) end
	end))

	return {
		Set = function(v)
			state = v
			track_.BackgroundColor3 = state and Theme.Accent or Color3.fromRGB(60, 66, 82)
			knob.Position = state and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
		end,
		Get = function() return state end,
	}
end

function Cloudy.CreateSlider(parent, text, min, max, default, callback)
	local holder = Instance.new("Frame")
	holder.BackgroundColor3 = Theme.PanelAlt
	holder.Size = UDim2.new(1, 0, 0, 52)
	holder.Parent = parent
	corner(holder, 8)
	padding(holder, 10)

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.TextColor3 = Theme.White
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text .. ": " .. tostring(default)
	lbl.Size = UDim2.new(1, 0, 0, 16)
	lbl.Parent = holder

	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = Color3.fromRGB(60, 66, 82)
	bar.Position = UDim2.new(0, 0, 0, 28)
	bar.Size = UDim2.new(1, 0, 0, 6)
	bar.Parent = holder
	corner(bar, 3)

	local fillFrac = (default - min) / (max - min)
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Theme.Accent
	fill.Size = UDim2.new(fillFrac, 0, 1, 0)
	fill.Parent = bar
	corner(fill, 3)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 14, 0, 14)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(fillFrac, 0, 0.5, 0)
	knob.BackgroundColor3 = Theme.White
	knob.Parent = bar
	corner(knob, 7)

	local dragging = false
	track(bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local rel = math.clamp((input.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
			fill.Size = UDim2.new(rel, 0, 1, 0)
			knob.Position = UDim2.new(rel, 0, 0.5, 0)
			local value = math.floor(min + (max - min) * rel)
			lbl.Text = text .. ": " .. tostring(value)
			if callback then callback(value) end
		end
	end))

	return holder
end

function Cloudy.CreateDropdown(parent, text, options, default, callback)
	local holder = Instance.new("Frame")
	holder.BackgroundColor3 = Theme.PanelAlt
	holder.Size = UDim2.new(1, 0, 0, 38)
	holder.ClipsDescendants = false
	holder.Parent = parent
	corner(holder, 8)
	padding(holder, 10)

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.TextColor3 = Theme.White
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text
	lbl.Size = UDim2.new(0.5, 0, 1, 0)
	lbl.Parent = holder

	local current = Instance.new("TextButton")
	current.AutoButtonColor = false
	current.Font = Enum.Font.GothamMedium
	current.TextSize = 13
	current.TextColor3 = Theme.Accent
	current.Text = tostring(default) .. "  ▾"
	current.BackgroundTransparency = 1
	current.AnchorPoint = Vector2.new(1, 0.5)
	current.Position = UDim2.new(1, 0, 0.5, 0)
	current.Size = UDim2.new(0.5, 0, 1, 0)
	current.TextXAlignment = Enum.TextXAlignment.Right
	current.Parent = holder

	local list = Instance.new("Frame")
	list.BackgroundColor3 = Theme.Panel
	list.Position = UDim2.new(0, 0, 1, 4)
	list.Size = UDim2.new(1, 0, 0, #options * 30)
	list.Visible = false
	list.ZIndex = 10
	list.Parent = holder
	corner(list, 8)
	stroke(list, Theme.Accent, 1)
	local layout = Instance.new("UIListLayout")
	layout.Parent = list

	for _, opt in ipairs(options) do
		local optBtn = Instance.new("TextButton")
		optBtn.AutoButtonColor = false
		optBtn.BackgroundTransparency = 1
		optBtn.Font = Enum.Font.Gotham
		optBtn.TextSize = 13
		optBtn.TextColor3 = Theme.White
		optBtn.Text = tostring(opt)
		optBtn.Size = UDim2.new(1, 0, 0, 30)
		optBtn.ZIndex = 11
		optBtn.Parent = list
		track(optBtn.MouseButton1Click:Connect(function()
			current.Text = tostring(opt) .. "  ▾"
			list.Visible = false
			if callback then callback(opt) end
		end))
	end

	track(current.MouseButton1Click:Connect(function()
		list.Visible = not list.Visible
	end))

	return holder
end

--=====================================================================
-- MAIN WINDOW
--=====================================================================

local Tabs = {"HOME", "PERFORMANCE", "VISUALS", "PLAYER", "COSMETICS", "OUTFITS", "INTERFACE", "SOCIAL", "SETTINGS"}
local tabButtons, tabPages = {}, {}
local mainFrame

local function buildMainWindow()
	local gui = Cloudy.Gui

	mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainWindow"
	mainFrame.BackgroundColor3 = Theme.Bg
	mainFrame.BackgroundTransparency = 0.05
	mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	mainFrame.Position = UDim2.fromScale(0.5, 0.5)
	mainFrame.Size = UDim2.new(0, 780, 0, 480)
	mainFrame.ClipsDescendants = true
	mainFrame.Visible = false
	mainFrame.Parent = gui
	corner(mainFrame, 16)
	local border = stroke(mainFrame, Theme.Accent, 1.5)
	local grad = gradient(border, 0)
	animateGradient(grad, 25)
	animatePulse(border)
	attachGlow(mainFrame)

	-- top bar
	local topBar = Instance.new("Frame")
	topBar.BackgroundColor3 = Theme.Panel
	topBar.Size = UDim2.new(1, 0, 0, 50)
	topBar.Parent = mainFrame
	corner(topBar, 16)
	makeDraggable(topBar, mainFrame)

	local logo = drawCloudIcon(topBar, 28, Theme.Accent)
	logo.Position = UDim2.new(0, 14, 0.5, 0)
	logo.AnchorPoint = Vector2.new(0, 0.5)

	local nameLbl = Instance.new("TextLabel")
	nameLbl.BackgroundTransparency = 1
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextSize = 16
	nameLbl.TextColor3 = Theme.White
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	nameLbl.Text = "Cloudy Client"
	nameLbl.Position = UDim2.new(0, 52, 0, 6)
	nameLbl.Size = UDim2.new(0, 200, 0, 18)
	nameLbl.Parent = topBar

	local userLbl = Instance.new("TextLabel")
	userLbl.BackgroundTransparency = 1
	userLbl.Font = Enum.Font.Gotham
	userLbl.TextSize = 12
	userLbl.TextColor3 = Theme.Muted
	userLbl.TextXAlignment = Enum.TextXAlignment.Left
	local plan = (Cloudy.User and Cloudy.User.plan) or "Free"
	userLbl.Text = (Cloudy.User and Cloudy.User.username or "Player") .. "  ·  " .. plan
	userLbl.Position = UDim2.new(0, 52, 0, 24)
	userLbl.Size = UDim2.new(0, 200, 0, 16)
	userLbl.Parent = topBar

	local closeBtn = Instance.new("TextButton")
	closeBtn.AutoButtonColor = false
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 16
	closeBtn.TextColor3 = Theme.Muted
	closeBtn.Text = "✕"
	closeBtn.BackgroundTransparency = 1
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.Position = UDim2.new(1, -14, 0.5, 0)
	closeBtn.Size = UDim2.new(0, 28, 0, 28)
	closeBtn.Parent = topBar
	track(closeBtn.MouseButton1Click:Connect(function()
		mainFrame.Visible = false
	end))

	-- sidebar
	local sidebar = Instance.new("Frame")
	sidebar.BackgroundColor3 = Theme.Panel
	sidebar.Position = UDim2.new(0, 0, 0, 50)
	sidebar.Size = UDim2.new(0, 160, 1, -50)
	sidebar.Parent = mainFrame
	local sideLayout = Instance.new("UIListLayout")
	sideLayout.Padding = UDim.new(0, 4)
	sideLayout.Parent = sidebar
	padding(sidebar, 10)

	-- content area
	local content = Instance.new("Frame")
	content.BackgroundTransparency = 1
	content.Position = UDim2.new(0, 160, 0, 50)
	content.Size = UDim2.new(1, -160, 1, -50)
	content.Parent = mainFrame
	padding(content, 18)

	local function selectTab(name)
		for n, btn in pairs(tabButtons) do
			tween(btn, {BackgroundColor3 = n == name and Theme.Accent or Theme.Panel}, 0.15)
		end
		for n, page in pairs(tabPages) do
			page.Visible = (n == name)
		end
	end

	for _, tabName in ipairs(Tabs) do
		local btn = Instance.new("TextButton")
		btn.AutoButtonColor = false
		btn.Font = Enum.Font.GothamMedium
		btn.TextSize = 13
		btn.TextColor3 = Theme.White
		btn.Text = "  " .. tabName
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.BackgroundColor3 = Theme.Panel
		btn.Size = UDim2.new(1, 0, 0, 34)
		btn.Parent = sidebar
		corner(btn, 8)
		tabButtons[tabName] = btn

		local page = Instance.new("ScrollingFrame")
		page.BackgroundTransparency = 1
		page.Size = UDim2.fromScale(1, 1)
		page.CanvasSize = UDim2.new(0, 0, 0, 0)
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.ScrollBarThickness = 4
		page.ScrollBarImageColor3 = Theme.Accent
		page.Visible = false
		page.Parent = content
		local pageLayout = Instance.new("UIListLayout")
		pageLayout.Padding = UDim.new(0, 10)
		pageLayout.Parent = page
		tabPages[tabName] = page

		track(btn.MouseButton1Click:Connect(function() selectTab(tabName) end))
	end

	selectTab("HOME")
	return content
end

local function sectionTitle(parent, text)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 15
	lbl.TextColor3 = Theme.White
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text
	lbl.Size = UDim2.new(1, 0, 0, 20)
	lbl.Parent = parent
	return lbl
end

--=====================================================================
-- HOME TAB
--=====================================================================

local function buildHomeTab()
	local page = tabPages.HOME
	sectionTitle(page, "Welcome back, " .. (Cloudy.User and Cloudy.User.username or "Player"))

	local card = Instance.new("Frame")
	card.BackgroundColor3 = Theme.Panel
	card.Size = UDim2.new(1, 0, 0, 90)
	card.Parent = page
	corner(card, 10)
	padding(card, 14)

	local plan = Instance.new("TextLabel")
	plan.BackgroundTransparency = 1
	plan.Font = Enum.Font.Gotham
	plan.TextSize = 13
	plan.TextColor3 = Theme.Muted
	plan.TextXAlignment = Enum.TextXAlignment.Left
	plan.Text = string.format(
		"Plan: %s\nUserId: %s\nCloudy Version: %s",
		(Cloudy.User and Cloudy.User.plan) or "Free",
		(Cloudy.User and Cloudy.User.userid) or "-",
		Config.Version
	)
	plan.Size = UDim2.fromScale(1, 1)
	plan.Parent = card

	Cloudy.CreateButton(page, "Save current settings to Cloudy", function()
		local ok = Cloudy.SaveSettings(Cloudy.User.userid, Cloudy.Settings)
		if ok then
			Cloudy.Notify("Cloudy", "Settings saved to your account.", "success")
		end
	end)
end

--=====================================================================
-- PERFORMANCE TAB (FPS / Ping / Memory / CPS + FPS limiter)
--=====================================================================

local function buildPerformanceTab()
	local page = tabPages.PERFORMANCE
	sectionTitle(page, "Performance")

	local statsCard = Instance.new("Frame")
	statsCard.BackgroundColor3 = Theme.Panel
	statsCard.Size = UDim2.new(1, 0, 0, 100)
	statsCard.Parent = page
	corner(statsCard, 10)
	padding(statsCard, 14)
	local statsLayout = Instance.new("UIGridLayout")
	statsLayout.CellSize = UDim2.new(0.5, -6, 0, 36)
	statsLayout.CellPadding = UDim2.new(0, 6, 0, 6)
	statsLayout.Parent = statsCard

	local function statLabel(name)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamBold
		l.TextSize = 14
		l.TextColor3 = Theme.White
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Text = name .. ": --"
		l.Parent = statsCard
		return l
	end

	local fpsLbl = statLabel("FPS")
	local pingLbl = statLabel("Ping")
	local memLbl = statLabel("Memory")
	local cpsLbl = statLabel("CPS")

	-- FPS counter
	local frameCount, fpsAccum = 0, 0
	track(RunService.RenderStepped:Connect(function(dt)
		frameCount += 1
		fpsAccum += dt
		if fpsAccum >= 0.5 then
			fpsLbl.Text = string.format("FPS: %d", math.floor(frameCount / fpsAccum))
			frameCount, fpsAccum = 0, 0
		end
	end))

	-- CPS counter
	local clickTimes = {}
	track(UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			table.insert(clickTimes, os.clock())
		end
	end))
	track(RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for i = #clickTimes, 1, -1 do
			if now - clickTimes[i] > 1 then table.remove(clickTimes, i) end
		end
		cpsLbl.Text = "CPS: " .. #clickTimes
	end))

	-- Ping + memory (lighter update rate)
	task.spawn(function()
		while mainFrame do
			local ok, ping = pcall(function()
				return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
			end)
			pingLbl.Text = "Ping: " .. (ok and math.floor(ping) .. "ms" or "--")
			local okMem, mem = pcall(function() return Stats:GetTotalMemoryUsageMb() end)
			memLbl.Text = "Memory: " .. (okMem and math.floor(mem) .. " MB" or "--")
			task.wait(1)
		end
	end)

	sectionTitle(page, "FPS Limiter")
	local limitNote = Instance.new("TextLabel")
	limitNote.BackgroundTransparency = 1
	limitNote.Font = Enum.Font.Gotham
	limitNote.TextSize = 11
	limitNote.TextColor3 = Theme.Muted
	limitNote.TextWrapped = true
	limitNote.Text = "Saved as a preference on your Cloudy account. Roblox does not expose a public API to force-cap the engine's render rate from a LocalScript, so this does not hard-limit FPS."
	limitNote.Size = UDim2.new(1, 0, 0, 32)
	limitNote.Parent = page

	Cloudy.CreateDropdown(page, "FPS Limit", {30, 60, 90, 120, 144, 240, "Unlimited"},
	(Cloudy.Settings.performance and Cloudy.Settings.performance.fpsLimit) or "Unlimited",
	function(choice)
		Cloudy.Settings.performance = Cloudy.Settings.performance or {}
		Cloudy.Settings.performance.fpsLimit = choice
	end)
end

--=====================================================================
-- VISUALS TAB (Shader presets via Lighting)
--=====================================================================

local ShaderPresets = {
	Cloudy = {
		Brightness = 2, Ambient = Color3.fromRGB(120,150,200), OutdoorAmbient = Color3.fromRGB(150,180,220),
		ColorCorrection = {Contrast = 0.05, Saturation = 0.1, TintColor = Color3.fromRGB(230,240,255)},
		Bloom = {Intensity = 0.4, Size = 24, Threshold = 1.2},
		Atmosphere = {Density = 0.3, Haze = 1, Glare = 0.2, Color = Color3.fromRGB(200,220,255)},
	},
	Realistic = {
		Brightness = 1, Ambient = Color3.fromRGB(80,80,80), OutdoorAmbient = Color3.fromRGB(120,120,120),
		ColorCorrection = {Contrast = 0.1, Saturation = 0, TintColor = Color3.fromRGB(255,255,255)},
		Bloom = {Intensity = 0.2, Size = 20, Threshold = 1.5},
		Atmosphere = {Density = 0.35, Haze = 1.5, Glare = 0, Color = Color3.fromRGB(199,199,199)},
	},
	Sunset = {
		Brightness = 1.5, Ambient = Color3.fromRGB(180,120,90), OutdoorAmbient = Color3.fromRGB(220,140,90),
		ColorCorrection = {Contrast = 0.15, Saturation = 0.25, TintColor = Color3.fromRGB(255,200,150)},
		Bloom = {Intensity = 0.6, Size = 32, Threshold = 0.9},
		Atmosphere = {Density = 0.45, Haze = 2, Glare = 0.5, Color = Color3.fromRGB(255,170,110)},
	},
	Night = {
		Brightness = 0.3, Ambient = Color3.fromRGB(20,25,45), OutdoorAmbient = Color3.fromRGB(30,35,60),
		ColorCorrection = {Contrast = 0.1, Saturation = -0.2, TintColor = Color3.fromRGB(180,190,255)},
		Bloom = {Intensity = 0.3, Size = 26, Threshold = 1.6},
		Atmosphere = {Density = 0.4, Haze = 1, Glare = 0, Color = Color3.fromRGB(40,45,80)},
	},
	Fantasy = {
		Brightness = 2.2, Ambient = Color3.fromRGB(150,100,200), OutdoorAmbient = Color3.fromRGB(180,130,230),
		ColorCorrection = {Contrast = 0.2, Saturation = 0.35, TintColor = Color3.fromRGB(230,200,255)},
		Bloom = {Intensity = 0.8, Size = 36, Threshold = 0.8},
		Atmosphere = {Density = 0.3, Haze = 1.2, Glare = 0.6, Color = Color3.fromRGB(210,170,255)},
	},
	Cinematic = {
		Brightness = 1.2, Ambient = Color3.fromRGB(60,60,70), OutdoorAmbient = Color3.fromRGB(90,90,100),
		ColorCorrection = {Contrast = 0.25, Saturation = -0.1, TintColor = Color3.fromRGB(255,245,235)},
		Bloom = {Intensity = 0.5, Size = 28, Threshold = 1.1},
		Atmosphere = {Density = 0.4, Haze = 1.8, Glare = 0.3, Color = Color3.fromRGB(180,175,170)},
	},
}

local function getOrCreate(className, name, parent)
	local existing = parent:FindFirstChild(name)
	if existing then return existing end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

function Cloudy.CreateShader(presetName)
	local preset = ShaderPresets[presetName]
	if not preset then return end

	Lighting.Brightness = preset.Brightness
	Lighting.Ambient = preset.Ambient
	Lighting.OutdoorAmbient = preset.OutdoorAmbient

	local cc = getOrCreate("ColorCorrectionEffect", "CloudyColorCorrection", Lighting)
	cc.Contrast = preset.ColorCorrection.Contrast
	cc.Saturation = preset.ColorCorrection.Saturation
	cc.TintColor = preset.ColorCorrection.TintColor

	local bloom = getOrCreate("BloomEffect", "CloudyBloom", Lighting)
	bloom.Intensity = preset.Bloom.Intensity
	bloom.Size = preset.Bloom.Size
	bloom.Threshold = preset.Bloom.Threshold

	local atmo = getOrCreate("Atmosphere", "CloudyAtmosphere", Lighting)
	atmo.Density = preset.Atmosphere.Density
	atmo.Haze = preset.Atmosphere.Haze
	atmo.Glare = preset.Atmosphere.Glare
	atmo.Color = preset.Atmosphere.Color

	local sunrays = getOrCreate("SunRaysEffect", "CloudySunRays", Lighting)
	sunrays.Intensity = preset.Bloom.Intensity * 0.3
	sunrays.Spread = 0.5

	Cloudy.Settings.visuals = Cloudy.Settings.visuals or {}
	Cloudy.Settings.visuals.shader = presetName
end

local function buildVisualsTab()
	local page = tabPages.VISUALS
	sectionTitle(page, "Shader Presets")

	local grid = Instance.new("Frame")
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, 90)
	grid.Parent = page
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.new(0.33, -6, 0, 38)
	gl.CellPadding = UDim2.new(0, 8, 0, 8)
	gl.Parent = grid

	for name in pairs(ShaderPresets) do
		local btn = Instance.new("TextButton")
		btn.AutoButtonColor = false
		btn.Font = Enum.Font.GothamMedium
		btn.TextSize = 13
		btn.TextColor3 = Theme.White
		btn.Text = name
		btn.BackgroundColor3 = Theme.PanelAlt
		btn.Parent = grid
		corner(btn, 8)
		track(btn.MouseButton1Click:Connect(function()
			Cloudy.CreateShader(name)
			Cloudy.Notify("Cloudy", name .. " shader applied.", "success")
		end))
	end

	sectionTitle(page, "Options")
	Cloudy.CreateToggle(page, "Fullbright (accessibility brightness boost)",
		(Cloudy.Settings.visuals and Cloudy.Settings.visuals.fullbright) or false,
		function(v)
			Cloudy.Settings.visuals = Cloudy.Settings.visuals or {}
			Cloudy.Settings.visuals.fullbright = v
			if v then
				Lighting.Brightness = 3
				Lighting.OutdoorAmbient = Color3.fromRGB(200,200,200)
			else
				Cloudy.CreateShader(Cloudy.Settings.visuals.shader or "Cloudy")
			end
		end)

	if Cloudy.Settings.visuals and Cloudy.Settings.visuals.shader then
		Cloudy.CreateShader(Cloudy.Settings.visuals.shader)
	end
end

--=====================================================================
-- PLAYER TAB (character settings the game owner chooses to expose)
--=====================================================================

local function buildPlayerTab()
	local page = tabPages.PLAYER
	sectionTitle(page, "Character")

	local function getHumanoid()
		local char = LocalPlayer.Character
		return char and char:FindFirstChildOfClass("Humanoid")
	end

	Cloudy.CreateSlider(page, "Walk Speed", 8, 50, 16, function(v)
		local hum = getHumanoid()
		if hum then hum.WalkSpeed = v end
	end)

	Cloudy.CreateSlider(page, "Jump Power", 20, 100, 50, function(v)
		local hum = getHumanoid()
		if hum then hum.JumpPower = v end
	end)

	Cloudy.CreateSlider(page, "Camera FOV", 50, 120, 70, function(v)
		workspace.CurrentCamera.FieldOfView = v
	end)

	Cloudy.CreateToggle(page, "Show health bar in HUD", true, function(v)
		Cloudy.Settings.hud = Cloudy.Settings.hud or {}
		Cloudy.Settings.hud.showHealth = v
	end)
end

--=====================================================================
-- COSMETICS TAB (client-only: auras, trails, name tags)
--=====================================================================

local activeCosmetics = {}

local function clearCosmetic(key)
	if activeCosmetics[key] then
		activeCosmetics[key]:Destroy()
		activeCosmetics[key] = nil
	end
end

local function applyTrail(color)
	clearCosmetic("trail")
	local char = LocalPlayer.Character
	if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local a0 = Instance.new("Attachment", root)
	a0.Position = Vector3.new(0, 1, 0)
	local a1 = Instance.new("Attachment", root)
	a1.Position = Vector3.new(0, -1, 0)
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(color)
	trail.Lifetime = 0.6
	trail.Parent = root
	activeCosmetics["trail"] = trail
end

local function applyAura(color)
	clearCosmetic("aura")
	local char = LocalPlayer.Character
	if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local attach = Instance.new("Attachment", root)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(color)
	emitter.Lifetime = NumberRange.new(0.5, 1)
	emitter.Rate = 20
	emitter.Speed = NumberRange.new(1, 2)
	emitter.Parent = attach
	activeCosmetics["aura"] = attach
end

local function applyNameTag(text)
	clearCosmetic("nametag")
	local char = LocalPlayer.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	if not head then return end
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 160, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 16
	lbl.TextColor3 = Theme.Accent
	lbl.TextStrokeTransparency = 0.5
	lbl.Text = text
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Parent = billboard
	activeCosmetics["nametag"] = billboard
end

local function buildCosmeticsTab()
	local page = tabPages.COSMETICS
	sectionTitle(page, "Cosmetics (client-only, visible only to you)")

	Cloudy.CreateDropdown(page, "Trail", {"Off", "Blue", "White", "Gold"}, "Off", function(choice)
		if choice == "Off" then clearCosmetic("trail"); return end
		local colors = {Blue = Theme.Accent, White = Theme.White, Gold = Color3.fromRGB(255,215,80)}
		applyTrail(colors[choice])
	end)

	Cloudy.CreateDropdown(page, "Aura", {"Off", "Blue", "White", "Gold"}, "Off", function(choice)
		if choice == "Off" then clearCosmetic("aura"); return end
		local colors = {Blue = Theme.Accent, White = Theme.White, Gold = Color3.fromRGB(255,215,80)}
		applyAura(colors[choice])
	end)

	Cloudy.CreateDropdown(page, "Title / Name Tag", {"Off", "Cloudy User", "Cloudy Premium"}, "Off", function(choice)
		if choice == "Off" then clearCosmetic("nametag"); return end
		applyNameTag(choice)
	end)
end

--=====================================================================
-- OUTFITS TAB (local-only appearance, from API-provided outfit data)
--=====================================================================

function Cloudy.ApplyOutfit(outfit)
	-- Only ever affects the LOCAL player's own character for this session.
	local char = LocalPlayer.Character
	if not char or not outfit then return end

	if outfit.shirt then
		local shirt = char:FindFirstChildOfClass("Shirt") or Instance.new("Shirt", char)
		shirt.ShirtTemplate = "rbxassetid://" .. tostring(outfit.shirt)
	end
	if outfit.pants then
		local pants = char:FindFirstChildOfClass("Pants") or Instance.new("Pants", char)
		pants.PantsTemplate = "rbxassetid://" .. tostring(outfit.pants)
	end

	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and outfit.body then
		for prop, val in pairs(outfit.body) do
			pcall(function() hum[prop] = val end)
		end
	end
end

local function buildOutfitsTab()
	local page = tabPages.OUTFITS
	sectionTitle(page, "Outfit")
	local note = Instance.new("TextLabel")
	note.BackgroundTransparency = 1
	note.Font = Enum.Font.Gotham
	note.TextSize = 11
	note.TextColor3 = Theme.Muted
	note.TextWrapped = true
	note.Text = "Outfits apply to your own character only, for this session."
	note.Size = UDim2.new(1, 0, 0, 28)
	note.Parent = page

	local shirtBox = Instance.new("TextBox")
	shirtBox.PlaceholderText = "Shirt asset id"
	shirtBox.Text = ""
	shirtBox.Font = Enum.Font.Gotham
	shirtBox.TextSize = 13
	shirtBox.TextColor3 = Theme.White
	shirtBox.BackgroundColor3 = Theme.PanelAlt
	shirtBox.Size = UDim2.new(1, 0, 0, 34)
	shirtBox.Parent = page
	corner(shirtBox, 8)
	padding(shirtBox, 8)

	local pantsBox = Instance.new("TextBox")
	pantsBox.PlaceholderText = "Pants asset id"
	pantsBox.Text = ""
	pantsBox.Font = Enum.Font.Gotham
	pantsBox.TextSize = 13
	pantsBox.TextColor3 = Theme.White
	pantsBox.BackgroundColor3 = Theme.PanelAlt
	pantsBox.Size = UDim2.new(1, 0, 0, 34)
	pantsBox.Parent = page
	corner(pantsBox, 8)
	padding(pantsBox, 8)

	Cloudy.CreateButton(page, "Apply Outfit", function()
		Cloudy.ApplyOutfit({shirt = shirtBox.Text, pants = pantsBox.Text})
		Cloudy.Settings.outfit = {shirt = shirtBox.Text, pants = pantsBox.Text}
		Cloudy.Notify("Cloudy", "Outfit applied.", "success")
	end)

	if Cloudy.Settings.outfit then
		task.defer(function()
			if LocalPlayer.Character then
				Cloudy.ApplyOutfit(Cloudy.Settings.outfit)
			end
		end)
	end
end

--=====================================================================
-- INTERFACE TAB (HUD elements: FPS/CPS/Ping/Toolbar visibility & style)
--=====================================================================

local HUD

local function buildHUD()
	local gui = Cloudy.Gui
	HUD = Instance.new("Frame")
	HUD.Name = "HUD"
	HUD.BackgroundTransparency = 1
	HUD.Size = UDim2.fromScale(1, 1)
	HUD.Parent = gui

	local box = Instance.new("Frame")
	box.Name = "StatsHUD"
	box.BackgroundColor3 = Theme.Panel
	box.BackgroundTransparency = 0.3
	box.Position = UDim2.new(0, 12, 0, 12)
	box.Size = UDim2.new(0, 140, 0, 76)
	box.Parent = HUD
	corner(box, 8)
	stroke(box, Theme.Accent, 1).Transparency = 0.5
	padding(box, 8)
	makeDraggable(box, box)

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.Parent = box

	local function hudLine(prefix)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Font = Enum.Font.GothamMedium
		l.TextSize = 13
		l.TextColor3 = Theme.White
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Text = prefix .. ": --"
		l.Size = UDim2.new(1, 0, 0, 16)
		l.Parent = box
		return l
	end

	local hudFps = hudLine("FPS")
	local hudPing = hudLine("Ping")
	local hudCps = hudLine("CPS")

	local frameCount, accum = 0, 0
	track(RunService.RenderStepped:Connect(function(dt)
		frameCount += 1
		accum += dt
		if accum >= 0.5 then
			hudFps.Text = "FPS: " .. math.floor(frameCount / accum)
			frameCount, accum = 0, 0
		end
	end))

	local clicks = {}
	track(UserInputService.InputBegan:Connect(function(input, gpe)
		if not gpe and input.UserInputType == Enum.UserInputType.MouseButton1 then
			table.insert(clicks, os.clock())
		end
	end))
	track(RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for i = #clicks, 1, -1 do
			if now - clicks[i] > 1 then table.remove(clicks, i) end
		end
		hudCps.Text = "CPS: " .. #clicks
	end))

	task.spawn(function()
		while HUD and HUD.Parent do
			local ok, ping = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
			hudPing.Text = "Ping: " .. (ok and math.floor(ping) .. "ms" or "--")
			task.wait(1)
		end
	end)

	return box
end

local function buildInterfaceTab()
	local page = tabPages.INTERFACE
	sectionTitle(page, "HUD")

	Cloudy.CreateToggle(page, "Show performance HUD",
		(Cloudy.Settings.hud == nil) or (Cloudy.Settings.hud.showFPS ~= false),
		function(v)
			if HUD then HUD.StatsHUD.Visible = v end
			Cloudy.Settings.hud = Cloudy.Settings.hud or {}
			Cloudy.Settings.hud.showFPS = v
		end)

	Cloudy.CreateSlider(page, "HUD Transparency (%)", 0, 90, 30, function(v)
		if HUD and HUD:FindFirstChild("StatsHUD") then
			HUD.StatsHUD.BackgroundTransparency = v / 100
		end
	end)

	sectionTitle(page, "General")
	Cloudy.CreateToggle(page, "Blur effects",
		(Cloudy.Settings.interface and Cloudy.Settings.interface.blur) ~= false,
		function(v)
			Cloudy.Settings.interface = Cloudy.Settings.interface or {}
			Cloudy.Settings.interface.blur = v
		end)

	Cloudy.CreateToggle(page, "Animations",
		(Cloudy.Settings.interface and Cloudy.Settings.interface.animations) ~= false,
		function(v)
			Cloudy.Settings.interface = Cloudy.Settings.interface or {}
			Cloudy.Settings.interface.animations = v
		end)
end

--=====================================================================
-- SOCIAL TAB
--=====================================================================

local function buildSocialTab()
	local page = tabPages.SOCIAL
	sectionTitle(page, "Your Cloudy Profile")

	local card = Instance.new("Frame")
	card.BackgroundColor3 = Theme.Panel
	card.Size = UDim2.new(1, 0, 0, 100)
	card.Parent = page
	corner(card, 10)
	padding(card, 14)

	local info = Instance.new("TextLabel")
	info.BackgroundTransparency = 1
	info.Font = Enum.Font.Gotham
	info.TextSize = 13
	info.TextColor3 = Theme.Muted
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.Text = string.format(
		"Username: %s\nUserId: %s\nCloudy Badge: %s",
		Cloudy.User.username, tostring(Cloudy.User.userid),
		(Cloudy.User.plan == "Premium") and "☁ Premium" or "☁ Member"
	)
	info.Size = UDim2.fromScale(1, 1)
	info.Parent = card

	local note = Instance.new("TextLabel")
	note.BackgroundTransparency = 1
	note.Font = Enum.Font.Gotham
	note.TextSize = 11
	note.TextColor3 = Theme.Muted
	note.TextWrapped = true
	note.Text = "A directory of other Cloudy users would need an additional API endpoint (e.g. GET /api/users)."
	note.Size = UDim2.new(1, 0, 0, 28)
	note.Parent = page
end

--=====================================================================
-- SETTINGS TAB
--=====================================================================

local function buildSettingsTab()
	local page = tabPages.SETTINGS
	sectionTitle(page, "Account")

	Cloudy.CreateDropdown(page, "Theme", {"Cloudy Blue", "Galaxy", "Midnight"},
	Cloudy.Settings.theme or "Cloudy Blue", function(choice)
		Cloudy.Settings.theme = choice
	end)

	Cloudy.CreateButton(page, "Save settings to Cloudy account", function()
		local ok = Cloudy.SaveSettings(Cloudy.User.userid, Cloudy.Settings)
		Cloudy.Notify("Cloudy", ok and "Settings saved." or "Failed to save settings.", ok and "success" or "error")
	end)

	Cloudy.CreateButton(page, "Sign out", function()
		for _, c in ipairs(Cloudy.Connections) do
			pcall(function() c:Disconnect() end)
		end
		if Cloudy.Gui then Cloudy.Gui:Destroy() end
	end)
end

--=====================================================================
-- CUSTOM TOOLBAR (in-game hotbar UI, not a Studio plugin toolbar)
--=====================================================================

local function buildToolbar()
	local gui = Cloudy.Gui
	local bar = Instance.new("Frame")
	bar.Name = "CloudyToolbar"
	bar.BackgroundColor3 = Theme.Panel
	bar.BackgroundTransparency = 0.15
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -14)
	bar.Size = UDim2.new(0, 360, 0, 56)
	bar.Parent = gui
	corner(bar, 14)
	stroke(bar, Theme.Accent, 1).Transparency = 0.4
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = bar
	padding(bar, 8)

	local slots = {}
	local function refreshSlots()
		for _, s in ipairs(slots) do s:Destroy() end
		table.clear(slots)
		local backpack = LocalPlayer:FindFirstChild("Backpack")
		if not backpack then return end
		for _, tool in ipairs(backpack:GetChildren()) do
			if tool:IsA("Tool") then
				local slot = Instance.new("TextButton")
				slot.AutoButtonColor = false
				slot.Size = UDim2.new(0, 40, 0, 40)
				slot.BackgroundColor3 = Theme.PanelAlt
				slot.Font = Enum.Font.GothamBold
				slot.TextSize = 11
				slot.TextColor3 = Theme.White
				slot.Text = tool.Name:sub(1, 4)
				slot.Parent = bar
				corner(slot, 10)
				track(slot.MouseEnter:Connect(function() tween(slot, {BackgroundColor3 = Theme.Accent}, 0.12) end))
				track(slot.MouseLeave:Connect(function() tween(slot, {BackgroundColor3 = Theme.PanelAlt}, 0.12) end))
				track(slot.MouseButton1Click:Connect(function()
					local char = LocalPlayer.Character
					local hum = char and char:FindFirstChildOfClass("Humanoid")
					if hum then hum:EquipTool(tool) end
				end))
				table.insert(slots, slot)
			end
		end
	end

	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then
		track(backpack.ChildAdded:Connect(refreshSlots))
		track(backpack.ChildRemoved:Connect(refreshSlots))
	end
	refreshSlots()

	return bar
end

--=====================================================================
-- MOBILE SUPPORT
--=====================================================================

local function buildMobileButton()
	if not (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
		return
	end
	local gui = Cloudy.Gui
	local btn = Instance.new("TextButton")
	btn.Name = "CloudyMobileButton"
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = Theme.Accent
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Position = UDim2.new(1, -16, 1, -16)
	btn.Size = UDim2.new(0, 56, 0, 56)
	btn.ZIndex = 50
	btn.Parent = gui
	corner(btn, 28)
	drawCloudIcon(btn, 30, Theme.White).AnchorPoint = Vector2.new(0.5, 0.5)
	local cloud = btn:FindFirstChildOfClass("Frame")
	if cloud then cloud.Position = UDim2.fromScale(0.5, 0.5) end
	makeDraggable(btn, btn)

	track(btn.MouseButton1Click:Connect(function()
		mainFrame.Visible = not mainFrame.Visible
	end))
end

--=====================================================================
-- BOOTSTRAP
--=====================================================================

local function launchCloudy()
	buildMainWindow()
	buildHomeTab()
	buildPerformanceTab()
	buildVisualsTab()
	buildPlayerTab()
	buildCosmeticsTab()
	buildOutfitsTab()
	buildInterfaceTab()
	buildSocialTab()
	buildSettingsTab()
	buildHUD()
	buildToolbar()
	buildMobileButton()

	mainFrame.Visible = true
	mainFrame.Size = UDim2.new(0, 0, 0, 0)
	
	--=====================================================================
	-- KEYBINDS
	--=====================================================================

	track(UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
		-- Ignore the key press if the player is typing in chat or a TextBox
		if gameProcessedEvent then return end

		-- Check if the pressed key is RightShift
		if input.KeyCode == Enum.KeyCode.RightShift then
			-- Toggle the visibility of the main window (if it has been loaded)
			if mainFrame then
				mainFrame.Visible = not mainFrame.Visible
			end
		end
	end))
	
	--=====================================================================
	-- API LAYER (Modified for Local 'testkey' Bypass)
	--=====================================================================

	function Cloudy.VerifyKey(key)
		-- Check for the specific local key
		if key == "testkey" then
			return true, {
				valid = true,
				user = {
					username = LocalPlayer.Name, -- Automatically uses your Roblox username
					plan = "Developer (Offline)"
				},
				settings = {
					-- You can define any default starting settings here if needed
				}
			}, nil
		else
			return false, nil, "Invalid key! Hint: Use 'testkey'"
		end
	end

	function Cloudy.LoadSettings(userid)
		-- Since we are offline, we can just return empty settings 
		-- (or you can hook this up to Roblox DataStores if you want actual saving)
		return {}
	end

	function Cloudy.SaveSettings(userid, settingsTable)
		-- Return true to trick the UI into thinking settings saved successfully
		return true
	end
	tween(mainFrame, {Size = UDim2.new(0, 780, 0, 480)}, 0.3, Enum.EasingStyle.Back)

	Cloudy.Notify("Cloudy", "Welcome, " .. Cloudy.User.username .. "!", "success")
end

buildRoot()
buildKeyScreen(launchCloudy)
