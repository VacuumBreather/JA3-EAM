local old_GenerateRouteDijkstra = GenerateRouteDijkstra

function GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    -- We override the global GetSectorTravelTime temporarily during this call
    local old_GetSectorTravelTime = GetSectorTravelTime
    
    -- Define a local override that adds pathfinding-only costs
    local pathfinding_GetSectorTravelTime = function(from, to, ...)
        local time, t1, t2, breakdown = old_GetSectorTravelTime(from, to, ...)
        
        -- Check if 'time' is valid (not false/nil)
        if time then
            -- CUSTOM LOGIC: High cost for enemy pathfinding through player/militia sectors
            local is_enemy = side == "enemy1" or side == "diamonds"
        
            if is_enemy and time and to then
                -- 1. Check for physical presence of player/allied squads
                -- We exclude travelling squads as they aren't "in" the sector to block it effectively
                local player_squads = GetSquadsInSector(to, true, false, true, true)
                local has_player_squads = #player_squads > 0
                
                -- 2. Check for physical presence of militia
                local has_militia = GetSectorMilitiaCount(to) > 0

                local factor = 0

                if has_player_squads then
                    factor = factor + 100
                end

                if has_militia then
                    factor = factor + 100
                end
                
                -- If player mercs OR militia are present, apply the penalty
                if to ~= end_sector and (has_player_squads or has_militia) then
                    -- Multiply cost by 20 to make the AI path around the threat
                    time = time * factor
                end
            end
        end
        
        return time, t1, t2, breakdown
    end

    -- Swap the function globally for the duration of the Dijkstra execution
    GetSectorTravelTime = pathfinding_GetSectorTravelTime
    
    -- Execute the original pathfinding logic with our modified weights
    local route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    
    -- Restore the original function immediately so actual movement/UI is unaffected
    GetSectorTravelTime = old_GetSectorTravelTime
    
    return route
end

-- This message is triggered whenever a sector changes ownership (e.g., Legion -> Player)
function OnMsg.SectorSideChanged(sector_id, old_side, new_side)
    -- Trigger a recalculation of all valid diamond shipment routes
    -- This ensures the 'weight' of routes is updated based on new ownership
    if GenerateDynamicDBPathCache then
        GenerateDynamicDBPathCache()
    end
end