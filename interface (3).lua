-- interface.lua | Lua / Roblox Luau | revision 5
-- Single-file client. All rendering uses Roblox GUI instances; no Drawing API.
local Settings = {
    Runtime = {
        Name = "XC VIP", Version = "5.5", File = "xcvip_settings_v5.json",
        GuiName = "ClientInterface", ErrorGuiName = "ClientInterface_StartupError", RenderName = "ClientInterface_Render_v5",
        ReadyTimeout = 30, ScanInterval = 0.2, StatusInterval = 0.3,
        DiscoveryBatch = 400, RayPasses = 16, NearPlane = 0.05,
        FadeTime = 0.18, MotionTime = 0.22, DragThreshold = 5,
        Width = 500, Height = 312.5, Margin = 12, Header = 58, Rail = 50, Strip = 28,
        Row = 30, Gap = 5, MaxBlacklist = 500, MaxName = 100,
        MaxConfigBytes = 131072, VisibilityThreshold = 0.95,
        MaxDelta = 0.1, SmoothRate = 60, MarkerSize = 8, BallFolder = "Balls",
    },
    ESP = {
        Enabled = true, EnemyOnly = true, VisibleCheck = false,
        Bots = true, BotTeamCheck = true, MaxDistance = 1000,
        CornerBoxes = false, FilledBox = false, FillOpacity = 0.18,
        Chams = false, ChamsFill = 0.55, TargetMarker = true, YOffset = 0,
    },
    Box = { Enabled = true, Color = Color3.fromRGB(0,210,255),
        VisColor = Color3.fromRGB(80,255,140), Thickness = 1.4 },
    Name = { Enabled = true, Color = Color3.fromRGB(240,240,255), Size = 13 },
    Health = { Enabled = true },
    Distance = { Enabled = true, Color = Color3.fromRGB(160,170,200) },
    Tracer = { Enabled = false, Color = Color3.fromRGB(0,210,255), Thickness = 1.2 },
    Skeleton = { Enabled = false, Color = Color3.fromRGB(210,215,255), Thickness = 1.1 },
    Aimbot = {
        Enabled = false, EnemyOnly = true, IgnoreTeammates = true,
        WallCheck = true, ShowFOV = true, FOV = 140, Smoothing = 0.22,
        MaxDistance = 500, BodyFallback = true, Bots = true, HoldToAim = true,
        AimPart = "Head", Priority = "Closest", Prediction = 0.12,
        Origin = "Cursor", Stickiness = 0.6,
    },
    Ball = {Enabled=false,ShowMarker=true,LeadTime=0.18,Radius=4,MinInterval=0.35,CurveDot=0.85,Key="F"},
    Misc = {
        Blacklist = {}, BlacklistESP = true, BlacklistAim = true,
        FpsHud = true, HotkeyESP = "F1", HotkeyAim = "F2",
        ReducedMotion = false, Accent = Color3.fromRGB(255,35,190),
    },
}
local R = Settings.Runtime
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local Defaults = copy(Settings)
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function vector(v) return typeof(v) == "Vector3" and finite(v.X) and finite(v.Y) and finite(v.Z) end
local function instance(v, class) return typeof(v) == "Instance" and (not class or v:IsA(class)) end
local function within(v, parent) return instance(v) and instance(parent) and v:IsDescendantOf(parent) end
local function destroy(v) if v then pcall(function() v:Destroy() end) end end
local function trim(v) return (v:match("^%s*(.-)%s*$")) end
-- No copied remotes: the adapter requests the configured normal parry key.
local function newBallAdapter(context)
    local adapter={status="disabled",ball=nil,point=nil,tti=nil,sent=false,lastTarget=nil,lastRequest=-math.huge}
    local previousPosition,previousTime,previousVelocity
    local inputService
    function adapter.Predict(relativePosition,relativeVelocity,radius)
        if not vector(relativePosition) or not vector(relativeVelocity) or not finite(radius) or radius<=0 then return nil end
        local a=relativeVelocity:Dot(relativeVelocity)
        local b=2*relativePosition:Dot(relativeVelocity)
        local c=relativePosition:Dot(relativePosition)-radius*radius
        if c<=0 then return 0 end
        if a<=1e-8 or b>=0 then return nil end
        local discriminant=b*b-4*a*c
        if discriminant<0 then return nil end
        -- Stable smaller root avoids subtracting nearly equal positive values.
        local denominator=-b+math.sqrt(discriminant)
        if denominator<=1e-8 then return nil end
        local time=2*c/denominator
        return finite(time) and time>=0 and time or nil
    end
    function adapter.Stop(reason)
        adapter.ball,adapter.point,adapter.tti=nil,nil,nil
        adapter.lastTarget,adapter.sent=nil,false
        adapter.inputError=nil
        previousPosition,previousTime,previousVelocity=nil,nil,nil
        adapter.status=reason or "disabled"
    end
    local function requestKey()
        if not inputService then
            local ok,value=pcall(function() return game:GetService("VirtualInputManager") end)
            if not ok then return false,"normal key input unavailable" end
            inputService=value
        end
        local key=Enum.KeyCode[context.settings.Key]
        local downOK,downError=pcall(function() inputService:SendKeyEvent(true,key,false,game) end)
        local upOK,upError=pcall(function() inputService:SendKeyEvent(false,key,false,game) end)
        if not downOK or not upOK then return false,tostring(downError or upError) end
        return true
    end
    function adapter.Step(now)
        local config=context.settings
        local player=context.player
        if not context.active() then adapter.Stop("inactive profile"); return end
        if not context.focused() or context.typing() then adapter.Stop("paused: focus / typing"); return end
        local character=player.Character
        local root=instance(character,"Model") and character:FindFirstChild("HumanoidRootPart")
        local humanoid=instance(character,"Model") and character:FindFirstChildOfClass("Humanoid")
        if not instance(root,"BasePart") or not humanoid or humanoid.Health<=0 then adapter.Stop("waiting for living character"); return end
        local folder=workspace:FindFirstChild(context.folder)
        if not folder then adapter.Stop("ball folder unavailable"); return end
        local chosen
        for _,candidate in ipairs(folder:GetChildren()) do
            if instance(candidate,"BasePart") and candidate:GetAttribute("realBall")==true then
                if chosen then adapter.Stop("multiple live balls: unresolved"); return end
                chosen=candidate
            end
        end
        if not chosen or not vector(chosen.Position) then adapter.Stop("waiting for attributed live ball"); return end
        if chosen~=adapter.ball then adapter.Stop("tracking new ball"); adapter.ball=chosen end
        adapter.point=chosen.Position
        local target=chosen:GetAttribute("target")
        if target~=adapter.lastTarget then adapter.sent=false; adapter.lastTarget=target end
        local targeted=target==player.Name or finite(player.UserId) and (target==player.UserId or target==tostring(player.UserId))
        local velocity=chosen.AssemblyLinearVelocity
        local dt=previousTime and now-previousTime
        if not vector(velocity) then velocity=Vector3.new() end
        if previousPosition and dt and dt>0.001 and dt<0.25 then
            local difference=chosen.Position-previousPosition
            if difference.Magnitude>250 then adapter.Stop("teleport / stale sample"); return end
            if velocity.Magnitude<0.01 and difference.Magnitude>0.001 then velocity=difference/dt end
        end
        local turning=previousVelocity and previousVelocity.Magnitude>0.1 and velocity.Magnitude>0.1
            and previousVelocity.Unit:Dot(velocity.Unit)<config.CurveDot
        previousPosition,previousTime,previousVelocity=chosen.Position,now,velocity
        local playerVelocity=vector(root.AssemblyLinearVelocity) and root.AssemblyLinearVelocity or Vector3.new()
        local relativePosition=chosen.Position-root.Position
        local relativeVelocity=velocity-playerVelocity
        adapter.tti=adapter.Predict(relativePosition,relativeVelocity,config.Radius)
        if relativePosition:Dot(relativeVelocity)>=0 then adapter.tti=nil end
        if target==nil then adapter.status="target attribute unavailable"; return end
        if not targeted then adapter.status="tracking: another target"; return end
        if not config.Enabled then adapter.status=adapter.inputError and ("input unavailable: "..adapter.inputError) or "targeted: auto parry OFF"; return end
        adapter.inputError=nil
        if context.menuOpen() then adapter.status="minimize menu to arm"; return end
        if adapter.sent then adapter.status="request sent; waiting for target change (unconfirmed)"; return end
        if turning then adapter.status="trajectory changed: resampling"; return end
        if not adapter.tti then adapter.status="not on an incoming intercept"; return end
        if adapter.tti>config.LeadTime then adapter.status=string.format("incoming: %.3fs",adapter.tti); return end
        if now-adapter.lastRequest<config.MinInterval then adapter.status="request interval"; return end
        adapter.lastRequest=now
        local ok,err=requestKey()
        if ok then adapter.sent=true; adapter.status="parry key requested (unconfirmed)"
        else
            config.Enabled=false
            adapter.inputError=tostring(err)
            adapter.status="input unavailable: "..adapter.inputError
            context.inputFailed()
        end
    end
    return adapter
end

local env = _G
if type(getgenv) == "function" then
    local ok, value = pcall(getgenv)
    if ok and type(value) == "table" then env = value end
end
local old = {}
for _, key in ipairs({"XCVIP_Unload", "DeltaESP_Unload"}) do
    local fn = env[key]
    if type(fn) == "function" and not old[fn] then old[fn] = true; pcall(fn) end
end
local State = {
    running = true, focused = true, aiming = false, touchAim = false,
    connections = {}, tweens = {}, tasks = {}, visuals = {}, bots = {},
    targets = {}, warnings = {}, widgets = {}, pages = {}, tabs = {},
    phase = "bootstrap", profile = nil, current = nil, remainder = Vector2.new(), frames = 0, elapsed = 0,
    fps = 0, scanElapsed = 0, statusElapsed = 0, stats = {}, debug = "idle",
}
local Services = {}
local GUI, Overlay, Main, Canvas, UIS, Players, LocalPlayer, RunService, TweenService, HttpService
local unload
local function warning(key, message)
    if State.warnings[key] then return end
    State.warnings[key] = true
    if type(warn) == "function" then pcall(warn,"[" .. R.Name .. "] " .. tostring(message)) end
end
local function guarded(key, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warning(key, err) end
    return ok
end
local function disconnect(connection)
    if not connection then return end
    State.connections[connection] = nil
    pcall(function() connection:Disconnect() end)
end
local function connect(signal, callback)
    local connection = signal:Connect(function(...)
        if State.running then guarded(tostring(callback), callback, ...) end
    end)
    State.connections[connection] = true
    return connection
end
local function cancelTweens(object)
    local active = State.tweens[object]
    if not active then return end
    State.tweens[object] = nil
    for tween, connection in pairs(active) do
        disconnect(connection)
        pcall(function() tween:Cancel() end)
    end
end
local function animate(object, properties, duration)
    cancelTweens(object)
    if Settings.Misc.ReducedMotion then
        for key, value in pairs(properties) do object[key] = value end
        return
    end
    local tween = TweenService:Create(object, TweenInfo.new(duration or R.MotionTime,
        Enum.EasingStyle.Quint, Enum.EasingDirection.Out), properties)
    local active = {}
    State.tweens[object] = active
    local connection
    connection = connect(tween.Completed, function()
        active[tween] = nil
        if State.tweens[object] == active then State.tweens[object] = nil end
        disconnect(connection)
    end)
    active[tween] = connection
    tween:Play()
end
local function spawnTask(fn)
    local thread
    thread = coroutine.create(function()
        guarded("worker", fn)
        State.tasks[coroutine.running()] = nil
    end)
    State.tasks[thread] = true
    task.spawn(thread)
end
unload = function()
    if not State.running then return end
    State.running = false
    State.current, State.aiming, State.touchAim = nil, false, false
    for connection in pairs(State.connections) do disconnect(connection) end
    for object in pairs(State.tweens) do cancelTweens(object) end
    for thread in pairs(State.tasks) do
        if thread ~= coroutine.running() then pcall(task.cancel, thread) end
    end
    if RunService then pcall(function() RunService:UnbindFromRenderStep(R.RenderName) end) end
    for _, visual in pairs(State.visuals) do destroy(visual.highlight) end
    if State.ball then State.ball.Stop("unloaded") end
    destroy(GUI)
    for _, key in ipairs({"XCVIP_Unload", "DeltaESP_Unload"}) do
        if env[key] == unload then env[key] = nil end
    end
    State.visuals, State.bots, State.targets, State.tasks = {}, {}, {}, {}
    State.widgets, State.pages, State.tabs = {}, {}, {}
    GUI, Overlay, Main, Canvas = nil, nil, nil, nil
end
env.XCVIP_Unload, env.DeltaESP_Unload = unload, unload
local function resetAim(reason)
    State.current, State.remainder, State.debug = nil, Vector2.new(), reason or "idle"
end
-- A plain diagnostic survives failed initialization; the next run removes it.
local function startupFailure(message)
    local detail="Startup failed ["..State.phase.."]: "..tostring(message)
    env.XCVIP_LastError=detail
    warning("initialize",detail)
    unload()
    pcall(function()
        local players=game:GetService("Players")
        local player=players.LocalPlayer
        local holder=player and player:FindFirstChildOfClass("PlayerGui")
        if not holder then return end
        destroy(holder:FindFirstChild(R.ErrorGuiName))
        local diagnostic=Instance.new("ScreenGui")
        diagnostic.Name=R.ErrorGuiName
        diagnostic.ResetOnSpawn=false
        diagnostic.IgnoreGuiInset=true
        diagnostic.DisplayOrder=1000
        local text=Instance.new("TextLabel")
        text.Size=UDim2.new(1,-24,0,150)
        text.Position=UDim2.fromOffset(12,12)
        text.BackgroundColor3=Color3.fromRGB(35,12,22)
        text.TextColor3=Color3.new(1,1,1)
        text.TextSize=14
        text.TextWrapped=true
        text.Text=R.Name.." "..R.Version.."\n"..detail.."\nCopy this error from the console or getgenv().XCVIP_LastError."
        text.Parent=diagnostic
        diagnostic.Parent=holder
    end)
end
local function initialize()
    State.phase="services"
    for _, name in ipairs({"Players", "RunService", "UserInputService", "TweenService", "HttpService"}) do
        Services[name] = game:GetService(name)
    end
    Players, RunService, UIS = Services.Players, Services.RunService, Services.UserInputService
    TweenService, HttpService = Services.TweenService, Services.HttpService
    State.phase="waiting for player"
    local deadline = os.clock() + R.ReadyTimeout
    repeat
        LocalPlayer = Players.LocalPlayer
        if game:IsLoaded() and LocalPlayer then break end
        if not State.running then return end
        assert(os.clock() < deadline, "Timed out waiting for game / LocalPlayer")
        task.wait()
    until false

    -- UI uses a fixed logical canvas with UIScale, including short viewports.
    local function make(class, parent, props)
        local object = Instance.new(class)
        for key, value in pairs(props or {}) do object[key] = value end
        object.Parent = parent
        return object
    end
    local function round(object, radius)
        local corner=object:FindFirstChildOfClass("UICorner") or make("UICorner",object,{})
        corner.CornerRadius=typeof(radius)=="UDim" and radius or UDim.new(0,radius)
        return corner
    end
    local function stroke(object, color, thickness)
        return make("UIStroke", object, {Color = color, Thickness = thickness or 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border})
    end
    GUI = make("ScreenGui", nil, {Name = R.GuiName, ResetOnSpawn = false,
        IgnoreGuiInset = true, DisplayOrder = 999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling})
    connect(GUI.Destroying, unload)
    State.phase="GUI parenting"
    local playerGui=LocalPlayer:FindFirstChildOfClass("PlayerGui")
        or LocalPlayer:WaitForChild("PlayerGui",R.ReadyTimeout)
    if playerGui then destroy(playerGui:FindFirstChild(R.ErrorGuiName)) end
    local function tryParent(holder)
        if not instance(holder) then return false end
        local ok=pcall(function() GUI.Parent=holder end)
        return ok and GUI.Parent==holder
    end
    -- Prefer the normal visible client hierarchy on desktop and mobile.
    local parented=tryParent(playerGui)
    if not parented and type(gethui)=="function" then
        local ok,holder=pcall(gethui)
        if ok then parented=tryParent(holder) end
    end
    if not parented then
        local ok,holder=pcall(function() return game:GetService("CoreGui") end)
        if ok then parented=tryParent(holder) end
    end
    assert(parented,"No writable GUI parent")
    GUI.Enabled=true
    State.phase="menu creation"
    Overlay = make("Frame", GUI, {Name = "Overlay", Size = UDim2.fromScale(1,1),
        BackgroundTransparency = 1, Active = false, ZIndex = 1})
    local function viewport()
        local camera = workspace.CurrentCamera
        local size = camera and camera.ViewportSize
        return size and size.X > 0 and size.Y > 0 and size or Vector2.new(R.Width, R.Height)
    end
    local function frame(parent, props)
        props = props or {}; props.BorderSizePixel = 0
        return make("Frame", parent, props)
    end
    local function label(parent, text, props)
        props = props or {}
        props.Text, props.BackgroundTransparency = text, 1
        props.TextColor3 = props.TextColor3 or Color3.fromRGB(240,236,250)
        props.TextSize = props.TextSize or 12
        props.Font = props.Font or Enum.Font.GothamMedium
        props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
        return make("TextLabel", parent, props)
    end
    local palette = {background = Color3.fromRGB(10,4,14), row = Color3.fromRGB(24,9,29),
        hover = Color3.fromRGB(43,14,46), muted = Color3.fromRGB(190,152,188)}
    local themeEntries = setmetatable({}, {__mode = "k"})
    local function themed(object, property)
        themeEntries[object] = property
        object[property] = Settings.Misc.Accent
        return object
    end
    local function button(parent, text, props)
        props = props or {}; props.Text = text
        props.BackgroundColor3 = palette.row; props.BorderSizePixel = 0
        props.TextColor3 = Color3.fromRGB(245,239,255); props.Font = Enum.Font.GothamSemibold
        props.TextSize = props.TextSize or 11; props.AutoButtonColor = false
        local object = make("TextButton", parent, props)
        round(object, 8)
        connect(object.MouseEnter, function()
            local selected=object:GetAttribute("Selected")==true
            animate(object,{BackgroundColor3=selected and Settings.Misc.Accent or palette.hover})
        end)
        connect(object.MouseLeave, function()
            local selected=object:GetAttribute("Selected")==true
            animate(object,{BackgroundColor3=selected and Settings.Misc.Accent or palette.row})
        end)
        return object
    end
    Main = frame(GUI, {Name = "Window", AnchorPoint = Vector2.new(0.5,0.5),
        Position = UDim2.fromScale(0.5,0.5), BackgroundTransparency = 1, ZIndex = 5})
    local halo=themed(frame(Main,{Name="NeonHalo",Position=UDim2.fromOffset(-7,-7),
        Size=UDim2.new(1,14,1,14),BackgroundTransparency=0.86}),"BackgroundColor3")
    round(halo,18)
    local haloStroke=themed(stroke(halo,Settings.Misc.Accent,2),"Color")
    Canvas = make("Frame", Main, {Size = UDim2.fromOffset(R.Width,R.Height),
        BackgroundColor3 = palette.background, BorderSizePixel = 0,
        ClipsDescendants = true})
    round(Canvas,14)
    local backdrop=make("UIGradient",Canvas,{Rotation=22})
    local outline = themed(stroke(Canvas,Settings.Misc.Accent,1.5), "Color")
    local scale = make("UIScale", Canvas, {})
    local header = frame(Canvas, {Size = UDim2.new(1,0,0,R.Header),
        BackgroundColor3 = Color3.fromRGB(18,6,21), Active = true})
    local headerEdge=themed(stroke(header,Settings.Misc.Accent,1),"Color")
    headerEdge.Transparency=0.72
    local accentLine = themed(frame(header,{Position=UDim2.new(0,0,1,-2),
        Size=UDim2.new(1,0,0,2)}),"BackgroundColor3")
    make("UIGradient",accentLine,{Transparency=NumberSequence.new({
        NumberSequenceKeypoint.new(0,0.6),NumberSequenceKeypoint.new(0.5,0),NumberSequenceKeypoint.new(1,0.6)})})
    local emblem=frame(header,{Name="Emblem",Position=UDim2.fromOffset(12,9),
        Size=UDim2.fromOffset(40,40),BackgroundColor3=palette.row})
    round(emblem,20); themed(stroke(emblem,Settings.Misc.Accent,2),"Color")
    local ring=frame(emblem,{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),
        Size=UDim2.fromOffset(22,22),BackgroundTransparency=1})
    round(ring,11); themed(stroke(ring,Settings.Misc.Accent,1.6),"Color")
    local core=themed(frame(emblem,{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),
        Size=UDim2.fromOffset(8,8)}),"BackgroundColor3"); round(core,4)
    for _,angle in ipairs({0,90,180,270}) do
        local radians=math.rad(angle)
        local dot=themed(frame(emblem,{AnchorPoint=Vector2.new(0.5,0.5),Size=UDim2.fromOffset(3,3),
            Position=UDim2.fromScale(0.5+math.cos(radians)*0.34,0.5+math.sin(radians)*0.34)}),"BackgroundColor3")
        round(dot,2)
    end
    local heading=label(header,R.Name .. "  -  CHOOSE GAME",{Position=UDim2.fromOffset(62,7),
        Size=UDim2.new(1,-136,0,26),TextSize=17,Font=Enum.Font.GothamBold,TextTruncate=Enum.TextTruncate.AtEnd})
    label(header,"NEON INTERFACE  -  v"..R.Version,{Position=UDim2.fromOffset(63,30),
        Size=UDim2.new(1,-136,0,18),TextSize=10,TextColor3=palette.muted,TextTruncate=Enum.TextTruncate.AtEnd})
    local minimize=button(header,"_",{Position=UDim2.new(1,-70,0,15),Size=UDim2.fromOffset(24,25)})
    local close=button(header,"x",{Position=UDim2.new(1,-38,0,15),Size=UDim2.fromOffset(24,25)})
    local rail=make("ScrollingFrame",Canvas,{Name="Rail",Position=UDim2.fromOffset(0,R.Header),
        Size=UDim2.new(0,R.Rail,1,-R.Header),BackgroundColor3=Color3.fromRGB(9,3,12),
        BorderSizePixel=0,ScrollBarThickness=0,CanvasSize=UDim2.fromOffset(0,204),
        ScrollingDirection=Enum.ScrollingDirection.Y})
    local tabs=frame(Canvas,{Name="Strip",Position=UDim2.fromOffset(R.Rail+8,R.Header+8),
        Size=UDim2.new(1,-(R.Rail+18),0,R.Strip),BackgroundTransparency=1})
    local body=frame(Canvas,{Name="Body",Position=UDim2.fromOffset(R.Rail+8,R.Header+R.Strip+14),
        Size=UDim2.new(1,-(R.Rail+18),1,-(R.Header+R.Strip+48)),BackgroundTransparency=1,ClipsDescendants=true})
    local footer=label(Canvas,"READY",{Position=UDim2.new(0,R.Rail+18,1,-27),
        Size=UDim2.new(1,-(R.Rail+120),0,20),TextSize=9,TextColor3=palette.muted})
    local unloadButton=button(Canvas,"UNLOAD",{Position=UDim2.new(1,-92,1,-29),Size=UDim2.fromOffset(76,22)})
    connect(unloadButton.Activated,unload)
    local fab=button(GUI,"XC",{AnchorPoint=Vector2.new(1,1),Position=UDim2.new(1,-16,1,-20),
        Size=UDim2.fromOffset(46,46),ZIndex=10,TextSize=15})
    fab.Name="FloatingXC"
    round(fab,UDim.new(1,0))
    local fabBorder=themed(stroke(fab,Settings.Misc.Accent,2),"Color")
    local fabHalo=themed(frame(fab,{Name="CircleGlow",AnchorPoint=Vector2.new(0.5,0.5),
        Position=UDim2.fromScale(0.5,0.5),Size=UDim2.new(1,12,1,12),BackgroundTransparency=0.92,ZIndex=9}),"BackgroundColor3")
    round(fabHalo,UDim.new(1,0))
    local fabRing=themed(stroke(fabHalo,Settings.Misc.Accent,1),"Color"); fabRing.Transparency=0.65
    local fabScale=make("UIScale",fab,{Scale=1})
    connect(fab.InputBegan,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            animate(fabScale,{Scale=0.92},R.FadeTime)
        end
    end)
    connect(UIS.InputEnded,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch then
            animate(fabScale,{Scale=1},R.FadeTime)
        end
    end)
    connect(UIS.WindowFocusReleased,function() cancelTweens(fabScale); fabScale.Scale=1 end)
    local touch=button(GUI,"HOLD AIM",{AnchorPoint=Vector2.new(1,1),Position=UDim2.new(1,-74,1,-20),
        Size=UDim2.fromOffset(92,46),ZIndex=10,Visible=false})
    local touchInput
    local function syncTouch()
        touch.Visible=State.profile~=nil and State.profile.id=="universal" and UIS.TouchEnabled and Settings.Aimbot.Enabled and Settings.Aimbot.HoldToAim
        if not touch.Visible then State.touchAim=false; touchInput=nil end
    end
    local toast=label(GUI,"",{AnchorPoint=Vector2.new(0.5,1),Position=UDim2.new(0.5,0,1,-18),
        Size=UDim2.fromOffset(300,32),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=20,
        BackgroundColor3=palette.row,Visible=false})
    toast.BackgroundTransparency=0.08; round(toast,10)
    local toastUntil=0
    local function notify(message)
        toast.Text=tostring(message); toast.Visible=true; toastUntil=os.clock()+2
    end
    local railButtons={}
    local refreshProfileUI
    local refreshRoster
    local currentPage="ESP"
    local function refreshTheme()
        local accent=Settings.Misc.Accent
        local tint=Color3.new(accent.R,accent.G,accent.B)
        Canvas.BackgroundColor3=Color3.new(1,1,1)
        backdrop.Color=ColorSequence.new(palette.background,tint:Lerp(palette.background,0.86))
        for object,property in pairs(themeEntries) do
            if object.Parent then object[property]=Settings.Misc.Accent end
        end
        for name,object in pairs(State.tabs) do
            cancelTweens(object)
            object:SetAttribute("Selected",name==currentPage)
            object.BackgroundColor3=name==currentPage and Settings.Misc.Accent or palette.row
            object.TextColor3=name==currentPage and Color3.new(1,1,1) or palette.muted
            local railButton=railButtons[name]
            if railButton then
                railButton:SetAttribute("Selected",name==currentPage)
                railButton.BackgroundTransparency=name==currentPage and 0.78 or 1
            end
        end
    end
    local function refreshWidgets()
        for _,refresh in ipairs(State.widgets) do refresh(false) end
        refreshTheme()
        syncTouch()
    end
    local function panel(visible)
        Main.Visible=visible
        if visible then
            Canvas.BackgroundTransparency=Settings.Misc.ReducedMotion and 0 or 0.35
            animate(Canvas,{BackgroundTransparency=0})
        else
            cancelTweens(Canvas)
        end
    end
    connect(minimize.Activated,function() panel(false) end)
    connect(close.Activated,function() panel(false) end)
    local order={}
    local function selectPage(name)
        currentPage=name
        if name=="Blacklist" and refreshRoster then refreshRoster() end
        for pageName,page in pairs(State.pages) do
            cancelTweens(page)
            page.Visible=pageName==name
            if page.Visible then
                page.Position=UDim2.fromOffset(Settings.Misc.ReducedMotion and 0 or 16,0)
                animate(page,{Position=UDim2.new()})
            end
        end
        refreshTheme()
    end
    local pageNames={"ESP","Aim","Extras","Blacklist","Status"}
    for index,name in ipairs(pageNames) do
        local pageName=name
        local railButton=button(rail,"",{Name=name.."Rail",Position=UDim2.fromOffset(10,12+(index-1)*38),
            Size=UDim2.fromOffset(30,30),BackgroundTransparency=1})
        railButtons[name]=railButton
        themed(stroke(railButton,Settings.Misc.Accent,1),"Color")
        local function shape(w,h,r,filled)
            local object=frame(railButton,{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),
                Size=UDim2.fromOffset(w,h),BackgroundTransparency=filled and 0 or 1})
            round(object,r)
            if filled then themed(object,"BackgroundColor3") else themed(stroke(object,Settings.Misc.Accent,1.4),"Color") end
            return object
        end
        if name=="ESP" then shape(14,14,3,false); shape(5,5,3,true)
        elseif name=="Aim" then shape(14,14,7,false); shape(4,4,2,true)
        elseif name=="Extras" then shape(12,12,2,false).Rotation=45
        elseif name=="Blacklist" then shape(14,14,7,false); shape(15,2,1,true).Rotation=45
        else
            for i,h in ipairs({6,10,14}) do
                local bar=shape(3,h,1,true); bar.AnchorPoint=Vector2.new(0,0)
                bar.Position=UDim2.fromOffset(7+(i-1)*5,22-h)
            end
        end
        connect(railButton.Activated,function() selectPage(pageName) end)
        local tab=button(tabs,name:upper(),{Position=UDim2.new((index-1)/#pageNames,0,0,0),
            Size=UDim2.new(1/#pageNames,-5,1,0)})
        local tabBorder=themed(stroke(tab,Settings.Misc.Accent,1),"Color"); tabBorder.Transparency=0.42
        round(tab,8)
        State.tabs[name]=tab
        connect(tab.Activated,function() selectPage(pageName) end)
        local page=make("ScrollingFrame",body,{Name=name,Size=UDim2.fromScale(1,1),
            BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,
            AutomaticCanvasSize=Enum.AutomaticSize.Y,CanvasSize=UDim2.new(),Visible=false,
            ScrollingDirection=Enum.ScrollingDirection.Y})
        themed(page,"ScrollBarImageColor3")
        make("UIPadding",page,{PaddingRight=UDim.new(0,8),PaddingBottom=UDim.new(0,8)})
        make("UIListLayout",page,{Padding=UDim.new(0,R.Gap),SortOrder=Enum.SortOrder.LayoutOrder})
        State.pages[name]=page; order[page]=0
    end
    local function row(page,height)
        order[page]=(order[page] or 0)+1
        local object=frame(page,{Size=UDim2.new(1,-2,0,height or R.Row),
            BackgroundColor3=palette.row,LayoutOrder=order[page]})
        round(object,9)
        local border=themed(stroke(object,Settings.Misc.Accent,1),"Color"); border.Transparency=0.65
        return object
    end
    local function section(page,text)
        local object=row(page,24); object.BackgroundTransparency=1
        themed(label(object,text:upper(),{Size=UDim2.fromScale(1,1),TextSize=10,
            Font=Enum.Font.GothamBold}),"TextColor3")
    end
    local function changed(sectionName,key,value)
        Settings[sectionName][key]=value
        syncTouch()
        if sectionName=="Aimbot" or sectionName=="Misc" and key:find("Blacklist") then resetAim() end
    end
    local function toggle(page,title,sectionName,key)
        local object=row(page)
        label(object,title,{Position=UDim2.fromOffset(50,0),Size=UDim2.new(1,-62,1,0),TextSize=11})
        local hit=button(object,"",{Position=UDim2.new(0,9,0.5,-9),Size=UDim2.fromOffset(32,18)})
        round(hit,UDim.new(1,0))
        local knob=frame(hit,{Size=UDim2.fromOffset(14,14),AnchorPoint=Vector2.new(0.5,0.5),
            BackgroundColor3=Color3.new(1,1,1)})
        round(knob,UDim.new(1,0))
        local function paint(motion)
            local value=Settings[sectionName][key]
            local properties={Position=value and UDim2.new(1,-10,0.5,0) or UDim2.new(0,10,0.5,0)}
            cancelTweens(hit)
            hit.BackgroundColor3=value and Settings.Misc.Accent or Color3.fromRGB(69,60,83)
            if motion then animate(knob,properties) else cancelTweens(knob); knob.Position=properties.Position end
        end
        connect(hit.Activated,function() changed(sectionName,key,not Settings[sectionName][key]); paint(true) end)
        State.widgets[#State.widgets+1]=paint; paint(false)
    end
    -- One shared pointer router for all sliders and draggable controls.
    local pointer
    local function stopPointer() pointer=nil end
    connect(UIS.InputChanged,function(input)
        if not pointer then return end
        if not Main.Visible and pointer.panel then stopPointer(); return end
        if pointer.input.UserInputType==Enum.UserInputType.Touch and input==pointer.input
            or pointer.input.UserInputType==Enum.UserInputType.MouseButton1
                and input.UserInputType==Enum.UserInputType.MouseMovement then
            pointer.move(input.Position)
        end
    end)
    connect(UIS.InputEnded,function(input)
        if not pointer then return end
        if input==pointer.input or pointer.input.UserInputType==Enum.UserInputType.MouseButton1
            and input.UserInputType==Enum.UserInputType.MouseButton1 then stopPointer() end
    end)
    local function press(input)
        return input.UserInputType==Enum.UserInputType.MouseButton1 or input.UserInputType==Enum.UserInputType.Touch
    end
    local function slider(page,title,sectionName,key,low,high,step,format)
        local object=row(page,52)
        label(object,title,{Position=UDim2.fromOffset(12,1),Size=UDim2.new(0.65,0,0,25)})
        local valueLabel=themed(label(object,"",{Position=UDim2.new(0.65,0,0,1),
            Size=UDim2.new(0.35,-12,0,25),TextXAlignment=Enum.TextXAlignment.Right}),"TextColor3")
        local rail=frame(object,{Position=UDim2.new(0,14,0,36),Size=UDim2.new(1,-28,0,4),
            BackgroundColor3=Color3.fromRGB(69,60,83)})
        round(rail,2)
        local fill=themed(frame(rail,{Size=UDim2.fromScale(0,1)}),"BackgroundColor3"); round(fill,2)
        local knob=frame(rail,{Size=UDim2.fromOffset(12,12),AnchorPoint=Vector2.new(0.5,0.5),
            BackgroundColor3=Color3.new(1,1,1)}); round(knob,6)
        local function paint()
            local value=Settings[sectionName][key]
            local ratio=math.clamp((value-low)/(high-low),0,1)
            fill.Size=UDim2.fromScale(ratio,1); knob.Position=UDim2.fromScale(ratio,0.5)
            valueLabel.Text=string.format(format,value)
        end
        local function move(position)
            if not page.Visible then stopPointer(); return end
            local ratio=math.clamp((position.X-rail.AbsolutePosition.X)/math.max(rail.AbsoluteSize.X,1),0,1)
            local value=math.clamp(low+math.floor((high-low)*ratio/step+0.5)*step,low,high)
            changed(sectionName,key,tonumber(string.format("%.8f",value))); paint()
        end
        local hit=make("TextButton",object,{Position=UDim2.new(0,5,0,25),Size=UDim2.new(1,-10,0,27),
            BackgroundTransparency=1,Text="",AutoButtonColor=false})
        connect(hit.InputBegan,function(input)
            if press(input) and not pointer then pointer={input=input,move=move,panel=true}; move(input.Position) end
        end)
        State.widgets[#State.widgets+1]=paint; paint()
    end
    local function cycle(page,title,sectionName,key,options)
        local object=row(page)
        label(object,title,{Position=UDim2.fromOffset(12,0),Size=UDim2.new(0.48,0,1,0)})
        local hit=button(object,"",{Position=UDim2.new(0.5,0,0,5),Size=UDim2.new(0.5,-10,1,-10)})
        local function paint() hit.Text=tostring(Settings[sectionName][key]) end
        connect(hit.Activated,function()
            local index=1
            for i,value in ipairs(options) do if value==Settings[sectionName][key] then index=i%#options+1; break end end
            changed(sectionName,key,options[index]); paint()
        end)
        State.widgets[#State.widgets+1]=paint; paint()
    end
    local function action(page,title,fn)
        local object=row(page)
        local hit=button(object,title,{Position=UDim2.fromOffset(4,3),Size=UDim2.new(1,-8,1,-6)})
        connect(hit.Activated,fn)
    end
    -- Only implemented profiles may enter the shared controls.
    local profiles={
        {id="universal",name="Universal",ready=true,description="Aim + ESP for standard player and NPC rigs."},
        {id="blade_ball",name="Blade Ball",ready=true,description="Ball tracking + timed parry-key requests. Requires live game signals."},
    }
    local launcher=make("ScrollingFrame",Canvas,{Name="GameSelector",Position=UDim2.fromOffset(12,R.Header+10),
        Size=UDim2.new(1,-24,1,-(R.Header+48)),BackgroundTransparency=1,BorderSizePixel=0,
        ScrollBarThickness=3,AutomaticCanvasSize=Enum.AutomaticSize.Y,CanvasSize=UDim2.new(),
        ScrollingDirection=Enum.ScrollingDirection.Y})
    themed(launcher,"ScrollBarImageColor3")
    make("UIListLayout",launcher,{Padding=UDim.new(0,R.Gap),SortOrder=Enum.SortOrder.LayoutOrder})
    make("UIPadding",launcher,{PaddingRight=UDim.new(0,6),PaddingBottom=UDim.new(0,4)})
    section(launcher,"Choose a game profile")
    local function selectProfile(profile)
        if not profile.ready then return end
        if State.ball then State.ball.Stop("profile changed") end
        Settings.Ball.Enabled=false
        State.profile=profile
        if refreshProfileUI then refreshProfileUI() end
        State.aiming,State.touchAim=false,false
        touchInput=nil; resetAim()
        launcher.Visible=false; rail.Visible=true; tabs.Visible=true; body.Visible=true; Overlay.Visible=true
        heading.Text=R.Name.."  -  "..profile.name:upper()
        selectPage(currentPage); syncTouch()
        notify(profile.name.." selected")
    end
    for _,entry in ipairs(profiles) do
        local profile=entry
        local card=row(launcher,68)
        card.Name=profile.id.."Profile"
        label(card,profile.name,{Position=UDim2.fromOffset(12,6),Size=UDim2.new(1,-140,0,24),
            TextSize=14,Font=Enum.Font.GothamBold})
        label(card,profile.description,{Position=UDim2.fromOffset(12,32),Size=UDim2.new(1,-24,0,28),
            TextSize=10,TextWrapped=true,TextColor3=palette.muted})
        local choose=button(card,profile.ready and ("PLAY "..profile.name:upper()) or "NOT CONFIGURED",{
            Name=profile.id.."Select",Position=UDim2.new(1,-132,0,8),Size=UDim2.fromOffset(120,24),TextSize=9})
        if profile.ready then connect(choose.Activated,function() selectProfile(profile) end)
        else choose.Active=false; choose.Selectable=false; choose.TextColor3=palette.muted end
    end
    local function openSelector()
        if State.ball then State.ball.Stop("profile changed") end
        Settings.Ball.Enabled=false
        State.profile=nil; State.aiming,State.touchAim=false,false
        touchInput=nil; resetAim(); syncTouch()
        Overlay.Visible=false
        for _,visual in pairs(State.visuals) do
            visual.group.Visible=false
            if visual.highlight then visual.highlight.Enabled=false end
        end
        rail.Visible=false; tabs.Visible=false; body.Visible=false; launcher.Visible=true
        heading.Text=R.Name.."  -  CHOOSE GAME"; footer.Text="CHOOSE A PROFILE"
        launcher.CanvasPosition=Vector2.new()
    end
    local esp,aim,extra,blacklist,status=State.pages.ESP,State.pages.Aim,State.pages.Extras,State.pages.Blacklist,State.pages.Status
    section(esp,"Visual overlay")
    for _,item in ipairs({{"Enable ESP","ESP","Enabled"},{"Show Boxes","Box","Enabled"},
        {"Corner Boxes","ESP","CornerBoxes"},{"Filled Box","ESP","FilledBox"},
        {"Skeleton","Skeleton","Enabled"},{"Names","Name","Enabled"},{"Health","Health","Enabled"},
        {"Distance","Distance","Enabled"},{"Tracers","Tracer","Enabled"},{"Chams","ESP","Chams"},
        {"Target Marker","ESP","TargetMarker"},{"Enemies Only","ESP","EnemyOnly"},
        {"NPCs","ESP","Bots"},{"NPC Team Check","ESP","BotTeamCheck"},{"Visible Only","ESP","VisibleCheck"}}) do
        toggle(esp,item[1],item[2],item[3])
    end
    slider(esp,"Maximum Distance","ESP","MaxDistance",100,3000,50,"%.0f studs")
    slider(esp,"Fill Opacity","ESP","FillOpacity",0.05,0.5,0.05,"%.2f")
    slider(esp,"Highlight Transparency","ESP","ChamsFill",0,0.95,0.05,"%.2f")
    slider(esp,"Vertical Offset","ESP","YOffset",-64,64,1,"%.0f px")
    section(aim,"Aim control")
    for _,item in ipairs({{"Enable Aim","Enabled"},{"Enemies Only","EnemyOnly"},{"Ignore Teammates","IgnoreTeammates"},
        {"Target NPCs","Bots"},{"Wall Check","WallCheck"},{"Body Fallback","BodyFallback"},
        {"Hold RMB / Touch Button","HoldToAim"},{"Show FOV","ShowFOV"}}) do toggle(aim,item[1],"Aimbot",item[2]) end
    local aimParts={"Head","Neck","UpperTorso","LowerTorso","Root","Closest"}
    local priorities={"Closest","LowestHP"}; local origins={"Cursor","Screen"}
    local hotkeys={"None","F1","F2","F3","F4","F5","F6"}
    cycle(aim,"Aim Part","Aimbot","AimPart",aimParts)
    cycle(aim,"Priority","Aimbot","Priority",priorities)
    cycle(aim,"Origin","Aimbot","Origin",origins)
    slider(aim,"Maximum Distance","Aimbot","MaxDistance",50,2000,50,"%.0f studs")
    slider(aim,"FOV","Aimbot","FOV",30,500,10,"%.0f px")
    slider(aim,"Smoothing","Aimbot","Smoothing",0.05,1,0.05,"%.2f")
    slider(aim,"Prediction","Aimbot","Prediction",0,0.4,0.02,"%.2f s")
    slider(aim,"Stickiness","Aimbot","Stickiness",0,1,0.05,"%.2f")
    local universalAimRows={}
    for _,object in ipairs(aim:GetChildren()) do if object:IsA("GuiObject") then universalAimRows[object]=true end end
    section(aim,"Ball timing")
    toggle(aim,"Auto Parry","Ball","Enabled")
    toggle(aim,"Ball Marker","Ball","ShowMarker")
    slider(aim,"Timing Lead (calibrate)","Ball","LeadTime",0.03,0.5,0.01,"%.2f s")
    slider(aim,"Interaction Radius (calibrate)","Ball","Radius",1,20,0.5,"%.1f studs")
    slider(aim,"Minimum Request Interval","Ball","MinInterval",0.1,2,0.05,"%.2f s")
    cycle(aim,"Parry Key","Ball","Key",{"F","Q","E"})
    local ballInfo=row(aim,84)
    local ballStatus=label(ballInfo,"Waiting for profile",{Position=UDim2.fromOffset(10,4),Size=UDim2.new(1,-20,1,-8),
        TextSize=10,TextWrapped=true,TextYAlignment=Enum.TextYAlignment.Top})
    refreshProfileUI=function()
        local ballMode=State.profile and State.profile.id=="blade_ball"
        State.tabs.Aim.Text=ballMode and "PARRY" or "AIM"
        for _,object in ipairs(aim:GetChildren()) do
            if object:IsA("GuiObject") then object.Visible=universalAimRows[object] and not ballMode or not universalAimRows[object] and ballMode or false end
        end
    end
    refreshProfileUI()
    section(extra,"Game profile")
    action(extra,"CHANGE GAME",openSelector)
    section(extra,"Interface")
    toggle(extra,"FPS HUD","Misc","FpsHud"); toggle(extra,"Reduced Motion","Misc","ReducedMotion")
    cycle(extra,"ESP Hotkey","Misc","HotkeyESP",hotkeys); cycle(extra,"Aim Hotkey","Misc","HotkeyAim",hotkeys)
    for _,preset in ipairs({{"NEON PINK",Color3.fromRGB(255,35,190)},
        {"PURPLE HAZE",Color3.fromRGB(190,50,255)},{"CRIMSON RED",Color3.fromRGB(255,45,85)},
        {"CYAN VOLT",Color3.fromRGB(0,210,255)}}) do
        local color=preset[2]
        action(extra,preset[1],function() Settings.Misc.Accent=color; refreshWidgets() end)
    end

    -- Versioned, bounded config validation; commit occurs only after validation.
    local ranges={Ball={LeadTime={0.03,0.5},Radius={1,20},MinInterval={0.1,2},CurveDot={-1,1}},ESP={MaxDistance={100,3000},FillOpacity={0.05,0.5},ChamsFill={0,0.95},YOffset={-64,64}},
        Box={Thickness={0.1,20}},Name={Size={1,100}},Tracer={Thickness={0.1,20}},Skeleton={Thickness={0.1,20}},
        Aimbot={MaxDistance={50,2000},FOV={30,500},Smoothing={0.05,1},Prediction={0,0.4},Stickiness={0,1}}}
    local choices={Ball={Key={"F","Q","E"}},Aimbot={AimPart=aimParts,Priority=priorities,Origin=origins},
        Misc={HotkeyESP=hotkeys,HotkeyAim=hotkeys}}
    local function serialize()
        local data={version=5,settings={}}
        for name,sectionValues in pairs(Settings) do
            if name~="Runtime" then
                local target={}; data.settings[name]=target
                for key,value in pairs(sectionValues) do
                    if typeof(value)=="Color3" then target[key]={value.R,value.G,value.B}
                    elseif key=="Blacklist" then
                        local names={}
                        for entry,blocked in pairs(value) do if blocked then names[#names+1]=entry end end
                        table.sort(names); target[key]=names
                    else target[key]=value end
                end
            end
        end
        return data
    end
    local function validate(data)
        assert(type(data)=="table" and data.version==5 and type(data.settings)=="table","Unsupported settings format")
        for key in pairs(data) do assert(key=="version" or key=="settings","Unknown envelope field") end
        local candidate=copy(Defaults)
        for sectionName in pairs(data.settings) do
            assert(sectionName~="Runtime" and Defaults[sectionName],"Unknown section")
        end
        for sectionName,sectionDefaults in pairs(Defaults) do
            if sectionName~="Runtime" then
                local source=data.settings[sectionName]
                if source==nil and sectionName=="Ball" then source=copy(Defaults.Ball) end
                assert(type(source)=="table","Missing section: "..sectionName)
                for key in pairs(source) do assert(sectionDefaults[key]~=nil,"Unknown field") end
                for key,default in pairs(sectionDefaults) do
                    local value=source[key]
                    if typeof(default)=="Color3" then
                        assert(type(value)=="table","Invalid color")
                        local count=0
                        for i,channel in pairs(value) do
                            assert(i==1 or i==2 or i==3,"Invalid color key")
                            assert(finite(channel) and channel>=0 and channel<=1,"Invalid color channel")
                            count=count+1
                        end
                        assert(count==3,"Missing color channel")
                        candidate[sectionName][key]=Color3.new(value[1],value[2],value[3])
                    elseif key=="Blacklist" then
                        assert(type(value)=="table","Invalid blacklist")
                        local count=0
                        for i,name in pairs(value) do
                            assert(finite(i) and i>=1 and i%1==0 and i<=R.MaxBlacklist,"Invalid blacklist index")
                            assert(type(name)=="string" and #name<=R.MaxName and trim(name)~="","Invalid blacklist name")
                            count=count+1
                        end
                        candidate.Misc.Blacklist={}
                        for i=1,count do
                            assert(type(value[i])=="string","Sparse blacklist")
                            candidate.Misc.Blacklist[trim(value[i]):lower()]=true
                        end
                    else
                        assert(type(value)==type(default),"Invalid field: "..sectionName.."."..key)
                        if type(value)=="number" then
                            local range=ranges[sectionName] and ranges[sectionName][key]
                            assert(finite(value) and (not range or value>=range[1] and value<=range[2]),"Invalid number")
                        end
                        local options=choices[sectionName] and choices[sectionName][key]
                        if options then
                            local found=false
                            for _,option in ipairs(options) do if option==value then found=true end end
                            assert(found,"Invalid choice")
                        end
                        candidate[sectionName][key]=value
                    end
                end
            end
        end
        return candidate
    end
    local refreshBlacklist
    local function commit(candidate)
        for name,values in pairs(candidate) do
            if name~="Runtime" then
                for key,value in pairs(values) do Settings[name][key]=copy(value) end
            end
        end
        Settings.Ball.Enabled=false
        if State.ball then State.ball.Stop("settings changed") end
        State.touchAim,State.aiming=false,false
        resetAim(); refreshWidgets()
        if refreshBlacklist then refreshBlacklist() end
    end
    action(extra,"SAVE SETTINGS",function()
        if type(writefile)~="function" then notify("Filesystem unavailable"); return end
        local ok,err=pcall(function()
            local data=serialize(); validate(data)
            local payload=HttpService:JSONEncode(data)
            assert(#payload<=R.MaxConfigBytes,"Settings too large")
            writefile(R.File,payload)
            if type(readfile)=="function" then assert(readfile(R.File)==payload,"Readback mismatch") end
        end)
        notify(ok and "Settings saved" or "Save failed"); if not ok then warning("save",err) end
    end)
    action(extra,"LOAD SETTINGS",function()
        if type(readfile)~="function" then notify("Filesystem unavailable"); return end
        local ok,result=pcall(function()
            local payload=readfile(R.File)
            assert(type(payload)=="string" and #payload<=R.MaxConfigBytes,"Invalid settings size")
            return validate(HttpService:JSONDecode(payload))
        end)
        if ok then commit(result); notify("Settings loaded")
        else notify("Settings rejected; current values retained"); warning("load",result) end
    end)
    action(extra,"RESET SETTINGS",function() commit(Defaults); notify("Settings reset") end)
    action(extra,"UNLOAD",unload)
    section(blacklist,"Blocked names")
    toggle(blacklist,"Apply to ESP","Misc","BlacklistESP"); toggle(blacklist,"Apply to Aim","Misc","BlacklistAim")
    local entry=row(blacklist)
    local entryBox=make("TextBox",entry,{Position=UDim2.fromOffset(12,0),Size=UDim2.new(1,-90,1,0),
        BackgroundTransparency=1,Text="",PlaceholderText="Player or NPC name",TextColor3=Color3.new(1,1,1),
        PlaceholderColor3=palette.muted,TextSize=12,Font=Enum.Font.GothamMedium,ClearTextOnFocus=false,
        TextXAlignment=Enum.TextXAlignment.Left})
    local add=button(entry,"ADD",{Position=UDim2.new(1,-70,0,5),Size=UDim2.fromOffset(60,24)})
    local blockedText=row(blacklist,80)
    local blockedLabel=label(blockedText,"",{Position=UDim2.fromOffset(12,6),Size=UDim2.new(1,-24,1,-12),
        TextWrapped=true,TextYAlignment=Enum.TextYAlignment.Top})
    refreshBlacklist=function()
        local names={}
        for name in pairs(Settings.Misc.Blacklist) do names[#names+1]=name end
        table.sort(names)
        blockedLabel.Text=#names>0 and table.concat(names,", ") or "No blocked names. Enter an existing name to remove it."
        blockedText.Size=UDim2.new(1,-2,0,math.max(80,math.ceil(#blockedLabel.Text/55)*18+20))
        if refreshRoster then refreshRoster() end
    end
    local function editBlacklist()
        local name=trim(entryBox.Text):lower()
        if name=="" or #name>R.MaxName then notify("Enter a valid name"); return end
        local list=Settings.Misc.Blacklist
        if list[name] then list[name]=nil; notify("Removed "..name)
        else
            local count=0; for _ in pairs(list) do count=count+1 end
            if count>=R.MaxBlacklist then notify("Blacklist is full"); return end
            list[name]=true; notify("Blocked "..name)
        end
        entryBox.Text=""; resetAim(); refreshBlacklist()
    end
    connect(add.Activated,editBlacklist)
    connect(entryBox.FocusLost,function(enter) if enter then editBlacklist() end end)
    section(blacklist,"Detected players / NPCs")
    local detected=frame(blacklist,{Name="DetectedRoster",Size=UDim2.new(1,-2,0,0),BackgroundTransparency=1,
        LayoutOrder=(order[blacklist] or 0)+1})
    order[blacklist]=detected.LayoutOrder
    make("UIListLayout",detected,{Padding=UDim.new(0,R.Gap),SortOrder=Enum.SortOrder.LayoutOrder})
    local rosterRows={}
    local function descriptorBlocked(descriptor)
        for _,name in ipairs(descriptor.aliases) do if Settings.Misc.Blacklist[name] then return true end end
        return false
    end
    refreshRoster=function()
        local entries,playerCharacters={},{}
        for _,player in ipairs(Players:GetPlayers()) do
            if player.Character then playerCharacters[player.Character]=true end
            if player~=LocalPlayer then
                local aliases={player.Name:lower(),player.DisplayName:lower()}
                if instance(player.Character,"Model") then aliases[#aliases+1]=player.Character.Name:lower() end
                entries[#entries+1]={id=player,name=player.Name:lower(),aliases=aliases,
                    text=player.DisplayName.." (@"..player.Name..")",kind="PLAYER"}
            end
        end
        for model in pairs(State.bots) do
            if within(model,workspace) and model~=LocalPlayer.Character and not playerCharacters[model]
                and not Players:GetPlayerFromCharacter(model) then
                -- Attribute checks here use the instance directly; faction helpers are declared later.
                if model:GetAttribute("IgnoreOverlay")~=true then
                    entries[#entries+1]={id=model,name=model.Name:lower(),aliases={model.Name:lower()},text=model.Name,kind="NPC"}
                end
            end
        end
        table.sort(entries,function(a,b)
            if a.kind~=b.kind then return a.kind=="PLAYER" end
            return a.text:lower()<b.text:lower()
        end)
        local active={}
        for index,descriptor in ipairs(entries) do
            active[descriptor.id]=true
            local item=rosterRows[descriptor.id]
            if not item then
                item={}
                item.row=frame(detected,{Size=UDim2.new(1,0,0,38),BackgroundColor3=palette.row})
                round(item.row,12)
                item.label=label(item.row,"",{Position=UDim2.fromOffset(10,0),Size=UDim2.new(1,-100,1,0),
                    TextSize=10,TextTruncate=Enum.TextTruncate.AtEnd})
                item.button=make("TextButton",item.row,{Position=UDim2.new(1,-86,0,7),Size=UDim2.fromOffset(76,24),
                    BorderSizePixel=0,TextSize=9,Font=Enum.Font.GothamSemibold,TextColor3=Color3.new(1,1,1),
                    AutoButtonColor=false,BackgroundColor3=palette.row})
                round(item.button,8)
                item.connection=connect(item.button.Activated,function()
                    local selected=item.descriptor
                    local list=Settings.Misc.Blacklist
                    if descriptorBlocked(selected) then
                        for _,name in ipairs(selected.aliases) do list[name]=nil end
                        notify("Unblocked "..selected.text)
                    else
                        if #selected.name>R.MaxName or trim(selected.name)=="" then notify("Name exceeds settings limit"); return end
                        local count=0; for _ in pairs(list) do count=count+1 end
                        if count>=R.MaxBlacklist then notify("Blacklist is full"); return end
                        list[selected.name]=true
                        notify("Blocked "..selected.text)
                    end
                    resetAim(); refreshBlacklist()
                end)
                rosterRows[descriptor.id]=item
            end
            item.descriptor=descriptor
            item.row.LayoutOrder=index
            item.label.Text="["..descriptor.kind.."] "..descriptor.text
            local blocked=descriptorBlocked(descriptor)
            item.button.Text=blocked and "UNBLOCK" or "BLOCK"
            item.button.BackgroundColor3=blocked and Color3.fromRGB(90,35,65) or Settings.Misc.Accent
        end
        for key,item in pairs(rosterRows) do
            if not active[key] then disconnect(item.connection); destroy(item.row); rosterRows[key]=nil end
        end
        detected.Size=UDim2.new(1,-2,0,#entries*(38+R.Gap))
    end
    local statusText=label(status,"",{Size=UDim2.new(1,-6,0,200),TextSize=11,Font=Enum.Font.Code,
        TextYAlignment=Enum.TextYAlignment.Top,TextWrapped=true})
    order[status]=order[status]+1; statusText.LayoutOrder=order[status]
    local function clampWindow()
        local size=viewport()
        local factor=math.max(0.01,math.min(1,(size.X-R.Margin*2)/R.Width,(size.Y-R.Margin*2)/R.Height))
        scale.Scale=factor; Main.Size=UDim2.fromOffset(R.Width*factor,R.Height*factor)
        local p=Main.Position
        local x=p.X.Scale*size.X+p.X.Offset; local y=p.Y.Scale*size.Y+p.Y.Offset
        local half=Main.Size.X.Offset/2; local tall=Main.Size.Y.Offset/2
        Main.Position=UDim2.fromOffset(math.clamp(x,half,math.max(half,size.X-half)),
            math.clamp(y,tall,math.max(tall,size.Y-tall)))
        local f=fab.Position; local fx=f.X.Scale*size.X+f.X.Offset; local fy=f.Y.Scale*size.Y+f.Y.Offset
        fab.Position=UDim2.fromOffset(math.clamp(fx,46,math.max(46,size.X)),math.clamp(fy,46,math.max(46,size.Y)))
    end
    local fabMoved=false
    local function draggable(handle,target,isPanel)
        connect(handle.InputBegan,function(input)
            if not press(input) or pointer then return end
            if isPanel then
                for _,control in ipairs({minimize,close}) do
                    local p,s=control.AbsolutePosition,control.AbsoluteSize
                    if input.Position.X>=p.X and input.Position.X<=p.X+s.X
                        and input.Position.Y>=p.Y and input.Position.Y<=p.Y+s.Y then return end
                end
            end
            local start=input.Position; local p=target.Position; local size=viewport()
            local origin=Vector2.new(p.X.Scale*size.X+p.X.Offset,p.Y.Scale*size.Y+p.Y.Offset)
            if not isPanel then fabMoved=false end
            pointer={input=input,panel=isPanel,move=function(position)
                local delta=position-start
                if delta.Magnitude<R.DragThreshold then return end
                if not isPanel then fabMoved=true end
                target.Position=UDim2.fromOffset(origin.X+delta.X,origin.Y+delta.Y)
                clampWindow()
            end}
        end)
    end
    draggable(header,Main,true); draggable(fab,fab,false)
    connect(fab.Activated,function() if fabMoved then fabMoved=false; return end; panel(not Main.Visible) end)
    connect(Main:GetPropertyChangedSignal("Visible"),function() if pointer and pointer.panel then stopPointer() end end)
    connect(touch.InputBegan,function(input)
        if touch.Visible and State.focused and press(input) and not touchInput then touchInput=input; State.touchAim=true end
    end)
    connect(UIS.InputEnded,function(input)
        if input==touchInput then touchInput=nil; State.touchAim=false; resetAim() end
    end)

    State.phase="rig discovery"
    -- Rig discovery is independent of ESP/aim switches; ownership is reconciled at scan time.
    local factionKeys={"Team","TeamId","TeamID","TeamName","Faction","Group","TeamValue"}
    local function attribute(object,key)
        if instance(object) then return object:GetAttribute(key) end
        return nil
    end
    local function normalize(value)
        if finite(value) then return "id:"..tostring(value) end
        if type(value)=="string" and trim(value)~="" then return "name:"..trim(value):lower() end
    end
    local function faction(object)
        if not instance(object) then return nil end
        if object:IsA("Player") and object.Team and not object.Neutral then return normalize(object.Team.Name) end
        for _,key in ipairs(factionKeys) do
            local token=normalize(attribute(object,key)); if token then return token end
        end
        local child=object:FindFirstChild("Team")
        if child and (child:IsA("StringValue") or child:IsA("IntValue") or child:IsA("NumberValue")) then
            return normalize(child.Value)
        end
        if object:IsA("Player") and not object.Neutral then return "color:"..tostring(object.TeamColor) end
    end
    local function sameTeam(target)
        local mine=faction(LocalPlayer) or faction(LocalPlayer.Character)
        local theirs=faction(target.player) or faction(target.character)
        return mine~=nil and theirs~=nil and mine==theirs
    end
    local function friendly(target)
        if sameTeam(target) then return true end
        -- No array of optional values: nil Player slots must not truncate iteration.
        local function flagged(object)
            return instance(object) and (attribute(object,"Friendly")==true
                or attribute(object,"Enemy")==false or attribute(object,"IsEnemy")==false)
        end
        return flagged(target.character) or flagged(target.player)
    end
    local function blocked(target)
        local list=Settings.Misc.Blacklist
        return list[target.character.Name:lower()] or target.player
            and (list[target.player.Name:lower()] or list[target.player.DisplayName:lower()]) or false
    end
    local function rig(model)
        if not instance(model,"Model") or not within(model,workspace) then return end
        local humanoid=model:FindFirstChildOfClass("Humanoid") or model:FindFirstChildWhichIsA("Humanoid",true)
        if not humanoid then return end
        -- A nested child rig must not make its outer container a character.
        local node=humanoid.Parent
        while node and node~=model do
            if node:IsA("Model") and node:FindFirstChild("HumanoidRootPart") then return end
            node=node.Parent
        end
        local root=model:FindFirstChild("HumanoidRootPart")
        if not instance(root,"BasePart") then
            local declared=humanoid.RootPart
            if instance(declared,"BasePart") and within(declared,model)
                and (declared.Name=="Torso" or declared.Name=="UpperTorso") then root=declared else return end
        end
        local head=model:FindFirstChild("Head")
        return root,instance(head,"BasePart") and head or nil,humanoid
    end
    local function alive(model,root,humanoid)
        if not root or not humanoid or not finite(humanoid.Health) or humanoid.Health<=0
            or humanoid:GetState()==Enum.HumanoidStateType.Dead or not vector(root.Position) then return false end
        -- Anchoring, Physics and PlatformStand are not evidence of death.
        return attribute(model,"Dead")~=true and attribute(model,"IsDead")~=true
            and attribute(humanoid,"Dead")~=true and attribute(humanoid,"IsDead")~=true
    end
    local function register(object)
        if not instance(object,"Humanoid") then return end
        local node=object.Parent
        while node and node~=workspace do
            if node:IsA("Model") then
                local root,_,humanoid=rig(node)
                if root and humanoid==object then State.bots[node]=true; return end
            end
            node=node.Parent
        end
    end
    local discoveryQueued={}
    connect(workspace.DescendantAdded,function(object)
        if object:IsA("Humanoid") then register(object)
        elseif object:IsA("BasePart") and (object.Name=="HumanoidRootPart" or object.Name=="Torso" or object.Name=="UpperTorso") then
            local node=object.Parent
            while node and node~=workspace do
                if node:IsA("Model") then discoveryQueued[node]=true end
                node=node.Parent
            end
        end
    end)
    connect(workspace.DescendantRemoving,function(object)
        if State.bots[object] then State.bots[object]=nil end
        if State.current and (State.current.target.character==object or State.current.part==object) then resetAim() end
    end)
    spawnTask(function()
        for index,object in ipairs(workspace:GetDescendants()) do
            if not State.running then return end
            if object:IsA("Humanoid") then register(object) end
            if index%R.DiscoveryBatch==0 then task.wait() end
        end
    end)
    local function removeVisual(key)
        local visual=State.visuals[key]
        if not visual then return end
        destroy(visual.highlight); destroy(visual.group); State.visuals[key]=nil
    end
    local function scan()
        for model in pairs(discoveryQueued) do
            discoveryQueued[model]=nil
            if within(model,workspace) then
                local _,_,humanoid=rig(model); if humanoid then register(humanoid) end
            end
        end
        local targets,characters,liveKeys={},{},{}
        for _,player in ipairs(Players:GetPlayers()) do
            local character=player.Character
            if character then characters[character]=true end
            if player~=LocalPlayer and instance(character,"Model") and within(character,workspace) then
                targets[#targets+1]={id=player,player=player,character=character,label=player.DisplayName,isBot=false}
                liveKeys[player]=true
            end
        end
        for model in pairs(State.bots) do
            if not within(model,workspace) then State.bots[model]=nil
            elseif not characters[model] and model~=LocalPlayer.Character and not Players:GetPlayerFromCharacter(model)
                and attribute(model,"IgnoreOverlay")~=true then
                targets[#targets+1]={id=model,character=model,label=model.Name,isBot=true}; liveKeys[model]=true
            end
        end
        State.targets=targets
        if Main.Visible and currentPage=="Blacklist" and State.profile then refreshRoster() end
        for key in pairs(State.visuals) do if not liveKeys[key] then removeVisual(key) end end
        if State.current and not liveKeys[State.current.target.id] then resetAim() end
    end
    connect(Players.PlayerRemoving,function(player)
        removeVisual(player)
        if State.current and State.current.target.id==player then resetAim() end
    end)
    local ray=RaycastParams.new(); ray.FilterType=Enum.RaycastFilterType.Exclude; ray.IgnoreWater=true
    local function visible(position,model)
        local camera=workspace.CurrentCamera
        if not camera or not vector(position) then return false end
        local origin=camera.CFrame.Position; local direction=position-origin
        if direction.Magnitude<=R.NearPlane then return true end
        local exclusions={}
        if LocalPlayer.Character then exclusions[#exclusions+1]=LocalPlayer.Character end
        -- Camera descendants commonly contain first-person viewmodels.
        exclusions[#exclusions+1]=camera
        for _=1,R.RayPasses do
            ray.FilterDescendantsInstances=exclusions
            local hit=workspace:Raycast(origin,direction,ray)
            if not hit or within(hit.Instance,model) then return true end
            if instance(hit.Instance,"BasePart") and hit.Instance.Transparency>=R.VisibilityThreshold then
                exclusions[#exclusions+1]=hit.Instance
            else return false end
        end
        return false
    end
    local function project(position)
        if not vector(position) then return end
        local camera=workspace.CurrentCamera; if not camera then return end
        local p,on=camera:WorldToViewportPoint(position)
        if not vector(p) or p.Z<=R.NearPlane then return end
        return Vector2.new(p.X,p.Y),on
    end
    local signs={-1,1}
    local function bounds(model)
        local cf,size=model:GetBoundingBox()
        if not vector(size) then return end
        local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge
        for _,x in ipairs(signs) do for _,y in ipairs(signs) do for _,z in ipairs(signs) do
            local p=project(cf:PointToWorldSpace(Vector3.new(size.X*x,size.Y*y,size.Z*z)/2))
            if not p then return end
            left,top,right,bottom=math.min(left,p.X),math.min(top,p.Y),math.max(right,p.X),math.max(bottom,p.Y)
        end end end
        top,bottom=top+Settings.ESP.YOffset,bottom+Settings.ESP.YOffset
        local size2=viewport()
        if right<0 or bottom<0 or left>size2.X or top>size2.Y or right-left<2 or bottom-top<3 then return end
        return left,top,right-left,bottom-top
    end
    local function line(parent)
        return frame(parent,{Visible=false,AnchorPoint=Vector2.new(0.5,0.5),BackgroundColor3=Color3.new(1,1,1)})
    end
    local function setLine(object,a,b,color,thickness)
        local delta=b-a
        object.Position=UDim2.fromOffset((a.X+b.X)/2,(a.Y+b.Y)/2)
        object.Size=UDim2.fromOffset(delta.Magnitude,thickness)
        object.Rotation=math.deg(math.atan2(delta.Y,delta.X)); object.BackgroundColor3=color; object.Visible=true
    end
    local bones15={{"Head","UpperTorso"},{"UpperTorso","LowerTorso"},{"UpperTorso","LeftUpperArm"},
        {"LeftUpperArm","LeftLowerArm"},{"LeftLowerArm","LeftHand"},{"UpperTorso","RightUpperArm"},
        {"RightUpperArm","RightLowerArm"},{"RightLowerArm","RightHand"},{"LowerTorso","LeftUpperLeg"},
        {"LeftUpperLeg","LeftLowerLeg"},{"LeftLowerLeg","LeftFoot"},{"LowerTorso","RightUpperLeg"},
        {"RightUpperLeg","RightLowerLeg"},{"RightLowerLeg","RightFoot"}}
    local bones6={{"Head","Torso"},{"Torso","Left Arm"},{"Torso","Right Arm"},{"Torso","Left Leg"},{"Torso","Right Leg"}}
    local function newVisual(key)
        local group=frame(Overlay,{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Visible=false})
        local v={group=group,corners={},bones={}}
        v.fill=frame(group,{Visible=false})
        v.box=frame(group,{BackgroundTransparency=1,Visible=false})
        v.outline=stroke(v.box,Color3.new(0,0,0),4)
        v.edge=frame(group,{BackgroundTransparency=1,Visible=false}); v.stroke=stroke(v.edge,Settings.Box.Color,1)
        v.healthBG=frame(group,{BackgroundColor3=Color3.new(0,0,0),Visible=false})
        v.health=frame(group,{Visible=false})
        v.name=label(group,"",{TextXAlignment=Enum.TextXAlignment.Center,Visible=false})
        v.distance=label(group,"",{TextXAlignment=Enum.TextXAlignment.Center,Visible=false})
        for _,object in ipairs({v.name,v.distance}) do
            object.TextStrokeTransparency=0.2; object.TextStrokeColor3=Color3.new(0,0,0)
        end
        v.tracer=line(group)
        for i=1,8 do v.corners[i]=line(group) end
        State.visuals[key]=v
        return v
    end
    local function hideVisual(v)
        v.group.Visible=false
        if v.highlight then v.highlight.Enabled=false end
    end
    local function clearVisualChildren(v)
        for _,object in ipairs(v.group:GetChildren()) do if object:IsA("GuiObject") then object.Visible=false end end
    end
    local function valid(target)
        return within(target.character,workspace) and target.character~=LocalPlayer.Character
            and (target.isBot and not Players:GetPlayerFromCharacter(target.character)
                or target.player and target.player.Parent==Players and target.player.Character==target.character)
    end
    local function renderTarget(target,origin)
        local e=Settings.ESP
        if not e.Enabled or not valid(target) or target.isBot and not e.Bots then return "off" end
        if (target.isBot and e.BotTeamCheck or not target.isBot and e.EnemyOnly) and friendly(target) then return "team" end
        if Settings.Misc.BlacklistESP and blocked(target) then return "blacklist" end
        local root,head,humanoid=rig(target.character)
        if not alive(target.character,root,humanoid) then return "dead / incomplete" end
        local distance=(origin-root.Position).Magnitude
        if distance>e.MaxDistance then return "far" end
        local x,y,w,h=bounds(target.character); if not x then return "off screen" end
        local seen=e.VisibleCheck and visible((head or root).Position,target.character)
        if e.VisibleCheck and not seen then return "occluded" end
        local color=seen and Settings.Box.VisColor or Settings.Box.Color
        local v=State.visuals[target.id] or newVisual(target.id)
        clearVisualChildren(v); v.group.Visible=true
        if Settings.Box.Enabled then
            if e.FilledBox then
                v.fill.Position=UDim2.fromOffset(x,y); v.fill.Size=UDim2.fromOffset(w,h)
                v.fill.BackgroundColor3=color; v.fill.BackgroundTransparency=1-e.FillOpacity; v.fill.Visible=true
            end
            if e.CornerBoxes then
                local len=math.min(w,h)*0.28
                local edges={{x,y,x+len,y},{x,y,x,y+len},{x+w,y,x+w-len,y},{x+w,y,x+w,y+len},
                    {x,y+h,x+len,y+h},{x,y+h,x,y+h-len},{x+w,y+h,x+w-len,y+h},{x+w,y+h,x+w,y+h-len}}
                for i,p in ipairs(edges) do setLine(v.corners[i],Vector2.new(p[1],p[2]),Vector2.new(p[3],p[4]),color,Settings.Box.Thickness) end
            else
                for _,object in ipairs({v.box,v.edge}) do
                    object.Position=UDim2.fromOffset(x,y); object.Size=UDim2.fromOffset(w,h); object.Visible=true
                end
                v.outline.Thickness=Settings.Box.Thickness+2; v.stroke.Color=color; v.stroke.Thickness=Settings.Box.Thickness
            end
        end
        if Settings.Name.Enabled then
            v.name.Text=target.label; v.name.TextColor3=Settings.Name.Color; v.name.TextSize=Settings.Name.Size
            v.name.Position=UDim2.fromOffset(x-80,y-Settings.Name.Size-6)
            v.name.Size=UDim2.fromOffset(w+160,Settings.Name.Size+4); v.name.Visible=true
        end
        if Settings.Distance.Enabled then
            v.distance.Text=string.format("[%d studs]",math.floor(distance)); v.distance.TextColor3=Settings.Distance.Color
            v.distance.Position=UDim2.fromOffset(x-30,y+h+3); v.distance.Size=UDim2.fromOffset(w+60,16); v.distance.Visible=true
        end
        if Settings.Health.Enabled then
            local max=finite(humanoid.MaxHealth) and math.max(1,humanoid.MaxHealth) or 1
            local ratio=math.clamp(humanoid.Health/max,0,1)
            v.healthBG.Position=UDim2.fromOffset(x-7,y-1); v.healthBG.Size=UDim2.fromOffset(4,h+2); v.healthBG.Visible=true
            v.health.Position=UDim2.fromOffset(x-6,y+h*(1-ratio)); v.health.Size=UDim2.fromOffset(2,h*ratio)
            v.health.BackgroundColor3=Color3.fromRGB(255,65,75):Lerp(Color3.fromRGB(65,255,130),ratio); v.health.Visible=true
        end
        if Settings.Tracer.Enabled then
            local size=viewport()
            setLine(v.tracer,Vector2.new(size.X/2,size.Y),Vector2.new(x+w/2,y+h),Settings.Tracer.Color,Settings.Tracer.Thickness)
        end
        if Settings.Skeleton.Enabled then
            local list=humanoid.RigType==Enum.HumanoidRigType.R15 and bones15 or bones6
            for index,pair in ipairs(list) do
                if not v.bones[index] then v.bones[index]=line(v.group) end
                local a,b=target.character:FindFirstChild(pair[1]),target.character:FindFirstChild(pair[2])
                if instance(a,"BasePart") and instance(b,"BasePart") then
                    local pa,ona=project(a.Position); local pb,onb=project(b.Position)
                    if pa and pb and ona and onb then
                        local offset=Vector2.new(0,e.YOffset)
                        setLine(v.bones[index],pa+offset,pb+offset,Settings.Skeleton.Color,Settings.Skeleton.Thickness)
                    end
                end
            end
        end
        if e.Chams then
            if not v.highlight then v.highlight=make("Highlight",target.character,{Name="OverlayHighlight"}) end
            v.highlight.Adornee=target.character; v.highlight.Enabled=true
            v.highlight.FillColor=color; v.highlight.OutlineColor=color; v.highlight.FillTransparency=e.ChamsFill
            v.highlight.DepthMode=e.VisibleCheck and Enum.HighlightDepthMode.Occluded or Enum.HighlightDepthMode.AlwaysOnTop
        elseif v.highlight then destroy(v.highlight); v.highlight=nil end
        return "drawn"
    end

    -- Aim uses the selected world point consistently for scoring, movement and marker.
    local circle=frame(Overlay,{BackgroundTransparency=1,AnchorPoint=Vector2.new(0.5,0.5),Visible=false})
    round(circle,10000); local circleStroke=stroke(circle,Settings.Misc.Accent,1.2)
    local marker=frame(Overlay,{Size=UDim2.fromOffset(R.MarkerSize,R.MarkerSize),
        AnchorPoint=Vector2.new(0.5,0.5),Visible=false}); round(marker,R.MarkerSize)
    local function mouseMode()
        return not State.touchAim and Settings.Aimbot.Origin=="Cursor" and UIS.MouseEnabled and type(mousemoverel)=="function"
    end
    local function aimOrigin()
        local size=viewport()
        if mouseMode() then return UIS:GetMouseLocation() end
        return Vector2.new(size.X/2,size.Y/2)
    end
    local function candidates(model,root,head)
        local torso=model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
        local lower=model:FindFirstChild("LowerTorso") or torso
        local result={}
        local function add(part,name,position,velocity)
            if not instance(part,"BasePart") then return end
            position=position or part.Position; velocity=velocity or part.AssemblyLinearVelocity
            if vector(position) then result[#result+1]={part=part,name=name,position=position,
                velocity=vector(velocity) and velocity or Vector3.new()} end
        end
        add(head,"Head")
        if instance(head,"BasePart") and instance(torso,"BasePart") then
            add(torso,"Neck",(head.Position+torso.Position)/2,(head.AssemblyLinearVelocity+torso.AssemblyLinearVelocity)/2)
        else add(head or torso,"Neck") end
        add(torso,"UpperTorso"); add(lower,"LowerTorso"); add(root,"Root")
        return result
    end
    local function evaluate(center,origin)
        local a=Settings.Aimbot; local best,sticky
        for _,target in ipairs(State.targets) do
            if valid(target) and (not target.isBot or a.Bots) and not (a.EnemyOnly and friendly(target))
                and not (a.IgnoreTeammates and sameTeam(target)) and not (Settings.Misc.BlacklistAim and blocked(target)) then
                local root,head,humanoid=rig(target.character)
                if alive(target.character,root,humanoid) and (origin-root.Position).Magnitude<=a.MaxDistance then
                    local list=candidates(target.character,root,head)
                    local localBest
                    local function consider(c)
                        local predicted=c.position+c.velocity*a.Prediction
                        local p,on=project(predicted); if not p or not on then return end
                        local distance=(p-center).Magnitude; if distance>a.FOV then return end
                        if a.WallCheck and (not visible(c.position,target.character) or not visible(predicted,target.character)) then return end
                        local ratio=distance/math.max(a.FOV,1)
                        local max=finite(humanoid.MaxHealth) and math.max(humanoid.MaxHealth,1) or 1
                        local score=a.Priority=="LowestHP" and math.clamp(humanoid.Health/max,0,1)+ratio*0.05 or ratio
                        if not localBest or score<localBest.score then
                            localBest={target=target,part=c.part,name=c.name,position=predicted,screen=p,score=score}
                        end
                    end
                    for _,c in ipairs(list) do if a.AimPart=="Closest" or c.name==a.AimPart then consider(c) end end
                    if not localBest and a.BodyFallback and a.AimPart~="Closest" then
                        for _,c in ipairs(list) do if c.name=="UpperTorso" or c.name=="LowerTorso" or c.name=="Root" then consider(c) end end
                    end
                    if localBest then
                        if State.current and State.current.target.id==target.id then sticky=localBest end
                        if not best or localBest.score<best.score then best=localBest end
                    end
                end
            end
        end
        if sticky and best and sticky.score-best.score<=a.Stickiness*0.6 then return sticky end
        return best
    end
    local function cameraAim(position,alpha)
        local camera=workspace.CurrentCamera; local current=camera.CFrame; local direction=position-current.Position
        if direction.Magnitude<=R.NearPlane then return end
        local up=current.UpVector
        if math.abs(direction.Unit:Dot(up))>0.999 then up=current.RightVector end
        camera.CFrame=current:Lerp(CFrame.lookAt(current.Position,position,up),alpha)
    end
    local function trunc(n) return n>=0 and math.floor(n) or math.ceil(n) end
    local function aimFrame(dt,origin)
        local a=Settings.Aimbot; local center=aimOrigin()
        circle.Visible=State.focused and a.Enabled and a.ShowFOV
        circle.Position=UDim2.fromOffset(center.X,center.Y); circle.Size=UDim2.fromOffset(a.FOV*2,a.FOV*2)
        circleStroke.Color=Settings.Misc.Accent; marker.Visible=false
        syncTouch()
        if not State.focused or not a.Enabled then resetAim(); return end
        if UIS:GetFocusedTextBox() then resetAim("typing"); return end
        if a.HoldToAim and not (State.aiming or State.touchAim) then resetAim("hold RMB / touch"); return end
        local best=evaluate(center,origin)
        if not best then resetAim("no target"); return end
        if not State.current or State.current.target.id~=best.target.id or State.current.name~=best.name then
            State.remainder=Vector2.new()
        end
        State.current=best; State.debug=best.target.label.." / "..best.name
        local alpha=1-math.exp(-R.SmoothRate*a.Smoothing*math.clamp(dt,0,R.MaxDelta))
        if mouseMode() then
            local delta=(best.screen-center)*alpha+State.remainder
            local dx,dy=trunc(delta.X),trunc(delta.Y)
            if dx~=0 or dy~=0 then
                if pcall(mousemoverel,dx,dy) then State.remainder=delta-Vector2.new(dx,dy)
                else State.remainder=Vector2.new(); cameraAim(best.position,alpha) end
            else State.remainder=delta end
        else State.remainder=Vector2.new(); cameraAim(best.position,alpha) end
        if Settings.ESP.Enabled and Settings.ESP.TargetMarker then
            local point,on=project(best.position)
            if point and on then marker.Position=UDim2.fromOffset(point.X,point.Y); marker.BackgroundColor3=Settings.Misc.Accent; marker.Visible=true end
        end
    end
    State.ball=newBallAdapter({settings=Settings.Ball,player=LocalPlayer,folder=R.BallFolder,
        active=function() return State.profile and State.profile.id=="blade_ball" end,
        focused=function() return State.focused end,typing=function() return UIS:GetFocusedTextBox()~=nil end,
        menuOpen=function() return Main.Visible end,inputFailed=function() refreshWidgets() end})
    local ballMarker=frame(Overlay,{Name="BallMarker",Size=UDim2.fromOffset(12,12),
        AnchorPoint=Vector2.new(0.5,0.5),BackgroundTransparency=1,Visible=false})
    round(ballMarker,UDim.new(1,0)); themed(stroke(ballMarker,Settings.Misc.Accent,2),"Color")
    State.phase="input binding"
    connect(UIS.InputBegan,function(input,processed)
        if not State.profile or not State.focused or processed or UIS:GetFocusedTextBox() then return end
        if input.UserInputType==Enum.UserInputType.MouseButton2 then State.aiming=true end
        if input.UserInputType~=Enum.UserInputType.Keyboard then return end
        local name=input.KeyCode.Name
        if name==Settings.Misc.HotkeyESP then
            Settings.ESP.Enabled=not Settings.ESP.Enabled; refreshWidgets()
            notify("ESP "..(Settings.ESP.Enabled and "ON" or "OFF"))
        elseif State.profile.id=="universal" and name==Settings.Misc.HotkeyAim then
            Settings.Aimbot.Enabled=not Settings.Aimbot.Enabled; resetAim(); refreshWidgets()
            notify("Aim "..(Settings.Aimbot.Enabled and "ON" or "OFF"))
        end
    end)
    connect(UIS.InputEnded,function(input)
        if input.UserInputType==Enum.UserInputType.MouseButton2 then State.aiming=false; if Settings.Aimbot.HoldToAim then resetAim() end end
    end)
    connect(UIS.WindowFocusReleased,function()
        State.focused,State.aiming,State.touchAim=false,false,false
        touchInput=nil; stopPointer(); resetAim(); circle.Visible=false; marker.Visible=false
    end)
    connect(UIS.WindowFocused,function() State.focused=true; State.aiming=false end)
    local cameraConnection
    local function bindCamera()
        disconnect(cameraConnection); cameraConnection=nil; resetAim()
        local camera=workspace.CurrentCamera
        if camera then cameraConnection=connect(camera:GetPropertyChangedSignal("ViewportSize"),clampWindow) end
        clampWindow()
    end
    connect(workspace:GetPropertyChangedSignal("CurrentCamera"),bindCamera)
    local function updateStatus()
        if not State.profile then footer.Text="CHOOSE A PROFILE"; return end
        footer.Text=Settings.Misc.FpsHud and string.format("%d FPS  /  %d VISIBLE  /  %d ERRORS",State.fps,
            State.stats.drawn or 0,State.stats.errors or 0) or "READY"
        if not Main.Visible or currentPage~="Status" then return end
        local lines={"profile: "..State.profile.name,"parry: "..State.ball.status,"aim: "..State.debug,"renderer: Roblox GUI",""}
        for _,target in ipairs(State.targets) do
            lines[#lines+1]=(target.isBot and "[npc] " or "")..target.label.."  "..(target.reason or "waiting")
        end
        statusText.Text=table.concat(lines,"\n"); statusText.Size=UDim2.new(1,-6,0,math.max(200,#lines*16))
    end
    connect(RunService.Heartbeat,function(dt)
        State.frames=State.frames+1; State.elapsed=State.elapsed+dt
        if State.elapsed>=0.5 then State.fps=math.floor(State.frames/State.elapsed+0.5); State.frames=0; State.elapsed=0 end
        State.scanElapsed=State.scanElapsed+dt; State.statusElapsed=State.statusElapsed+dt
        if State.scanElapsed>=R.ScanInterval then State.scanElapsed=0; scan() end
        if State.statusElapsed>=R.StatusInterval then State.statusElapsed=0; updateStatus() end
        if State.profile and State.profile.id=="blade_ball" then
            if not guarded("ball-step",State.ball.Step,os.clock()) then Settings.Ball.Enabled=false; State.ball.Stop("adapter error"); refreshWidgets() end
            ballStatus.Text=State.ball.status.."\n"..(State.ball.tti and string.format("Predicted entry: %.3fs",State.ball.tti) or "No predicted intercept")
                .."\nTiming is uncalibrated. Key requests are not success confirmation."
        end
        if toast.Visible and os.clock()>=toastUntil then toast.Visible=false end
    end)
    local function render(dt)
        if not State.running then return end
        marker.Visible=false
        ballMarker.Visible=false
        for _,v in pairs(State.visuals) do hideVisual(v) end
        if not State.profile then circle.Visible=false; syncTouch(); resetAim("choose a profile"); return end
        local camera=workspace.CurrentCamera
        if not camera then circle.Visible=false; resetAim(); return end
        local myRoot=rig(LocalPlayer.Character)
        local origin=myRoot and myRoot.Position or camera.CFrame.Position
        -- Resolve camera movement before projecting the overlay for this frame.
        local aimOK,aimError=true,nil
        if State.profile.id=="universal" then aimOK,aimError=pcall(aimFrame,dt,origin)
        else
            resetAim(); circle.Visible=false
            if Settings.Ball.ShowMarker and State.ball.point then
                local point,on=project(State.ball.point)
                if point and on then ballMarker.Position=UDim2.fromOffset(point.X,point.Y); ballMarker.Visible=true end
            end
        end
        if not aimOK then resetAim("aim error"); marker.Visible=false; circle.Visible=false; warning("aim",aimError) end
        local stats={drawn=0,errors=0}
        for _,target in ipairs(State.targets) do
            local ok,result=pcall(renderTarget,target,origin)
            if ok then
                target.reason=result
                if result=="drawn" then stats.drawn=stats.drawn+1 end
            else
                local v=State.visuals[target.id]; if v then hideVisual(v) end
                target.reason="error"; stats.errors=stats.errors+1; warning("renderTarget",result)
            end
        end
        State.stats=stats
        if not Settings.Misc.ReducedMotion and Main.Visible then
            outline.Transparency=0.18+0.12*math.sin(os.clock()*2)
            haloStroke.Transparency=0.22+0.14*math.sin(os.clock()*2)
        else outline.Transparency=0.18; haloStroke.Transparency=0.22 end
        if not Settings.Misc.ReducedMotion then
            fabRing.Transparency=0.55+0.12*math.sin(os.clock()*2)
        else fabRing.Transparency=0.65 end
    end
    State.phase="render binding"
    local ok,err=pcall(function()
        RunService:BindToRenderStep(R.RenderName,Enum.RenderPriority.Camera.Value+1,function(dt)
            if not guarded("frame",render,dt) then
                resetAim("frame error"); marker.Visible=false; circle.Visible=false
                for _,v in pairs(State.visuals) do hideVisual(v) end
            end
        end)
    end)
    if not ok then warning("bind",err); connect(RunService.RenderStepped,render) end
    State.phase="opening selector"
    refreshBlacklist(); refreshWidgets(); bindCamera(); selectPage("ESP"); scan(); openSelector(); panel(true)
    State.phase="ready"
    env.XCVIP_LastError=nil
    notify(R.Name.." "..R.Version.." loaded")
end
local ok,err=pcall(initialize)
if not ok then startupFailure(err) end
