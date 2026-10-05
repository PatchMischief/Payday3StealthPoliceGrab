-- SilentPoliceRestraints 0.1.0. Native gameplay is experimental until heist-tested.
-- F6: request a rear grab; while holding an admitted officer, request release/tie.
local rules = require("rules")
local PREFIX = "[SilentPoliceRestraints] "
local START_HOOK = "/Script/Starbreeze.SBZInteractorComponent:Server_StartInteraction"
local records, requests, hook_frames = {}, {}, {}
local hooks_ready, queued, key_queued, diagnostics_queued = false, false, false, false
local sequence = 0
local GRAB_TIMEOUT, ACTION_TIMEOUT, HOLD_TIMEOUT = 6, 8, 300

local function log(message) print(PREFIX .. tostring(message) .. "\n") end
local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end
local function read(object, field)
    if object == nil then return nil end
    local ok, result = pcall(function() return object[field] end)
    if ok then return result end
end
local function call(object, method, ...)
    if not valid(object) then return false, nil end
    local args = {...}
    return pcall(function() return object[method](object, table.unpack(args)) end)
end
local function unbox(value)
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end
local function address(object)
    local ok, result = call(object, "GetAddress")
    if ok then return result end
end
local function same(a, b)
    return valid(a) and valid(b) and address(a) ~= nil and address(a) == address(b)
end
local function bool(value) return value == true or value == 1 end
local function name(object)
    local ok, result = call(object, "GetName")
    if ok and type(result) == "string" then return result end
    local text_ok, text = pcall(function() return result:ToString() end)
    if text_ok then return text end
end
local function objects(class_name)
    local ok, result = pcall(FindAllOf, class_name)
    return ok and result or {}
end
local function array_values(array)
    if type(array) == "table" then return array end
    local result = {}
    if array ~= nil then
        pcall(function()
            array:ForEach(function(index, value) result[index] = unbox(value) end)
        end)
    end
    return result
end
local function find(path)
    local ok, object = pcall(StaticFindObject, path)
    if ok and valid(object) then return object end
end
local function now(pawn)
    local library = find("/Script/Engine.Default__GameplayStatics")
    local ok, value = call(library, "GetTimeSeconds", pawn)
    if ok and type(value) == "number" then return value end
    return os.clock()
end
local function world(object)
    local ok, value = call(object, "GetWorld")
    if ok then return value end
end
local function authority(actor)
    local ok, value = call(actor, "HasAuthority")
    return ok and value == true
end
local function is_police(actor)
    local ok, cls = call(actor, "GetClass")
    if not ok then return false end
    for _ = 1, 24 do
        if not valid(cls) then return false end
        if name(cls) == "CH_BaseCop_C" then return true end
        ok, cls = call(cls, "GetSuperStruct")
        if not ok then return false end
    end
    return false
end
local function local_controller()
    for _, controller in pairs(objects("PlayerController")) do
        local ok, local_player = call(controller, "IsLocalPlayerController")
        if ok and local_player == true and valid(read(controller, "Pawn")) then
            return controller, read(controller, "Pawn")
        end
    end
end
local function enum_value(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return value:match("([^:]+)$") end
end
local function mode_index(component, mode)
    for index, value in ipairs(array_values(read(component, "ModeArray"))) do
        value = enum_value(value)
        if value == mode or (mode == 1 and value == "HumanShield") then
            return index - 1 -- UE4SS TArray indices are one-based; the native RPC is zero-based.
        end
    end
end
local function raw_mode(component, index)
    return enum_value(array_values(read(component, "ModeArray"))[index + 1])
end
local function held_by(actor, pawn)
    return bool(read(actor, "bIsCarried")) and same(read(actor, "CurrentCarryInstigator"), pawn)
end
local function has_state(actor, mask)
    local state = read(actor, "HostageState")
    return type(state) == "number" and math.floor(state / mask) % 2 == 1
end
local function position(actor)
    local ok, value = call(actor, "K2_GetActorLocation")
    if ok then return value end
end
local function vector(value)
    local x, y, z = read(value, "X"), read(value, "Y"), read(value, "Z")
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return x, y, z
    end
end
local function snapshot(actor, pawn, controller)
    local result = {
        police = is_police(actor), alive = bool(read(actor, "bIsAlive")),
        player_alive = bool(read(pawn, "bIsAlive")),
    }
    local casing_ok, casing = call(pawn, "IsCasing")
    result.masked = casing_ok and casing == false
    local game_state = read(world(pawn), "GameState")
    local state_ok, state = call(game_state, "GetCurrentHeistState")
    state = enum_value(state)
    result.stealth = state_ok and (state == 0 or state == "Stealth")
    local seen_ok, seen = call(pawn, "IsSeenByAI")
    result.unseen = seen_ok and seen == false
    local ai_controller = read(actor, "Controller")
    local enemy_ok, enemy = call(ai_controller, "GetCurrentEnemy")
    local category = enum_value(read(actor, "CurrentBehaviorCategory"))
    local detection_ok, detection = call(pawn, "GetDetectionData")
    local undetected = detection_ok
    if detection_ok then
        for _, entry in pairs(array_values(detection)) do
            if same(read(entry, "Detector"), actor) or same(read(entry, "Detector"), ai_controller) then
                local amount = read(entry, "Detection")
                if type(amount) ~= "number" or amount > 0 then undetected = false end
            end
        end
    end
    result.unaware = enemy_ok and not valid(enemy) and undetected
        and (category == 1 or category == "Idle") and not valid(read(actor, "CurrentTarget"))
    local interactor = read(pawn, "Interactor")
    local interaction_ok, interaction = call(interactor, "GetCurrentInteraction")
    result.free = interaction_ok and not valid(interaction)
        and not valid(read(pawn, "CurrentCarryActor")) and not bool(read(actor, "bIsCarried"))
        and not bool(read(actor, "bIsBeingHogTied")) and not has_state(actor, 4)
    local sight_ok, sight = call(controller, "LineOfSightTo", actor, {X = 0, Y = 0, Z = 0}, false)
    result.line_of_sight = sight_ok and sight == true and same(world(actor), world(pawn))
    local px, py, pz = vector(position(pawn))
    local ax, ay, az = vector(position(actor))
    local forward_ok, forward = call(actor, "GetActorForwardVector")
    local fx, fy = vector(forward)
    local rotation_ok, rotation = call(controller, "GetControlRotation")
    local yaw = read(rotation, "Yaw")
    if px and ax and forward_ok and fx and rotation_ok and type(yaw) == "number" then
        local dx, dy, dz = px - ax, py - ay, pz - az
        local horizontal = math.sqrt(dx * dx + dy * dy)
        result.distance_cm = math.sqrt(horizontal * horizontal + dz * dz)
        if horizontal > 0 then
            result.behind_dot = (dx * fx + dy * fy) / horizontal
            local radians = math.rad(yaw)
            result.aim_dot = (-dx * math.cos(radians) - dy * math.sin(radians)) / horizontal
        end
    end
    return result
end
local function restore(record)
    if not valid(record.actor) then return end
    local ok, error_message = pcall(function()
        record.actor.bIsValidHumanShield = record.original.valid
        record.actor.HumanShieldData = record.original.data
        record.actor:SetHumanShieldAllowed(record.original.allowed)
        record.actor:SetDownOnGroundAllowed(record.original.down)
    end)
    if not ok then log("Permission restoration failed: " .. tostring(error_message)) end
end
local function finish(record, message)
    restore(record)
    records[record.key] = nil
    if message then log(message) end
end
local function admit(actor, pawn, controller)
    if not authority(pawn) or not authority(actor) then return nil end
    local allowed = rules.can_grab(snapshot(actor, pawn, controller))
    if not allowed then return nil end
    local key = address(actor)
    if key == nil or records[key] then return nil end
    local original = {
        valid = read(actor, "bIsValidHumanShield"), data = read(actor, "HumanShieldData"),
        allowed = read(actor, "bIsHumanShieldAllowed"), down = read(actor, "bIsDownOnGroundAllowed"),
    }
    if original.valid == nil or original.allowed == nil or original.down == nil then return nil end
    original.valid, original.allowed, original.down = bool(original.valid), bool(original.allowed), bool(original.down)
    local shield_data = original.data
    if not valid(shield_data) then shield_data = read(actor, "SurrenderedHumanShieldData") end
    if not valid(shield_data) then return nil end
    local record = {
        key = key, actor = actor, pawn = pawn, world = world(pawn), original = original,
        phase = "grabbing", deadline = now(pawn) + GRAB_TIMEOUT,
    }
    records[key] = record
    local ok = pcall(function()
        actor.HumanShieldData = shield_data -- Per-actor pointer; the shared asset is never edited.
        actor.bIsValidHumanShield = true
        actor:SetHumanShieldAllowed(true)
        actor:SetDownOnGroundAllowed(true)
    end)
    if not ok then finish(record, "Native grab permissions unavailable."); return nil end
    return record
end
local function hook_pre(context, interaction_param, _, mode_param)
    local interactor, interaction = unbox(context), unbox(interaction_param)
    local ok, pawn = call(interactor, "GetOwner")
    if not ok or not authority(pawn) then return end
    local index = unbox(mode_param)
    if type(index) ~= "number" then return end
    local mode = raw_mode(interaction, index)
    if mode ~= 1 and mode ~= "HumanShield" then return end
    local actor_ok, actor = call(interaction, "GetOwner")
    if not actor_ok then return end
    local record = admit(actor, pawn, read(pawn, "Controller"))
    if record then hook_frames[address(interactor)] = record end
end
local function hook_post(context, interaction_param)
    local interactor, interaction = unbox(context), unbox(interaction_param)
    local key = address(interactor)
    local record = hook_frames[key]
    if not record then return end
    hook_frames[key] = nil
    local ok, current = call(interactor, "GetCurrentInteraction")
    if not (ok and same(current, interaction)) and not held_by(record.actor, record.pawn) then
        finish(record, "The game rejected the grab; permissions restored.")
    end
end
local function install_hooks()
    if hooks_ready then return end
    if not find(START_HOOK) then return end
    local ok = pcall(RegisterHook, START_HOOK, hook_pre, hook_post)
    if ok then hooks_ready = true else log("Interaction hook unavailable; F6 is disabled.") end
end
local function push_action(record, path)
    local cls = find(path)
    if not valid(cls) then return false end
    local ok, action = call(read(record.actor, "Controller"), "PushAction", cls, record.pawn)
    return ok and valid(action)
end
local function tick()
    install_hooks()
    for key, request in pairs(requests) do
        if not valid(request.pawn) or not same(world(request.pawn), request.world) then
            requests[key] = nil
        elseif now(request.pawn) >= request.complete_at then
            if not held_by(request.actor, request.pawn) then
                call(request.interactor, "Server_CompleteInteraction", request.component, request.id)
            end
            requests[key] = nil
        end
    end
    for _, record in pairs(records) do
        local alive = valid(record.actor) and valid(record.pawn)
            and bool(read(record.actor, "bIsAlive")) and bool(read(record.pawn, "bIsAlive"))
        if not alive or not same(world(record.pawn), record.world) or not same(world(record.actor), record.world) then
            finish(record)
        elseif now(record.pawn) >= record.deadline then
            finish(record, "Native " .. record.phase .. " timed out; permissions restored.")
        elseif record.phase == "grabbing" then
            if held_by(record.actor, record.pawn) then
                record.phase, record.deadline = "held", now(record.pawn) + HOLD_TIMEOUT
                log("Officer grabbed. Press F6 while holding them to release and restrain.")
            end
        elseif record.phase == "held" then
            if not bool(read(record.actor, "bIsCarried")) and not same(read(record.pawn, "CurrentCarryActor"), record.actor) then
                if push_action(record, "/Script/Starbreeze.SBZAIAction_GetDownOnGround") then
                    record.phase, record.deadline = "going down", now(record.pawn) + ACTION_TIMEOUT
                else finish(record, "The game rejected the get-down action.") end
            elseif bool(read(record.actor, "bIsCarried")) and not held_by(record.actor, record.pawn) then
                finish(record, "Officer transferred; request cancelled.")
            end
        elseif record.phase == "going down" then
            if has_state(record.actor, 2) or bool(read(record.actor, "bIsInDownOnGroundPose")) then
                if push_action(record, "/Script/Starbreeze.SBZAIAction_HogTie") then
                    record.phase, record.deadline = "tying", now(record.pawn) + ACTION_TIMEOUT
                else finish(record, "The game rejected the restraint action.") end
            end
        elseif record.phase == "tying" and has_state(record.actor, 4) then
            finish(record, "Officer restrained (native hostage state confirmed).")
        end
    end
end
local function shove(pawn)
    for _, ability in pairs(objects("GA_HumanShieldShove_C")) do
        local ok, cls = call(ability, "GetClass")
        if ok and valid(cls) then
            local activated, result = call(read(pawn, "AbilitySystem"), "TryActivateAbilityByClass", cls, true)
            return activated and result == true
        end
    end
    return false
end
local function action()
    install_hooks()
    if not hooks_ready then log("Native interaction hook not ready."); return end
    local controller, pawn = local_controller()
    if not valid(pawn) then log("Enter a heist first."); return end
    local carried = read(pawn, "CurrentCarryActor")
    if valid(carried) then
        if not is_police(carried) or not held_by(carried, pawn) then
            log("Wait until the officer is fully held."); return
        end
        -- The host only restrains actors admitted by the native start hook.
        if authority(pawn) and not records[address(carried)] then
            log("This officer was not admitted by this mod."); return
        end
        if shove(pawn) then log("Release requested; waiting for the host's native restraint actions.")
        else log("The game rejected release, or its human-shield ability is unavailable.") end
        return
    end
    if requests[address(pawn)] then log("A grab request is already pending."); return end
    local target, component, index, nearest, nearest_failure = nil, nil, nil, math.huge, math.huge
    local reason = "No eligible unnoticed officer nearby."
    for _, cop_controller in pairs(objects("BP_CopController_C")) do
        local actor = read(cop_controller, "Pawn")
        if valid(actor) and same(world(actor), world(pawn)) then
            local state = snapshot(actor, pawn, controller)
            local eligible, failure = rules.can_grab(state)
            local interaction = read(actor, "Interactable")
            local candidate_index = mode_index(interaction, 1)
            local distance = state.distance_cm or math.huge
            if eligible and candidate_index ~= nil and distance < nearest then
                nearest, target, component, index = distance, actor, interaction, candidate_index
            elseif distance < nearest_failure then
                nearest_failure = distance
                reason = eligible and "The game has no human-shield mode on this officer." or failure
            end
        end
    end
    if not target then log(reason); return end
    local interactor = read(pawn, "Interactor")
    sequence = (sequence + 1) % 1000000
    local id = read(interactor, "InteractId")
    if type(id) ~= "number" then log("Native interaction id unavailable."); return end
    id = id + sequence
    local ok = call(interactor, "Server_StartInteraction", component, id, index)
    if not ok then log("Native grab request failed."); return end
    local duration = read(component, "Duration")
    if type(duration) ~= "number" or duration < 0 or duration > ACTION_TIMEOUT then
        call(interactor, "Server_StopInteraction", component)
        log("Native interaction duration unavailable; request cancelled."); return
    end
    requests[address(pawn)] = {
        pawn = pawn, actor = target, world = world(pawn), component = component,
        interactor = interactor, id = id, complete_at = now(pawn) + duration + 0.1,
    }
    log("Grab requested through the game's interaction system.")
end
local function diagnostics()
    local _, pawn = local_controller()
    local count = 0
    for _ in pairs(records) do count = count + 1 end
    log("0.1.0; hook=" .. tostring(hooks_ready) .. "; player=" .. tostring(valid(pawn))
        .. "; authority=" .. tostring(authority(pawn)) .. "; managed=" .. tostring(count))
    for _, record in pairs(records) do log((name(record.actor) or "officer") .. ": " .. record.phase) end
end
local function queue(callback, done)
    ExecuteInGameThread(function()
        local ok, message = pcall(callback)
        if done then done() end
        if not ok then log("Adapter error: " .. tostring(message)) end
    end)
end
RegisterKeyBind(Key.F6, function()
    if key_queued then return end
    key_queued = true
    queue(action, function() key_queued = false end)
end)
RegisterKeyBind(Key.F8, function()
    if diagnostics_queued then return end
    diagnostics_queued = true
    queue(diagnostics, function() diagnostics_queued = false end)
end)
LoopAsync(100, function()
    if not queued then
        queued = true
        queue(tick, function() queued = false end)
    end
    return false
end)
log("Loaded experimental 0.1.0. F6 grabs/releases an officer; F8 reports native state.")

-- Returning entry points lets the adapter be exercised without a game process.
return {request_action = action, tick = tick, diagnostics = diagnostics, managed = records}
