--инициализация объекта
Pathfinder = {}
Pathfinder.__index = Pathfinder
function Pathfinder.new() return setmetatable({}, Pathfinder) end

--константы
DEFAULT_RESOLUTION = 20
DIRECTIONS = {
	Vector3.yAxis,
	-Vector3.yAxis,
	Vector3.xAxis,
	-Vector3.xAxis,
	Vector3.zAxis,
	-Vector3.zAxis,
}

--для статической местности
local discoveredTerrainVoxels = {}

--заполняет воксель частью, для отладки
function DEBUG_FILLVOXEL(pos, size)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Position = pos
	part.Size = Vector3.new(size, size, size)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = .9
	part.Material = Enum.Material.Neon
	part.Color = Color3.new(math.random(1,100)/100,math.random(1,100)/100,math.random(1,100)/100)
	part.Parent = game.Workspace
	return part
end

function GridVector(pos, resolution)
	return Vector3.new(math.round(pos.X/resolution)*resolution, math.round(pos.Y/resolution)*resolution, math.round(pos.Z/resolution)*resolution )
end

--проверяет столкновения как с местностью, так и с частями в области
local colCount = 0
function checkCollision(pos, size, params, waterMode, useStaticTerrain)    --waterMode: только, исключая, игнорировать
	
	--сглаживание затрат на производительность
	if colCount > 25 then
		task.wait()
		colCount = 0
	else
		colCount+=1
	end
	
	--статическая проверка
	local terrainEmpty = nil
	if useStaticTerrain then

		--проверить, что этот записанный воксель был записан для этого размера
		local entry = discoveredTerrainVoxels[pos][size]
		if entry then
			terrainEmpty = true
			if entry.full then return true end
			if entry.water then
				if waterMode == "excluding" then return true end
			else
				if waterMode == "only" then return true end
			end
		end
	end
	
	--проверка частей
	local parts = workspace:GetPartBoundsInBox(CFrame.new(pos), Vector3.new(size, size, size), params)
	
	--часть найдена, вернуть true
	if #parts > 0 then 
		return true 
	end
		
	--проверка местности
	if not terrainEmpty then
		--чтение местности
		local regionsize = Vector3.new(size, size, size)/2
		local mat, occ = workspace.Terrain:ReadVoxels(Region3.new(pos - regionsize, pos + regionsize), 4)
		local foundMaterials = {}

		local readsize = mat.Size

		for x = 1, readsize.X, 1 do
			for y = 1, readsize.Y, 1 do
				for z = 1, readsize.Z, 1 do
					foundMaterials[#foundMaterials+1] = mat[x][y][z].Name
				end
			end
		end
		
		--обнаружение твердой и жидкой местности
		local full = false
		local water = false
		for _, i in pairs(foundMaterials) do
			if i == "Air" then continue end

			if i == "Water" then
				water = true
			else
				full = true
			end
		end
		
		--вставить в обнаруженную таблицу, если статическая местность включена. документирует размеры проверок, использованных на этом вокселе
		if useStaticTerrain then
			local entry = discoveredTerrainVoxels[pos]

			if entry then
				discoveredTerrainVoxels[pos][size] = {
					full = full,
					water = water
				}
			else
				entry = {}
				entry[size] = {
					full = full,
					water = water,
				}
				discoveredTerrainVoxels[pos] = entry
			end
		end
		
		if water then 
			if waterMode == "excluding" then return true end
		else
			if waterMode == "only" then return true end	
		end
		if full then return true end
	end
	
	return false
end

--удаляет ненужные контрольные точки из пути
function cullPath(path, waterMode)
	local newPath = {path[1]}
	local previous = path[1]
	local goal = path[#path]
	local params = RaycastParams.new()
	--params.IgnoreWater = ignoreWater
	
	for x, i in pairs(path) do
		--пропустить первый индекс
		if x <= 1 then continue end
		
		--лучевое сканирование между последней добавленной контрольной точкой и текущей контрольной точкой
		local results = workspace:Raycast(previous, (i - previous).Unit * (i-previous).Magnitude, params)
		local water = false
		
		if results and results.Material == Enum.Material.Water then
			water = true
			params.IgnoreWater = true
			results = workspace:Raycast(previous, (i - previous).Unit * (i-previous).Magnitude, params)
		end
		
		--вставить предыдущую контрольную точку, если найдено столкновение
		if results or (waterMode == "only" and water == false) or (waterMode == "excluding" and water) then 
			table.insert(newPath, path[x-1]) 
			previous = path[x-1]
		end
		
		--вставить финальную контрольную точку в путь
		if i == goal then 
			newPath[#newPath+1] = goal
		end
	end
	
	return newPath
end

-- генерирует путь от точки A до точки B
function Pathfinder:genPath(start: Vector3, goal: Vector3, args: {})
	--useStaticTerrain, waterMode, filtered, resolution, testSize
	local open = {}
	local closed = {}
	
	local path = nil
	
	local args = args or {}
	local waterMode = args.waterMode or "ignore"
	local useStaticTerrain = args.useStaticTerrain or false
	local filtered = args.filtered or {}
	local resolution = math.max( args.resolution or DEFAULT_RESOLUTION, .1)
	local testSize = math.max( args.testSize or resolution, .1 )
	local rayParams = RaycastParams.new()
	local overParams = OverlapParams.new()
	start = GridVector(start, resolution)
	goal = GridVector(goal, resolution)
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = filtered
	overParams.FilterType = Enum.RaycastFilterType.Exclude
	overParams.FilterDescendantsInstances = filtered
	
	--проверка, что цель находится в допустимом месте
	local found = checkCollision(goal, testSize, overParams, waterMode, useStaticTerrain)
	if found then return nil end
	
	local function algorithm()
		--найти S
		local lowestScore = math.huge
		local S = nil
		
		for v, i in pairs(open) do
			if (i.G + i.H) < lowestScore then
				S = v
				lowestScore = i.G + i.H
			end
		end
		
		--переместить в закрытый
		local Sdata = open[S]
		open[S] = nil
		closed[S] = Sdata
		
		--обработать соседние плитки
		for _, i in pairs(DIRECTIONS) do
			local dir = i * resolution
			local tile = S + dir
			
			--проверка цели
			if tile == goal then
				path = {}
				local currentTile = S
				table.insert(path, 1, tile)
				
				while currentTile do
					table.insert(path, 1, currentTile)
					currentTile = closed[currentTile].P
				end
				return
			end
			
			--игнорировать, если закрыто
			if closed[tile] then continue end
			
			--добавить в открытый, если его там еще нет
			if not open[tile] then
				--проверка на столкновение (столкновение удаляет воксель из рассмотрения)
				local found = checkCollision(tile, testSize, overParams, waterMode, useStaticTerrain)
				if found then closed[tile] = true continue end
				
				--проверка видимости (отсутствие видимости предотвращает путь от источника к этому вокселю)
				local raycast = workspace:Raycast(S, dir, rayParams)
				if raycast and raycast.Material ~= Enum.Material.Water then print("связь заблокирована") continue end
				
				--вставить плитку, если не найдено столкновение
				open[tile] = {
					G = Sdata.G + resolution,
					H = (tile - goal).Magnitude,
					P = S
				}
				continue
			end
			
			--уже в открытом списке
			local sDist = Sdata.G + resolution
			local prevDist = open[tile].G
			if sDist < prevDist then
				open[tile] = {
					G = Sdata.G + resolution,
					H = (tile - goal).Magnitude,
					P = S
				}
			end
		end
		return
	end
	
	open[start] = {
		G = 0,
		H = (start - goal).Magnitude
	}
	
	local run = true
	while run do
		run = false
		algorithm()
		if path ~= nil then break end
		for _, i in pairs(open) do
			run = true
			break
		end
	end
	
	--очистка пути
	if path then
		path = cullPath(path, true)
	end
	
	return path
end

return Pathfinder
