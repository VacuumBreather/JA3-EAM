function ApplyPathfindingPenalty(old_GetSectorTravelTime, side, end_sector)
    return function(from, to, ...)
        local time, t1, t2, breakdown = old_GetSectorTravelTime(from, to, ...)
        
        -- Check if 'time' is valid (not false/nil)
        if time then
            -- CUSTOM LOGIC: High cost for enemy pathfinding through player/militia sectors
            local is_enemy = side == "enemy1" or side == "diamonds"
            
            if is_enemy and to then
                -- 1. Check for physical presence of player/allied squads
                -- We exclude travelling squads as they aren't "in" the sector to block it effectively
                local player_squads = GetSquadsInSector(to, true, false, true, true)
                local has_player_squads = #player_squads > 0
                
                -- 2. Check for physical presence of militia
                local has_militia = GetSectorMilitiaCount(to) > 0
                
                -- If player mercs OR militia are present, apply the penalty
                -- Do not apply it if the sector is the final destination (to allow attacks)
                if to ~= end_sector and (has_player_squads or has_militia) then
                    time = 2500000
                end
            end
        end
        
        return time, t1, t2, breakdown
    end
end

local old_GenerateRouteDijkstra = GenerateRouteDijkstra

function GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    local old_GetSectorTravelTime = GetSectorTravelTime
    GetSectorTravelTime = ApplyPathfindingPenalty(old_GetSectorTravelTime, side, end_sector)
    
    local route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    
    GetSectorTravelTime = old_GetSectorTravelTime

    if not route then
        print("ATTENTION: Alt-Route necessary (GenerateRouteDijkstra)")
        route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    end
    
    return route
end

local old_GenerateRouteDijkstraSimplified = GenerateRouteDijkstraSimplified

function GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)
    local old_GetSectorTravelTime = GetSectorTravelTime
    GetSectorTravelTime = ApplyPathfindingPenalty(old_GetSectorTravelTime, side, end_sector)
    
    local route = old_GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)
    
    GetSectorTravelTime = old_GetSectorTravelTime

    if not route then
        print("ATTENTION: Alt-Route necessary (GenerateRouteDijkstraSimplified)")
        route = old_GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)
    end
    
    return route
end

Queue = {}
function Queue.new()
    return { first = 1, last = 0 }
end

function Queue.put(queue, value)
    local last = queue.last + 1
    queue.last = last
    queue[last] = value
end

function Queue.pop(queue)
    local first = queue.first
    if first > queue.last then print("[ERROR]: Queue is empty") end
    local value = queue[first]
    queue[first] = nil
    queue.first = first + 1

    return value
end

function Queue.empty(queue)
    return queue.first > queue.last
end

Set = {}
function Set.new()
    return {}
end

function Set.add(set, value)
    print(string.format("Set.add: %s", tostring(value)))
    set[value] = true
end

function Set.contains(set, value)
    return set[value]
end

Path = { first = 1, last = 1 }



local function BreadthFirstSearch(from, getNeighbours)
    local count = 1
    local frontier = Queue.new()
    Queue.put(frontier, from)
    local came_from = { [from] = "NONE" }

    while not Queue.empty(frontier) do
        local current = Queue.pop(frontier)

        for next, _ in pairs(getNeighbours(current)) do
            if not came_from[next] then
                Queue.put(frontier, next)
                came_from[next] = current
                count = count + 1
            end
        end
    end

    CombatLog("important", string.format("Checked %d sectors", count))
    print(string.format("Checked %d sectors", count))

    return came_from
end

local function ReconstructPath(from, to, came_from)
    local current = to
    local path = {}

    while current ~= from and current ~= "NONE" do
        path[#path + 1] = current
        current = came_from[current]
    end

    -- Reverse the table
    local n = #path
    for i = 1, math.floor(n / 2) do
        local j = n - i + 1
        path[i], path[j] = path[j], path[i]
    end
    
    CombatLog("important", table.concat(path, " -> "))
    print(table.concat(path, " -> "))
end

local db_cache_dirty = true

function OnMsg.SectorSideChanged()
    db_cache_dirty = true
end

function OnMsg.InitSessionCampaignObjects()
    db_cache_dirty = true

    local came_from = BreadthFirstSearch("A2", GetNeighborSectors)
    ReconstructPath("A2", "F7", came_from)
end

function OnMsg.LoadSessionData()
    db_cache_dirty = true

    local came_from = BreadthFirstSearch("A2", GetNeighborSectors)
    ReconstructPath("A2", "F7", came_from)
end

-- local old_SpawnDynamicDBSquad = SpawnDynamicDBSquad

-- function SpawnDynamicDBSquad(...)
--     if db_cache_dirty then
--         DBRoutesCacheDynamic = nil -- Clear to force rebuild
--         GenerateDynamicDBPathCache()
--         db_cache_dirty = false
--     end
--     return old_SpawnDynamicDBSquad(...)
-- end