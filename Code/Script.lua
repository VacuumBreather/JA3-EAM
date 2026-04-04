function ApplyPathfindingPenalty(old_GetSectorTravelTime, side)
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
                if has_player_squads or has_militia then
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
    GetSectorTravelTime = ApplyPathfindingPenalty(old_GetSectorTravelTime, side)
    
    local route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)
    
    GetSectorTravelTime = old_GetSectorTravelTime

    if not route then
        route = old_GenerateRouteDijkstra(start_sector, end_sector, fullRoute, units, pass_mode, squad_curr_sector, side, noShortcuts)

        if route then            
            print("ATTENTION: Alt-Route necessary (GenerateRouteDijkstra)")
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
            print("ATTENTION: Alt-Route necessary (GenerateRouteDijkstra)")
        end
    end
    
    return route
end

-- Priority Queue

-- Priority Queue (Min-Heap)
local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

function PriorityQueue.new()
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

-- Peek at the top element without removing it
function PriorityQueue:peek()
  if self._size == 0 then return nil end
  return self._heap[1].value, self._heap[1].priority
end

function PriorityQueue:isEmpty()
  return self._size == 0
end

function PriorityQueue:size()
  return self._size
end

--Priority Queue end
local function DijkstraSearch(from, getNeighbours, getCost)
    local count = 1
    local frontier = PriorityQueue.new()
    frontier:put(from, 0)
    local came_from = { [from] = "NONE" }
    local cost_so_far = { [from] = 0 }

    while not frontier:isEmpty() do
        local current = frontier:pop()
        count = count + 1

        -- Iterate through neighboring sectors
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
end

function OnMsg.LoadSessionData()
    db_cache_dirty = true
end

function GenerateDynamicDBPathCache_Optimized()
	PauseInfiniteLoopDetection("DBPathfinding")
	local st = GetPreciseTicks()
	local routeCache = {}
	local sources = {}
	local destinations = {}
	local campaign = GetCurrentCampaignPreset()
	local cols = campaign.sector_columns
	local rows = campaign.sector_rows

    local minRouteLength = 10
	
	for id, sector in sorted_pairs(gv_Sectors) do
		if IsSectorUnderground(id) then goto continue end
		
		if sector.DBSourceSector and not sources[id] then
			sources[#sources + 1] = id
			sources[id] = "src"
		end
		
		local row, col = sector_unpack(id)
		local isEdgeSector = row == rows or cols == col or row == 1 or col == 1
		if (sector.DBDestinationSector or isEdgeSector) and not destinations[id] then
			destinations[#destinations + 1] = id
			destinations[id] = isEdgeSector and "edge" or "dest"
		end
		
		::continue::
	end
	
	if #sources == 0 or #destinations == 0 then 
		DBRoutesCacheDynamic = {}
		return
	end

	local source_lookups = {}
    local getTravelTime = ApplyPathfindingPenalty(GetSectorTravelTime, "diamonds")
    local getCost = function(from, to)
        local dir = GetSectorDirection(from, to)
        return GetSectorTravelTime(from, to, nil, nil, "land_water_boatless", nil, "diamonds", dir)
    end

	for _, source in ipairs(sources) do
        local came_from = DijkstraSearch(source, GetNeighborSectors, getCost)
        source_lookups[source] = came_from
    end

    for _, source in ipairs(sources) do
        for _, dest in ipairs(destinations) do
			if source == dest then goto continue end

            local route = ReconstructPath(source, dest, source_lookups[source])

            if #route >= minRouteLength then
				route.source = source
				route.dest = dest
				routeCache[#routeCache + 1] = route
			end

			::continue::
        end
    end

    DBRoutesCacheDynamic = routeCache
	print(string.format("GenerateDynamicDBPathCache finished after: %d ms/n", GetPreciseTicks() - st))
	ResumeInfiniteLoopDetection("DBPathfinding")
end

local old_SpawnDynamicDBSquad = SpawnDynamicDBSquad

function SpawnDynamicDBSquad(...)
    if db_cache_dirty then
        GenerateDynamicDBPathCache_Optimized()
        db_cache_dirty = false
    end
    return old_SpawnDynamicDBSquad(...)
end