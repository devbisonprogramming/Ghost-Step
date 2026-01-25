--[[
NOTE:
This system is implemented as a LocalScript to directly handle player input, camera effects, and responsive
movement. In a game setting, final position and other validation would be server-authoritative, but for the
sake of the demonstration all logic will remain client-sided, in one centralised LocalScript (would also be
typically split into multiple modules).
]]
--[[
Ghost-Step Ability Lifecycle:
1. Initialization: Create ability instance, cache template references, link to input
2. Input Requested: Detect keypress
3. CanActivate: Verify ability is ready and conditions are met
4. Target Resolution: Raycast to determine valid dash endpoint
5. Impact Frame: Short pause before dash for anim/brief effect
6. Dash Execution: Lerp character to target, spawn ghost trail
7. Dash Completion: Snap character to final position, restore movement
8. Ability End: Mark ability inactive, cleanup ghost parts, fire AbilityEnded signal
9. Cleanup/Recovery: Ensure all temporary objects/connections are cleared
]]

--========================================================
-- Services & Dependencies
--========================================================
-- Caches all Roblox services needed by the ability
-- Makes code cleaner, avoids repeated calls and centralises references for easy maintenance
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
--========================================================
-- Constants & Configuration
--========================================================
-- Centralises all constants and configuration variables
-- Allows for easy changing of values, especially for testing, and improves readability and maintenance

-- CONFIGURABLE VALUES
local DASH_COOLDOWN = 1 -- number, seconds until player can dash again
local MAX_DASH_DISTANCE = 100 -- number, maximum distance in studs a dash can travel
local DASH_DURATION = 0.2 -- number, seconds for dash
local IMPACT_FRAME_DURATION = 0.2 -- number, seconds for impact frame
local GHOST_FADE_SPEED = 1 -- number, the rate at which ghost parts fade after dash
local STARTING_GHOST_TRANSPARENCY = 0.4 -- number, starting ghost part transparency
local SNAPSHOT_PARENT = ReplicatedStorage.GhostSnapshots -- folder, where object pool stores available models
local SNAPSHOT_INTERVAL = 0.05 -- number, time between each snapshot generation
local MAX_GHOSTS = 10 -- number, max parts in object pool
local GHOST_COLLISION_GROUP_NAME = "GhostVisuals" -- string, name of collision group for ghost visuals
local ABILITY_HOTKEY = Enum.KeyCode.E -- Enum.KeyCode, the hotkey to start ability checks

-- TWEENS
local FADE_INFO = TweenInfo.new(GHOST_FADE_SPEED, Enum.EasingStyle.Linear)

-- PHYSICS
-- This has to happen on the server (it does in another script) but is here to show the process of it happening
--PhysicsService:RegisterCollisionGroup(GHOST_COLLISION_GROUP_NAME)
--PhysicsService:CollisionGroupSetCollidable(GHOST_COLLISION_GROUP_NAME, "Default", false)
--PhysicsService:CollisionGroupSetCollidable(GHOST_COLLISION_GROUP_NAME, GHOST_COLLISION_GROUP_NAME, false)

-- RAYCAST
local OFFSET_DISTANCE = 2
local DOT_THRESHOLD = 0.6
local MAX_DROP_DISTANCE = 30

-- EFFECTS
local EffectsFolder = ReplicatedStorage.Effects
local DarkFlash = EffectsFolder.DarkFlash
local LightFlash = EffectsFolder.LightFlash
--local AnimationId = "rbxassetid://125115673093578"
local AnimationId = "rbxassetid://102031021896528"

--========================================================
-- Utility Functions
--========================================================
-- Contains small, reusable helper functions not tied to a specific system or object
-- Encapsulate common logic to keep main ability code clean, readable, and
-- focused on behaviour rather than details

-- Function takes in a model and a character model and creates a 'snapshot' of the character on the new model
-- Used to separate concerns from object pool to keep code focused and readable
local function captureSnapshot(model: Model, character: Model)
	if not character and character.Parent then return end
	-- Loop through model and capture the CFrame of each part that is also inside the character
	for _, part in ipairs(model:GetChildren()) do -- iPairs not pairs
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.Transparency = STARTING_GHOST_TRANSPARENCY
			if part.Name ~= "HumanoidRootPart" then part.CollisionGroup = GHOST_COLLISION_GROUP_NAME end -- Prevents snapshots colliding with player
			local charPart = character:FindFirstChild(part.Name)
			if charPart then
				part.CFrame = charPart.CFrame
			end
		end
	end
end

-- Function takes in a ColourCorrectionEffect and 'flashes' it on the players screen before linking it to a trove for cleanup
-- Used as a generic effect function that would be stored in a lighting effects utility
local function flashImpactFrame(trove, effectTemplate: ColorCorrectionEffect)
	local effect = effectTemplate:Clone()
	effect.Parent = game.Lighting
	effect.Enabled = true
	task.delay(IMPACT_FRAME_DURATION, function()
		effect.Enabled = false
		trove:Add(effect)
	end)
end

-- Function takes in a trove for cleanup and loads an animation onto the player's character
local function playAnimation(trove, character: Model): AnimationTrack
	if not character then return end
	local humanoid = character:WaitForChild("Humanoid")
	local animator: Animator = humanoid:WaitForChild("Animator")

	-- Create new animation instance
	local dashAnim = Instance.new("Animation")
	dashAnim.AnimationId = AnimationId

	local dashAnimTrack = animator:LoadAnimation(dashAnim)
	dashAnimTrack:Play(0.1)

	trove:Add(dashAnimTrack)
	return dashAnimTrack
end

-- Function to 'pulse' the FOV of the player's camera in a smooth tween
-- Used to make the dash feel more fulfilling and boost the UX
local function pulseFOV(camera: Camera, pulseAmount, duration)
	local originalFOV = camera.FieldOfView
	local targetFOV = originalFOV + pulseAmount
	
	-- Tween to increased FOV
	local tweenIn = TweenService:Create(
		camera,
		TweenInfo.new(duration*0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{FieldOfView = targetFOV}
	)
	-- Tween to original FOV
	local tweenOut = TweenService:Create(
		camera,
		TweenInfo.new(duration*0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{FieldOfView = originalFOV}
	)
	
	tweenIn:Play()
	tweenIn.Completed:Connect(function()
		tweenOut:Play()
	end)
end

-- Handles camera effects during a dash
local function dashScreenEffects(camera)
	-- FOV pulse out for speed
	pulseFOV(camera, 10, 0.25)

	-- Slight camera shake at the END of dash (impact frame)
	task.spawn(function()
		task.wait(DASH_DURATION - 0.05) -- Just before landing
		local originalCF = camera.CFrame
		for i = 1, 3 do
			local shake = CFrame.new( -- Random shake positions
				math.random(-20, 20) / 100,
				math.random(-20, 20) / 100,
				0
			)
			camera.CFrame = originalCF * shake
			task.wait(0.02)
		end
		camera.CFrame = originalCF
	end)
end

-- Simple function that sets the transparency of the character and fades it in and out
-- Used to create a 'ghost'-like effect on the player
local function shadowFade(character, duration)
	if not character then return end
	
	local parts = {}
	local decals = {}
	
	-- Store original transparencies
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Transparency < 1 then
			parts[descendant] = descendant.Transparency
		elseif descendant:IsA("Decal") then
			decals[descendant] = descendant.Transparency
		end
	end
	
	-- Fade out heavily (80-90% of the duration)
	local fadeOutDuration = duration * 0.15
	local fadeOut = TweenInfo.new(fadeOutDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	
	for part, originalTrans in pairs(parts) do
		local tween = TweenService:Create(part, fadeOut, 
			{Transparency = 0.95}) -- Almost invisible
		tween:Play()
	end
	
	for decal, originalTrans in pairs(decals) do
		local tween = TweenService:Create(decal, fadeOut, 
			{Transparency = 0.95})
		tween:Play()
	end
	
	-- Quick snap back (15-20% of the duration)
	task.wait(fadeOutDuration)
	
	local fadeInDuration = duration * 0.85
	local fadeIn = TweenInfo.new(fadeInDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	
	for part, originalTrans in pairs(parts) do
		TweenService:Create(part, fadeIn, {Transparency = originalTrans}):Play()
	end
	
	for decal, originalTrans in pairs(decals) do
		TweenService:Create(decal, fadeIn, {Transparency = originalTrans}):Play()
	end
end

-- Simple functions used to visualise raycast line and point of impact whilst debugging
local function createRayLine(origin, direction): BasePart
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(0.1, 0.1, direction.Magnitude)
	part.CFrame = CFrame.lookAt(origin, origin + direction) * CFrame.new(0, 0, -direction.Magnitude/2)
	part.Parent = workspace
	return part
end
local function createDebugPart(cframe: CFrame): BasePart
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(1,2,1)
	part.CFrame = cframe
	part.Parent = workspace
	return part
end

--========================================================
-- Signal Implementation
--========================================================
-- Implements a lightweight Signal pattern to allow different parts of the script to
-- communicate through events without tight coupling. Used to represent state changes
-- such as ability start, end, or cleanup, demonstrating an understanding of event-driven architecture
-- Inspired by the common Signal modules used in Roblox development but custom made for simplicity
local Signal = {}
Signal.__index = Signal

function Signal.new()
	local self = setmetatable({}, Signal)
	self.listeners = {}
	self.isDestroyed = false
	
	return self
end

function Signal:Connect(callback: ()->()): {Callback: ()->(), Connected: boolean, Disconnect: ()->()}
	if self.isDestroyed == true then return end
	if typeof(callback) ~= "function" then return end -- Cannot accept callbacks that arent a function

	local connection = { -- Store info in a simple connection table
		Callback = callback,
		Connected = true,
	}
	connection.Disconnect = function()
		if connection.Connected == false then return end
		if self.isDestroyed then return end
		connection.Connected = false
	end
	table.insert(self.listeners, connection)
	return connection
end

function Signal:Fire(...)
	if self.isDestroyed == true then return end
	-- Fire every connection. If connection has a callback then call it with the passed arguments
	for _, connection in ipairs(self.listeners) do
		if connection.Connected == false then continue end
		connection.Callback(...)
	end
end

function Signal:Destroy()
	self.isDestroyed = true
	if self.listeners then
		for _, listener in ipairs(self.listeners) do
			-- Uncouple events linked to listener
			listener.Disconnect()
		end
	end
	self.listeners = {}
end

--========================================================
-- Cleanup / Trove Implementation
--========================================================
-- Implements a simple Trove-style cleanup system responsible for tracking temporary objects,
-- connections, and resources created during the ability lifecycle. Centralising cleanup
-- prevents memory leaks, and keeps the ability safe to reuse
-- Inspired by the classic Trove module but modified for simplicity
local Trove = {}
Trove.__index = Trove

function Trove.new()
	return setmetatable({
		_resources = {},
		_isDestroyed = false
	}, Trove)
end

function Trove:Add(resource)
	if self._isDestroyed then
		-- Auto-destroy any new resources if Trove is already destroyed
		if resource.Destroy then
			resource:Destroy()
		elseif resource.Disconnect then
			resource:Disconnect()
		end
		return
	end
	table.insert(self._resources, resource)
	return resource
end

function Trove:Clean()
	if self._isDestroyed then return end

	for _, resource in ipairs(self._resources) do
		-- Clean the most types of instance
		if typeof(resource) == "RBXScriptConnection" then
			resource:Disconnect()
		elseif type(resource) == "table" and resource.Destroy then
			resource:Destroy()
		elseif resource:IsA("BasePart") and resource.Destroy then
			resource:Destroy()
		elseif type(resource) == "function" then
			resource()
		end
	end

	table.clear(self._resources)
end

function Trove:Destroy()
	if self._isDestroyed then return end
	self._isDestroyed = true
	self:Clean()
end

--========================================================
-- Object Pool (Ghost Trail Parts)
--========================================================
-- Manages an object pool for ghost trail parts used during the dash.
-- Parts are reused instead of recreated to reduce allocation overhead and avoid performance
-- spikes, with optimisation and runtime efficiency in mind
local ObjectPool = {}
ObjectPool.__index = ObjectPool

function ObjectPool.new(template: Model)
	local self = setmetatable({}, ObjectPool)
	
	self.template = template
	self.available = {}
	self.inUse = {}
	self.size = MAX_GHOSTS
	
	for i = 1, self.size do
		local clone = template:Clone()
		clone.Name = "GhostSnapshot_"..i
		clone.Parent = SNAPSHOT_PARENT
		table.insert(self.available, clone)
	end
	
	return self
end
-- Take an object out of the pool to simulate creation of new parts
function ObjectPool:Checkout()
	if #self.available == 0 then
		-- Nothing available in object pool
		return
	end
	local object = table.remove(self.available, 1)
	table.insert(self.inUse, object)
	self:_resetObject(object)
	return object
end
-- Return an object back into the available pool for later use
function ObjectPool:Release(object: Model)
	if not table.find(self.inUse, object) then
		return
	end
	local index = table.find(self.inUse, object)
	if index then
		table.remove(self.inUse, index)
		table.insert(self.available, object)
	end
end
-- Resets the Transparency, CFrame and visibility of models in pool
function ObjectPool:_resetObject(object: Model)
	for _, part in ipairs(object:GetDescendants()) do
		if not part:IsA("BasePart") then continue end
		part.Transparency = 1
		part.CFrame = CFrame.new()
		part.CanCollide = false
		part.Anchored = true
	end
end

--========================================================
-- Base Ability Class
--========================================================
-- Defines the BaseAbility class, which stores information about the ability
-- Responsible for CanActivate checks and shared lifecycle logic that gets updated/added to
-- in the Ghost-Step Ability
local BaseAbility = {}
BaseAbility.__index = BaseAbility

function BaseAbility.new()
	local self = setmetatable({}, BaseAbility)
	-- State
	self.active = false
	self.onCooldown = false
	self.lastActivationTime = 0
	-- Troves
	self._lifetimeTrove = Trove.new()
	self._sessionTrove = Trove.new()
	-- Signals (lifetime)
	self.Activated = Signal.new()
	self.Deactivated = Signal.new()
	self.Destroyed = Signal.new()
	
	self._lifetimeTrove:Add(self.Activated)
	self._lifetimeTrove:Add(self.Deactivated)
	self._lifetimeTrove:Add(self.Destroyed)
	
	return self
end

-- Simple activation check
function BaseAbility:CanActivate()
	if self.active then
		return false
	end
	if self.onCooldown then
		return false
	end
	return true
end

function BaseAbility:Activate()
	-- 3.CanActivate check
	if not self:CanActivate() then
		return false
	end
	self.active = true
	self.lastActivationTime = os.clock()
	-- Clean previous session
	self._sessionTrove:Clean()
	
	self.Activated:Fire()
	-- Call subclass hook
	if self.OnActivated then
		self:OnActivated(self._sessionTrove)
	end
	return true
end

function BaseAbility:Deactivate()
	-- 8: Ability End
	if not self.active then return end
	self.active = false
	
	if self.OnDeactivated then
		self:OnDeactivated()
	end
	-- 9: Ability Cleanup/Recovery
	self._sessionTrove:Clean() -- Removes temporary connections and instances
	self.Deactivated:Fire()
end

-- Clears up all lifetime connections and fires a final signal
function BaseAbility:Destroy()
	if self.active then
		self:Deactivate() -- Force deactivates to prevent destroyed ability being still active
	end
	self.Destroyed:Fire()
	self._sessionTrove:Destroy() -- Clean everything + destroy troves
	self._lifetimeTrove:Destroy()
end

--========================================================
-- Ghost-Step Ability
--========================================================
-- Defines the GhostStep class and related functions, which inherits from BaseAbility
-- Contains all dash-specific logic: target resolution, impact frame, dash execution,
-- ghost trail management, and cleanup. Each lifecycle step is clearly separated
-- to maintain readability and demonstrate understanding of ability design

-- GhostStep functions: In a full system these functions would be within the class itself, not as local functions

-- 4.Target Resolution
-- Raycast function to determine the player's intent when trying to dash, and returning a CFrame
local function resolveTarget(sessionTrove, player: Player, character: Model): CFrame?
	-- Sanity checks
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	-- Make sure the player cannot click on themselves, but rather through themselves
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { character }
	
	local mouse = player:GetMouse()
	local camera = workspace.CurrentCamera
	
	-- Screen intent ray
	-- Cast a ray from the camera through the cursor to determine where the player is aiming
	local unitRay = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local intentResult = workspace:Raycast(
		unitRay.Origin,
		unitRay.Direction * MAX_DASH_DISTANCE,
		params
	)
	-- Store the point the player is aiming at (either at the hit point or max distance in that direction)
	local intentPoint = intentResult
		and intentResult.Position
		or (unitRay.Origin + unitRay.Direction * MAX_DASH_DISTANCE)
		
	-- If we hit something with the screen ray, try to dash directly to that surface
	if intentResult then
		local surfaceNormal = intentResult.Normal
		local up = Vector3.new(0, 1, 0)
		-- Calculate how aligned the surface is with up
		local dot = surfaceNormal:Dot(up)
		
		-- If surfae is flat enough to stand on, dash directly to it
		if dot >= DOT_THRESHOLD then
			-- Offset slightly above to prevent clipping through
			local landingPoint = intentResult.Position + Vector3.new(0, 0.1, 0)
			
			-- Verify it's within dash distance from player
			local distanceToSurface = (landingPoint - hrp.Position).Magnitude
			if distanceToSurface <= MAX_DASH_DISTANCE then
				return CFrame.new(landingPoint)
			end
		end
	end
		
	-- If a direct surface wasn't found use forward dash with collision
	-- Start slightly above hrp to avoid ground clipping
	local origin = hrp.Position + Vector3.new(0, 1, 0)
	local toIntent = intentPoint - origin
	local dashDirection = toIntent.Unit
	local dashDistance = math.min(toIntent.Magnitude, MAX_DASH_DISTANCE) -- Clamp to max allowed distance

	-- Use Shapecast instead of Raycast to prevent getting stuck between parts
	local forwardResult = workspace:Spherecast(
		origin, 
		0.5, -- Small sphere radius to detect gaps
		dashDirection * dashDistance, 
		params
	)
	
	local dashPoint
	
	if forwardResult then
		-- Hit a wall, position dash endpoint away from it
		local normalOffset = forwardResult.Normal * (OFFSET_DISTANCE + 0.5) -- Extra padding
		dashPoint = forwardResult.Position + normalOffset
		
		-- Additional clearance check with spherecast
		local horizontalNormal = Vector3.new(forwardResult.Normal.X, 0, forwardResult.Normal.Z)
		if horizontalNormal.Magnitude > 0.1 then
			horizontalNormal = horizontalNormal.Unit
			local clearanceCheck = workspace:Spherecast(
				dashPoint,
				0.5,
				horizontalNormal * OFFSET_DISTANCE,
				params
			)
			if clearanceCheck then
				-- Push out more if still too close
				dashPoint = dashPoint + horizontalNormal * (OFFSET_DISTANCE * 2)
			end
		end
	else
		-- No obstruction so go full distance
		dashPoint = origin + dashDirection * dashDistance
	end
	
	-- Now find a valid landing surface below the dash endpoint
	-- Downward landing with improved surface detection
	local DOWN_START_OFFSET = 3.0 -- Increased to better catch surfaces above
	local downOrigin = dashPoint + Vector3.new(0, DOWN_START_OFFSET, 0)
	local totalDownDistance = MAX_DROP_DISTANCE + DOWN_START_OFFSET
	
	-- Use spherecast for downward detection
	local downResult = workspace:Spherecast(
		downOrigin, 
		0.3, -- Smaller sphere for tighter detection
		Vector3.new(0, -totalDownDistance, 0), 
		params
	)
	
	-- If a steep surface is hit then keep searching for flat landing
	local attempts = 0
	local maxAttempts = 5
	
	while downResult and attempts < maxAttempts do
		local up = Vector3.new(0, 1, 0)
		local dot = downResult.Normal:Dot(up)
		
		-- Valid surface found
		if dot >= DOT_THRESHOLD then
			break
		end
		
		-- Hit a steep surface, continue searching below
		attempts = attempts + 1
		local newOrigin = downResult.Position + Vector3.new(0, -0.3, 0)
		local remainingDistance = totalDownDistance - (downOrigin.Y - newOrigin.Y)
		-- Stop if we run out of search distance
		if remainingDistance <= 0 then
			downResult = nil
			break
		end
		-- Cast again from new position
		downResult = workspace:Spherecast(
			newOrigin,
			0.3,
			Vector3.new(0, -remainingDistance, 0),
			params
		)
	end
		
	if not downResult then
		--warn("No valid landing surface found within drop distance")
		return false
	end
	
	-- Final slope validation
	local up = Vector3.new(0, 1, 0)
	local dot = downResult.Normal:Dot(up)
	if dot < DOT_THRESHOLD then
		warn(`All surfaces too steep. Final dot: {dot}, Normal: {downResult.Normal}`)
		return CFrame.new()
	end
	
	-- Verify the landing isn't too far below dash endpoint
	local actualDrop = dashPoint.Y - downResult.Position.Y
	if actualDrop > MAX_DROP_DISTANCE then
		warn(`Drop too far: {actualDrop} studs (max: {MAX_DROP_DISTANCE})`)
		return CFrame.new()
	end
	
	-- Valid landing found
	return CFrame.new(downResult.Position + Vector3.new(0, 0.1, 0))
end

-- Simple Tween function to fade out a model
local function applyFade(snapshot: Model, sessionTrove)
	for _, part in ipairs(snapshot:GetChildren()) do
		if part:IsA("BasePart") then
			local fadeTween = TweenService:Create(part, FADE_INFO, {Transparency = 1})
			fadeTween:Play()
			sessionTrove:Add(fadeTween)
		end
	end
end

-- Instantiates a snapshot from an object pool to be a snapshot of the player
local function spawnGhostSnapshot(self, sessionTrove, snapshot: Model)
	local player = self.player or Players.LocalPlayer
	local character = player.Character
	-- Sanity checks so snapshots don't throw errors
	if not character then warn("No character found") return end
	captureSnapshot(snapshot, character) -- Captures player's current positions
	snapshot.Parent = workspace.Snapshots
	applyFade(snapshot, sessionTrove) -- Apply fade to the snapshot over time
end

-- Function lerps the character smoothly to the position returned by resolveTarget
-- Uses lerp over Tween because it gives more precise control and smooth but quick movement
local function moveCharacter(self, player: Player, sessionTrove, endPos: CFrame)
	-- Sanity checks to verify the lerp won't error
	local character = player.Character
	if not character then return end
	local hrp: BasePart = character:WaitForChild("HumanoidRootPart")
	if not hrp then return end
	local humanoid = character:WaitForChild("Humanoid")
	if not humanoid then return end
	
	local startPos = hrp.CFrame -- Moving from player's current CFrame
	-- Calculate dash direction
	local dashDirection = (endPos.Position - startPos.Position)
	-- Recalculate endPos with clamped dir
	endPos = startPos + dashDirection
	-- Store Y target before adding HipHeight
	local targetY = endPos.Position.Y
	
	endPos = endPos + Vector3.new(0, humanoid.HipHeight, 0) -- Stops drifting underground
	endPos = CFrame.new(endPos.Position) * (startPos - startPos.Position) -- Keep rotation
	
	local startTime = tick()
	local nextSnapshotTime = 0
	
	while tick() - startTime < DASH_DURATION do
		local elapsed = tick() - startTime
		local alpha = elapsed / DASH_DURATION
		
		if elapsed >= nextSnapshotTime then
			-- Manage ghost snapshots: only spawn at certain intervals to create an 'imprint' of the player's dash
			-- Checks out an item from object pool if available then releases it after use
			nextSnapshotTime += SNAPSHOT_INTERVAL
			local snapshot = self._ghostPool:Checkout()
			spawnGhostSnapshot(self, sessionTrove, snapshot)
			self._ghostPool:Release(snapshot)
		end
		
		-- Lerp X and Z horizontally
		local lerpedX = startPos.Position.X + (endPos.Position.X - startPos.Position.X) * alpha
		local lerpedZ = startPos.Position.Z + (endPos.Position.Z - startPos.Position.Z) * alpha
		
		-- Lerp Y separately, but never go below end Y. Y is separate because it can cause issues with dipping underground
		-- And needs more contraint than just X and Z
		local lerpedY = startPos.Position.Y + (endPos.Position.Y - startPos.Position.Y) * alpha
		lerpedY = math.max(lerpedY, targetY) -- Make sure it takes the highest end point to prevent dipping
		
		local lerpedPos = Vector3.new(lerpedX, lerpedY, lerpedZ)
		
		-- Keep original rotation
		-- Equivalent of doing :Lerp() but following the math instead of using the Roblox function
		hrp.CFrame = CFrame.new(lerpedPos) * (startPos - startPos.Position)
		task.wait()
	end
end

-- GhostStep Class
local GhostStep = {}
GhostStep.__index = GhostStep
setmetatable(GhostStep, BaseAbility) -- inheritance link between GhostStep and generic BaseAbility class

function GhostStep.new(template: Model, player: Player)
	local self = setmetatable(BaseAbility.new(), GhostStep)
	self._ghostPool = ObjectPool.new(template) -- Available Ghost snapshots for the ability
	self._dashAnimationTrack = nil
	self.player = player
	return self
end

function GhostStep:CanActivate()
	if not BaseAbility.CanActivate(self) then
		return false
	end
	-- Can add any custom functionality into here
	-- Example, player cant ability whilst in the air
	--if self.character.Humanoid.FloorMaterial == Enum.Material.Air then
	--	return false
	--end
	return true
end

function GhostStep:OnActivated(sessionTrove)
	-- Get fresh player + character reference
	local player = self.player or game.Players.LocalPlayer
	local character = player.Character or player.CharacterAdded:Wait()
	-- 4: Target Resolution
	local target = resolveTarget(sessionTrove, player, character)
	if typeof(target) == "boolean" then -- Only will be so if resolveTarget returns false (encountered an error)
		return
	end
	-- 5: Impact Frame and Effects
	task.spawn(function()
		local dashAnimTrack = playAnimation(sessionTrove, character)
		self._dashAnimationTrack = dashAnimTrack
		shadowFade(character, 0.5) -- Character transparency pulse
		flashImpactFrame(sessionTrove, DarkFlash) -- Impact effect
		dashScreenEffects(workspace.CurrentCamera) -- Camera effect to give immersive effect to dash
	end)
	-- 6: Dash Execution
	moveCharacter(self, player, sessionTrove, target)
end

function GhostStep:OnDeactivated()
	-- 7: Dash Completion
	-- Called when the dash ends. Exists to finalize or correct ability-specific state.
	-- Currently minimal because cleanup is handled by BaseAbility via Trove.
	if self._dashAnimationTrack then
		self._dashAnimationTrack:Stop()
		self._dashAnimationTrack = nil
	end
end

--========================================================
-- Input Binding & Ability Controller
--========================================================
-- Binds user input to ABILITY_HOTKEY to start the ability lifecycle
-- Handles activation requests to easily initialise the rest of the cycle whilst abstracting validation, etc.
-- to keep the other sections more readable and focused on their purpose

local function BindInput(ghostStep)
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		-- 2.Input Requested
		if input.KeyCode == ABILITY_HOTKEY then
			ghostStep:Activate()
			task.wait(0.5)
			ghostStep:Deactivate()
		end
	end)
	-- Example usage of the custom signals created earlier to focus on event-driven design
	-- Prevents user from spamming ability, which could cause bugs and unwanted behaviour
	ghostStep.Deactivated:Connect(function()
		ghostStep.onCooldown = true
		task.delay(DASH_COOLDOWN, function()
			ghostStep.onCooldown = false
		end)
	end)
	ghostStep.Activated:Connect(function()
		-- Could link to external systems for extra effects, e.g.
		--SoundUtil.PlayGhostSound()
	end)
end

--========================================================
-- Demo Bootstrap
--========================================================
-- 1. Initialisation
local player = Players.LocalPlayer
local template = ReplicatedStorage.Template -- Example Ghost template for Ghost snapshots
local ghostStep = GhostStep.new(template, player)
BindInput(ghostStep)
