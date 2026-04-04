-- Factory function to create the pathfinding penalty wrapper
function ApplyPathfindingPenalty(old_GetSectorTravelTime, side, end_sector)
    return function(from, to, ...)
        local time, t1, t2, breakdown = old_GetSectorTravelTime(from, to, ...)
        
        if time then
            local is_enemy = side == "enemy1" or side == "diamonds"
            
            if is_enemy and to then
                -- Check for presence of player squads or militia
                local player_squads = GetSquadsInSector(to, true, false, true, true)
                local has_player_squads = #player_squads > 0
                local has_militia = GetSectorMilitiaCount(to) > 0
                
                -- Apply the penalty floor (1,000,000) unless it's the target destination
                if has_player_squads or has_militia then
                    time = 2500000
                end
            end
        end
        
        return time, t1, t2, breakdown
    end
end

-- Wrapper to safely swap the global and execute a function
local function ExecuteWithPathfindingPenalty(side, end_sector, original_func, ...)
    local old_GetSectorTravelTime = GetSectorTravelTime
    local penalty_func = ApplyPathfindingPenalty(old_GetSectorTravelTime, side, end_sector)

    -- Use rawset to bypass strict mode global assignment check
    rawset(_G, "GetSectorTravelTime", penalty_func)

    -- Use pcall to ensure restoration even on errors
    local ok, route = pcall(original_func, ...)

    -- Restore the original global
    rawset(_G, "GetSectorTravelTime", old_GetSectorTravelTime)

    if not ok then
        -- Log the error if the pathfinding crashed
        print("Pathfinding Error: " .. tostring(route))
        return false
    end

    return route
end

-- Monkey Patch for Standard Pathfinding
local old_GenerateRouteDijkstra = GenerateRouteDijkstra
function GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    return ExecuteWithPathfindingPenalty(side, end_sector, old_GenerateRouteDijkstra, 
        start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
end

-- Monkey Patch for Diamond Shipment Pathfinding
local old_GenerateRouteDijkstraSimplified = GenerateRouteDijkstraSimplified
function GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)
    return ExecuteWithPathfindingPenalty(side, end_sector, old_GenerateRouteDijkstraSimplified, 
        start_sector, end_sector, pass_mode, side, ...)
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

local old_SpawnDynamicDBSquad = SpawnDynamicDBSquad

function SpawnDynamicDBSquad(...)
    if db_cache_dirty then
        if DBRoutesCacheDynamic then
            rawset(_G, "DBRoutesCacheDynamic", nil) -- Clear to force rebuild
        end
        GenerateDynamicDBPathCache()
        db_cache_dirty = false
    end
    return old_SpawnDynamicDBSquad(...)
end