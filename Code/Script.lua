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
                    -- 1. Check for physical presence of player/allied squads
                    -- We exclude travelling squads as they aren't "in" the sector to block it effectively
                    local player_or_militia_squads = GetSquadsInSector(id, true, true, true, true)
                    has_presence = #player_or_militia_squads > 0
                end

                -- If player mercs OR militia are present, apply the penalty
                if has_presence then
                    time = Max(tonumber(time) or 0, 2500000)
                end
            end
        end

        return time, t1, t2, breakdown
    end
end

local old_GenerateRouteDijkstra = GenerateRouteDijkstra

function GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    local old_GetSectorTravelTime = GetSectorTravelTime
    GetSectorTravelTime = ApplyPathfindingPenalty(old_GetSectorTravelTime, side)

    local route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)

    GetSectorTravelTime = old_GetSectorTravelTime

    if not route then
        route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)

        if route then
            print(string.format("[EAM] [Warning] Fallback pathfinding was necessary to find a route from %s to %s", start_sector, end_sector))
        end
    end

    return route
end

local old_GenerateRouteDijkstraSimplified = GenerateRouteDijkstraSimplified

function GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)
    local old_GetSectorTravelTime = GetSectorTravelTime
    GetSectorTravelTime = ApplyPathfindingPenalty(old_GetSectorTravelTime, side)

    local route = old_GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)

    GetSectorTravelTime = old_GetSectorTravelTime

    if not route then
        route = old_GenerateRouteDijkstraSimplified(start_sector, end_sector, pass_mode, side, ...)

        if route then
            print(string.format("[EAM] [Warning] Fallback pathfinding was necessary to find a route from %s to %s", start_sector, end_sector))
        end
    end

    return route
end

-- Priority Queue

-- Priority Queue (Min-Heap)
local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

local function PriorityQueue.new()
  return setmetatable({ _heap = {}, _size = 0 }, PriorityQueue)
end

-- Swap two elements in the heap
local function swap(heap, i, j)
  heap[i], heap[j] = heap[j], heap[i]
end

-- Bubble up to restore heap property after insertion
local function siftUp(heap, i)
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap[parent].priority <= heap[i].priority then break end
    swap(heap, parent, i)
    i = parent
  end
end

-- Bubble down to restore heap property after removal
local function siftDown(heap, i, size)
  while true do
    local smallest = i
    local left, right = 2 * i, 2 * i + 1

    if left <= size and heap[left].priority < heap[smallest].priority then
      smallest = left
    end
    if right <= size and heap[right].priority < heap[smallest].priority then
      smallest = right
    end

    if smallest == i then break end
    swap(heap, i, smallest)
    i = smallest
  end
end

-- Insert a value with a given priority (lower number = higher priority)
function PriorityQueue:put(value, priority)
  self._size = self._size + 1
  self._heap[self._size] = { value = value, priority = priority }
  siftUp(self._heap, self._size)
end

-- Remove and return the highest-priority (lowest number) element
function PriorityQueue:pop()
  if self._size == 0 then return nil end

  local top = self._heap[1]
  self._heap[1] = self._heap[self._size]
  self._heap[self._size] = nil
  self._size = self._size - 1
  if self._size > 0 then
    siftDown(self._heap, 1, self._size)
  end

  return top.value, top.priority
end

function PriorityQueue:isEmpty()
  return self._size == 0
end

--Priority Queue end
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
                    local priority = new_cost
                    frontier:put(next_sector, priority)
                    came_from[next_sector] = current
                end
            end
        end
    end

    return came_from
end

local function ReconstructPath(from, to, came_from)
    local current = to
    local path = {}

    while current and current ~= from and current ~= "NONE" do
        path[#path + 1] = current
        current = came_from[current]
    end

    -- Verify if we actually reached the start
    if current ~= from and current ~= "NONE" then
        return {} -- Return empty path if no route was found
    end

    -- Reverse the table
    local n = #path

    for i = 1, math.floor(n / 2) do
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

function GenerateDynamicDBPathCache_Optimized()
    -- Enable engine protection
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

    -- Cache player and militia presence
    for id, sector in pairs(gv_Sectors) do
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

            -- Check for map edges
            if sector.DBDestinationSector or row == rows or col == cols or row == 1 or col == 1 then
                destinations[#destinations + 1] = id
            end
        end
    end

    -- Check if we can build routes at all
	if #sources == 0 or #destinations == 0 then
		DBRoutesCacheDynamic = {}
        ResumeInfiniteLoopDetection("DBPathfinding")
		return
	end

    -- Cache the cost function for speed
    local base_travel_time = GetSectorTravelTime
    local penalty_travel_time = ApplyPathfindingPenalty(base_travel_time, "diamonds", cached_presence)

    local getCost = function(f, t)
        local dir = GetSectorDirection(f, t)
        return penalty_travel_time(f, t, nil, nil, "land_water_boatless", nil, "diamonds", dir)
    end

    local dedupe = {}

    -- The Optimized Loop
    for _, src in ipairs(sources) do
        local came_from = DijkstraSearch(src, GetNeighborSectors, getCost)
        for _, dest in ipairs(destinations) do
            if src ~= dest then
                local route = ReconstructPath(src, dest, came_from)

                if not route or #route == 0 then goto continue end

                -- Shave off weird looking routes at the edge of the map.
                if destinations[dest] == "edge" then
                    local edgeSectorsToRemove = 0

                    for i = #route, 1, -1 do
                        local sectorId = route[i]
                        local row, col = sector_unpack(sectorId)
                        local isEdgeSector = row == rows or cols == col or row == 1 or col == 1

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
                end

                -- Prevent duplication
                if dedupe[src .. " " .. dest] then goto continue end

                -- The route should be at least minRouteLength long.
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

    -- Restore protection and print only the FINAL result
    ResumeInfiniteLoopDetection("DBPathfinding")
    print(string.format("DB Cache Rebuilt: %d routes in %d ms", #routeCache, GetPreciseTicks() - st))
    CombatLog("DBPathfinding", string.format("DB Cache Rebuilt old way: %d routes in %d ms", #DBRoutesCacheDynamic, GetPreciseTicks() - st))
end

local old_SpawnDynamicDBSquad = SpawnDynamicDBSquad

function SpawnDynamicDBSquad(...)
    if db_cache_dirty then
	    local st = GetPreciseTicks()
        DBRoutesCacheDynamic = nil
        GenerateDynamicDBPathCache()
        print(string.format("DB Cache Rebuilt old way: %d routes in %d ms", #DBRoutesCacheDynamic, GetPreciseTicks() - st))
        CombatLog("DBPathfinding", string.format("DB Cache Rebuilt old way: %d routes in %d ms", #DBRoutesCacheDynamic, GetPreciseTicks() - st))
        GenerateDynamicDBPathCache_Optimized()
        db_cache_dirty = false
    end
    return old_SpawnDynamicDBSquad(...)
end