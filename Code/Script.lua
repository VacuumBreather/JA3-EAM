--- Generates a pathfinding penalty function to deter enemy squads from sectors with player/militia presence.
--- @param old_GetSectorTravelTime function The original travel time calculation function.
--- @param side string The side (faction) currently performing pathfinding.
--- @param cached_presence table|nil Optional pre-calculated presence data (sector_id -> boolean).
--- @return function A wrapped travel time function that applies high costs to guarded sectors.
function ApplyPathfindingPenalty(old_GetSectorTravelTime, side, cached_presence)
    return function(from, to, ...)
        local time, t1, t2, breakdown = old_GetSectorTravelTime(from, to, ...)

        -- Check if 'time' is valid (not false/nil)
        if time then
            -- CUSTOM LOGIC: High cost for enemy pathfinding through player/militia sectors
            local is_enemy = side == "enemy1" or side == "diamonds"

            if is_enemy and to then
                local has_presence = false

                if cached_presence then
                    has_presence = cached_presence[to]
                else
                    -- Fallback: Check for physical presence of player/allied squads or militia
                    -- We exclude travelling squads as they aren't "in" the sector to block it effectively
                    local player_or_militia_squads = GetSquadsInSector(to, true, true, true, true)
                    has_presence = #player_or_militia_squads > 0
                end

                -- If player mercs OR militia are present, apply a significant penalty floor.
                -- Using 2,500,000 as a "soft-block" cost (approx. 115 hours).
                if has_presence then
                    time = Max(tonumber(time) or 0, 2500000)
                end
            end
        end

        return time, t1, t2, breakdown
    end
end

local old_GenerateRouteDijkstra = GenerateRouteDijkstra

--- Standard satellite pathfinding monkey patch to apply penalties.
function GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    local old_GetSectorTravelTime = GetSectorTravelTime
    -- Temporarily override the global GetSectorTravelTime to influence the Dijkstra search
    GetSectorTravelTime = ApplyPathfindingPenalty(old_GetSectorTravelTime, side)

    local route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)

    -- Restore the original function immediately to avoid side effects
    GetSectorTravelTime = old_GetSectorTravelTime

    if not route then
        -- If no path was found with penalties, retry without them to prevent squads from getting stuck
        route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)

        if route then
            print(string.format("[EAM] [Warning] Fallback pathfinding was necessary to find a route from %s to %s", start_sector, end_sector))
        end
    end

    return route
end

local old_GenerateRouteDijkstraSimplified = GenerateRouteDijkstraSimplified

--- Diamond shipment pathfinding monkey patch to apply penalties.
function GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)
    local old_GetSectorTravelTime = GetSectorTravelTime
    -- Temporarily override the global GetSectorTravelTime
    GetSectorTravelTime = ApplyPathfindingPenalty(old_GetSectorTravelTime, side)

    local route = old_GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)

    -- Restore the original function
    GetSectorTravelTime = old_GetSectorTravelTime

    if not route then
        -- Fallback to original logic if penalty-aware pathfinding fails
        route = old_GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)

        if route then
            print(string.format("[EAM] [Warning] Fallback pathfinding was necessary to find a route from %s to %s", start_sector, end_sector))
        end
    end

    return route
end

--- Priority Queue (Min-Heap) implementation optimized for reduced GC pressure.
local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

--- Creates a new PriorityQueue instance.
function PriorityQueue.new()
  return setmetatable({ _values = {}, _priorities = {}, _size = 0 }, PriorityQueue)
end

--- Internal helper to swap two elements in the heap.
local function swap(self, i, j)
  local values, priorities = self._values, self._priorities
  values[i], values[j] = values[j], values[i]
  priorities[i], priorities[j] = priorities[j], priorities[i]
end

--- Internal helper to restore heap property by moving an element up.
local function siftUp(self, i)
  local priorities = self._priorities
  while i > 1 do
    local parent = i >> 1 -- Bitwise shift for faster math.floor(i / 2)
    if priorities[parent] <= priorities[i] then break end
    swap(self, parent, i)
    i = parent
  end
end

--- Internal helper to restore heap property by moving an element down.
local function siftDown(self, i, size)
  local priorities = self._priorities
  while true do
    local smallest = i
    local left, right = i << 1, (i << 1) + 1 -- Bitwise shifts for children

    if left <= size and priorities[left] < priorities[smallest] then
      smallest = left
    end
    if right <= size and priorities[right] < priorities[smallest] then
      smallest = right
    end

    if smallest == i then break end
    swap(self, i, smallest)
    i = smallest
  end
end

--- Inserts a value into the queue with a numeric priority.
--- @param value any The data to store.
--- @param priority number Lower values have higher priority.
function PriorityQueue:put(value, priority)
  local size = self._size + 1
  self._size = size
  self._values[size] = value
  self._priorities[size] = priority
  siftUp(self, size)
end

--- Removes and returns the highest-priority element and its priority.
--- @return any|nil, number|nil The stored value and its priority, or nil if empty.
function PriorityQueue:pop()
  local size = self._size
  if size == 0 then return nil end

  local values, priorities = self._values, self._priorities
  local val, prio = values[1], priorities[1]
  
  values[1] = values[size]
  priorities[1] = priorities[size]
  
  values[size] = nil
  priorities[size] = nil
  
  size = size - 1
  self._size = size
  if size > 0 then
    siftDown(self, 1, size)
  end

  return val, prio
end

--- Checks if the queue is empty.
function PriorityQueue:isEmpty()
  return self._size == 0
end

--Priority Queue end
--- Performs a one-to-all Dijkstra search to calculate path costs from a source sector.
--- @param from string The starting sector ID.
--- @param getNeighbours function A function that returns adjacent sectors (sector_id -> direction).
--- @param getCost function A function that returns the travel cost between two adjacent sectors.
--- @return table A table of parent pointers (sector_id -> previous_sector_id) for path reconstruction.
local function DijkstraSearch(from, getNeighbours, getCost)
    local frontier = PriorityQueue.new()
    frontier:put(from, 0)
    local came_from = { [from] = "NONE" }
    local cost_so_far = { [from] = 0 }

    while not frontier:isEmpty() do
        local current = frontier:pop()

        for next_sector, _ in pairs(getNeighbours(current)) do
            local travel_cost = getCost(current, next_sector)

            if type(travel_cost) == "number" then
                local new_cost = cost_so_far[current] + travel_cost

                if (not cost_so_far[next_sector]) or new_cost < cost_so_far[next_sector] then
                    cost_so_far[next_sector] = new_cost
                    frontier:put(next_sector, new_cost)
                    came_from[next_sector] = current
                end
            end
        end
    end

    return came_from
end

--- Reconstructs a path from the source to a target using 'came_from' data.
--- @param from string The source sector ID.
--- @param to string The target sector ID.
--- @param came_from table The result of a DijkstraSearch.
--- @return table An ordered list of sector IDs from from to to.
local function ReconstructPath(from, to, came_from)
    local current = to
    local path = {}

    -- Backtrack from the destination to the source
    while current and current ~= from and current ~= "NONE" do
        path[#path + 1] = current
        current = came_from[current]
    end

    -- Verify if we actually reached the source
    if current ~= from and current ~= "NONE" then
        return {} -- Return empty path if unreachable
    end

    -- Reverse the path in-place to get Source -> Destination order
    local n = #path
    for i = 1, n >> 1 do
        local j = n - i + 1
        path[i], path[j] = path[j], path[i]
    end

    return path
end

local db_cache_dirty = true

function OnMsg.SectorSideChanged()
    db_cache_dirty = true
end

function OnMsg.InitSessionCampaignObjects()
    db_cache_dirty = true
end

function OnMsg.LoadSessionData()
    db_cache_dirty = true
end

--- Rebuilds the Diamond Briefcase shipment route cache using optimized one-to-all searches.
--- This implementation respects player/militia presence by applying high pathfinding costs.
function GenerateDynamicDBPathCache_Optimized()
    -- Enable engine protection to prevent timeout during heavy calculations
	PauseInfiniteLoopDetection("DBPathfinding")

	local st = GetPreciseTicks()
	local routeCache = {}
	local sources = {}
	local destinations = {}
    local cached_presence = {}
	local campaign = GetCurrentCampaignPreset()
	local cols = campaign.sector_columns
	local rows = campaign.sector_rows
    local minRouteLength = 10

    -- Cache player and militia presence once to avoid expensive engine calls in the inner loops
    for id, _ in pairs(gv_Sectors) do
        local player_or_militia_squads = GetSquadsInSector(id, true, true, true, true)
        if #player_or_militia_squads > 0 then
            cached_presence[id] = true
        end
    end

	-- Build Source and Destination lists
    for id, sector in sorted_pairs(gv_Sectors) do
        if not IsSectorUnderground(id) then
            if sector.DBSourceSector then
                sources[#sources + 1] = id
            end

            local row, col = sector_unpack(id)

            -- Identify potential exit sectors (marked or map boundaries)
            if sector.DBDestinationSector or row == rows or col == cols or row == 1 or col == 1 then
                destinations[#destinations + 1] = id
            end
        end
    end

    -- Safety check: ensure both sources and destinations exist
	if #sources == 0 or #destinations == 0 then
		DBRoutesCacheDynamic = {}
        ResumeInfiniteLoopDetection("DBPathfinding")
		return
	end

    -- Prepare the cost evaluation closure
    local base_travel_time = GetSectorTravelTime
    local penalty_travel_time = ApplyPathfindingPenalty(base_travel_time, "diamonds", cached_presence)

    local getCost = function(f, t)
        local dir = GetSectorDirection(f, t)
        return penalty_travel_time(f, t, nil, nil, "land_water_boatless", nil, "diamonds", dir)
    end

    local dedupe = {}

    -- Main optimization loop: O(Sources * Dijkstra) instead of O(Sources * Destinations * Dijkstra)
    for _, src in ipairs(sources) do
        local came_from = DijkstraSearch(src, GetNeighborSectors, getCost)
        for _, dest in ipairs(destinations) do
            if src ~= dest then
                local route = ReconstructPath(src, dest, came_from)

                if not route or #route == 0 then goto continue end

                -- Shave off redundant movements along the map boundary.
                -- This ensures shipments exit at the first available edge sector.
                local edgeSectorsToRemove = 0
                for i = #route, 1, -1 do
                    local sectorId = route[i]
                    local row, col = sector_unpack(sectorId)
                    local isEdgeSector = row == rows or col == cols or row == 1 or col == 1

                    if isEdgeSector then
                        edgeSectorsToRemove = edgeSectorsToRemove + 1
                    else
                        break
                    end
                end

                if edgeSectorsToRemove > 1 then
                    local routeLength = #route
                    for i = 0, edgeSectorsToRemove - 2 do
                        route[routeLength - i] = nil
                    end
                    dest = route[#route]
                end

                -- Prevent storing identical routes in the cache
                if dedupe[src .. " " .. dest] then goto continue end

                -- Enforce minimum travel distance to keep shipments on the map
                if #route >= minRouteLength then
                    route.source, route.dest = src, dest
                    dedupe[src .. " " .. dest] = true
                    routeCache[#routeCache + 1] = route
                end
            end

            ::continue::
        end
    end

    DBRoutesCacheDynamic = routeCache

    -- Restore engine infinite loop protection
    ResumeInfiniteLoopDetection("DBPathfinding")
    print(string.format("[EAM] DB Cache Rebuilt: %d routes in %d ms", #routeCache, GetPreciseTicks() - st))
    CombatLog("DBPathfinding", string.format("DB Cache Rebuilt: %d routes in %d ms", #DBRoutesCacheDynamic, GetPreciseTicks() - st))
end

local old_SpawnDynamicDBSquad = SpawnDynamicDBSquad

--- Overrides the standard Diamond Shipment spawner to ensure the cache is refreshed when dirty.
function SpawnDynamicDBSquad(...)
    if db_cache_dirty then
	    local st = GetPreciseTicks()
        -- Force the game to rebuild its base cache if needed, though we primarily use our optimized one
        DBRoutesCacheDynamic = nil
        GenerateDynamicDBPathCache()
        
        -- Run our optimized pathfinding rebuild
        GenerateDynamicDBPathCache_Optimized()
        db_cache_dirty = false
    end
    return old_SpawnDynamicDBSquad(...)
end