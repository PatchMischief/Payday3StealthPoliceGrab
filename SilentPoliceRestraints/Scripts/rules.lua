-- Engine-independent admission policy. Unreal distances are centimetres.
local M = {}
M.MAX_DISTANCE_CM = 160
M.BEHIND_DOT = -0.5 -- Within 60 degrees of directly behind the officer.
M.AIM_DOT = 0.7

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

function M.can_grab(state)
    if type(state) ~= "table" then return false, "State unavailable" end
    local checks = {
        {"police", "Target is not a police officer or security guard"},
        {"alive", "Officer is not alive"},
        {"player_alive", "Player is not alive"},
        {"masked", "Mask up first"},
        {"stealth", "Heist is not in stealth"},
        {"unaware", "Officer is aware or suspicious"},
        {"unseen", "Player is being observed"},
        {"free", "Officer or player is already occupied"},
        {"line_of_sight", "Approach is obstructed"},
    }
    for _, check in ipairs(checks) do
        if state[check[1]] ~= true then return false, check[2] end
    end
    if not finite(state.distance_cm) or state.distance_cm <= 0
        or state.distance_cm > M.MAX_DISTANCE_CM then
        return false, "Move within 1.6 metres of the officer"
    end
    if not finite(state.behind_dot) or state.behind_dot < -1.000001
        or state.behind_dot > M.BEHIND_DOT then
        return false, "Approach from behind"
    end
    if not finite(state.aim_dot) or state.aim_dot > 1.000001
        or state.aim_dot < M.AIM_DOT then
        return false, "Look toward the officer"
    end
    return true, "Ready"
end

return M
