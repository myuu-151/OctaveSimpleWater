-- Water.lua
-- Attach to the water StaticMesh3D node. Does three things per frame:
--   1. scroll the water surface material (two drifting layers)
--   2. scroll the shoreline foam band so the wave crawls around the shore
--   3. show/hide each object's baked foam ring depending on whether the object
--      is actually in the water (crosses the water plane). The rings are CHILD
--      nodes of their objects (named "<obj>Foam"), so they follow the object
--      automatically -- this script only toggles their visibility.
--
-- foamTargets: comma list of object node names whose "<name>Foam" ring should be
-- shown only while the object is in the water (default "cube").

Water = {}

function Water:Create()
    self.waterMatName = "M_Water"        -- water surface material (scrolled)
    self.foamLineMatName = "M_FoamLine"  -- shoreline/ring foam material (U scrolls)
    self.foamLineSpeed = 0.12            -- foam crawl speed (U/sec)
    self.scrollSpeed = 0.02              -- water uv0 drift
    self.scrollSpeed2 = -0.013           -- water uv1 drift (mirrored)
    self.scrollDirX = 1.0
    self.scrollDirY = 1.0
    self.foamTargets = "cube"            -- objects whose foam ring is depth-gated
    self.shorelineName = "ShorelineFoam" -- static shoreline band node (Y-pinned too)
    self.foamLift = 0.002                -- height above the water surface (~mm, just enough to avoid z-fight)
    self.time = 0.0
    self.waterY = nil
    self.waterMat = nil
    self.foamLineMat = nil
    self.targets = nil                   -- { {mesh=..., objNode=..., ringNode=...}, ... }
    self.shorelineNode = nil
end

function Water:GatherProperties()
    return
    {
        { name = "waterMatName", type = DatumType.String },
        { name = "foamLineMatName", type = DatumType.String },
        { name = "foamLineSpeed", type = DatumType.Float },
        { name = "scrollSpeed", type = DatumType.Float },
        { name = "scrollSpeed2", type = DatumType.Float },
        { name = "scrollDirX", type = DatumType.Float },
        { name = "scrollDirY", type = DatumType.Float },
        { name = "foamTargets", type = DatumType.String },
    }
end

-- Euler (degrees, YXZ) + scale + translation applied to a local position.
local function TransformPoint(px, py, pz, pos, rot, scl)
    px = px * scl.x; py = py * scl.y; pz = pz * scl.z
    local d2r = math.pi / 180.0
    local cx = math.cos(rot.x * d2r); local sx = math.sin(rot.x * d2r)
    local cy = math.cos(rot.y * d2r); local sy = math.sin(rot.y * d2r)
    local cz = math.cos(rot.z * d2r); local sz = math.sin(rot.z * d2r)
    local x1 = px * cz - py * sz
    local y1 = px * sz + py * cz
    local z1 = pz
    local y2 = y1 * cx - z1 * sx
    local z2 = y1 * sx + z1 * cx
    local x3 = x1 * cy + z2 * sy
    local z3 = -x1 * sy + z2 * cy
    return x3 + pos.x, y2 + pos.y, z3 + pos.z
end

function Water:Init()
    local world = self:GetWorld()
    if (world == nil) then return false end

    if (self.waterMat == nil and self.waterMatName ~= "") then
        self.waterMat = LoadAsset(self.waterMatName)
    end
    if (self.foamLineMat == nil and self.foamLineMatName ~= "") then
        self.foamLineMat = LoadAsset(self.foamLineMatName)
    end

    -- water height from our own (flat) mesh, in world space
    if (self.waterY == nil) then
        local mesh = self.GetStaticMesh and self:GetStaticMesh() or nil
        if (mesh ~= nil) then
            local verts = mesh:GetVertices()
            if (verts ~= nil and #verts > 0) then
                local p = verts[1].position
                local _, wy, _ = TransformPoint(p.x, p.y, p.z,
                    self:GetWorldPosition(), self:GetWorldRotation(), self:GetScale())
                self.waterY = wy
            end
        end
        if (self.waterY == nil) then self.waterY = self:GetWorldPosition().y end
    end

    if (self.shorelineNode == nil and self.shorelineName ~= "") then
        self.shorelineNode = world:FindNode(self.shorelineName)
    end

    -- resolve each object node + its foam-ring child ("<name>Foam") + mesh verts
    if (self.targets == nil) then
        self.targets = {}
        for name in string.gmatch(self.foamTargets, "([^,%s]+)") do
            local obj = world:FindNode(name)
            local ring = world:FindNode(name .. "Foam")
            local mesh = obj and obj.GetStaticMesh and obj:GetStaticMesh() or nil
            if (obj ~= nil and ring ~= nil and mesh ~= nil) then
                table.insert(self.targets, { objNode = obj, ringNode = ring,
                                             verts = mesh:GetVertices() })
            else
                if (obj == nil) then Log.Warning("Water: object '" .. name .. "' not found") end
                if (ring == nil) then Log.Warning("Water: ring '" .. name .. "Foam' not found") end
            end
        end
    end

    return true
end

-- One pass over the object's verts: XZ centroid (to place the ring), Y extent
-- (to test if it straddles the water plane), all in world space.
function Water:ObjectState(t)
    local pos = t.objNode:GetWorldPosition()
    local rot = t.objNode:GetWorldRotation()
    local scl = t.objNode:GetScale()
    local minY = 1e30
    local maxY = -1e30
    local sx = 0.0
    local sz = 0.0
    local verts = t.verts
    local nv = #verts
    for i = 1, nv do
        local p = verts[i].position
        local wx, wy, wz = TransformPoint(p.x, p.y, p.z, pos, rot, scl)
        if (wy < minY) then minY = wy end
        if (wy > maxY) then maxY = wy end
        sx = sx + wx; sz = sz + wz
    end
    local crosses = (minY < self.waterY) and (maxY > self.waterY)
    return sx / nv, sz / nv, rot.y, crosses
end

function Water:UpdateWater(deltaTime)
    if (not self:Init()) then return end
    self.time = self.time + deltaTime

    -- water surface: two layers drifting on opposing diagonals
    if (self.waterMat ~= nil) then
        local dl = math.sqrt(self.scrollDirX * self.scrollDirX + self.scrollDirY * self.scrollDirY)
        if (dl < 0.0001) then dl = 1.0 end
        local dx = self.scrollDirX / dl
        local dy = self.scrollDirY / dl
        local o1 = self.scrollSpeed * self.time
        local o2 = self.scrollSpeed2 * self.time
        local swell = 0.006 * math.sin(self.time * 0.7)
        local u1 = dx * o1 + swell
        local v1 = dy * o1
        local u2 = -dx * o2
        local v2 = dy * o2 - swell
        self.waterMat:SetUvOffset(Vec(u1 - math.floor(u1), v1 - math.floor(v1)), 0)
        self.waterMat:SetUvOffset(Vec(u2 - math.floor(u2), v2 - math.floor(v2)), 1)
    end

    -- shoreline + ring foam: scroll U so the wave crawls; U is a whole number of
    -- texture repeats, so it loops perfectly seamless.
    if (self.foamLineMat ~= nil) then
        local fu = self.foamLineSpeed * self.time
        self.foamLineMat:SetUvOffset(Vec(fu - math.floor(fu), 0.0), 0)
    end

    local foamY = self.waterY + self.foamLift   -- all foam sits ~1mm above water

    -- shoreline band: keep it pinned flat just above the water (mesh baked at
    -- local Y=0, XZ already in world coords -> only the node Y matters)
    if (self.shorelineNode ~= nil) then
        self.shorelineNode:SetWorldPosition(Vec(0.0, foamY, 0.0))
    end

    -- Drive each object's foam ring: pin it to the water surface (so it doesn't
    -- sink with the object), follow the object's X/Z + yaw, and show it only while
    -- the object actually crosses the water plane.
    if (self.targets ~= nil) then
        for i = 1, #self.targets do
            local t = self.targets[i]
            local cx, cz, yaw, crosses = self:ObjectState(t)
            if (crosses) then
                t.ringNode:SetWorldPosition(Vec(cx, foamY, cz))
                t.ringNode:SetWorldRotation(Vec(0.0, yaw, 0.0))
                t.ringNode:SetVisible(true)
            else
                t.ringNode:SetVisible(false)
            end
        end
    end
end

function Water:Tick(deltaTime)
    self:UpdateWater(deltaTime)
end

function Water:EditorTick(deltaTime)
    self:UpdateWater(deltaTime)
end
