--****************************************************************************
--**
--**  File     :  /lua/sim/Prop.lua
--**  Author(s):
--**
--**  Summary  :
--**
--**  Copyright © 2005 Gas Powered Games, Inc.  All rights reserved.
--****************************************************************************
--
-- The base Prop lua class
--
local Entity = import('/lua/sim/Entity.lua').Entity
local EffectUtil = import('/lua/EffectUtilities.lua')

RECLAIMLABEL_MIN_MASS = 20

Prop = Class(moho.prop_methods, Entity) {

    -- Do not call the base class __init and __post_init, we already have a c++ object
    __init = function(self,spec)
    end,
    __post_init = function(self,spec)
    end,

    OnCreate = function(self)
        Entity.OnCreate(self)
        self.Trash = TrashBag()
        local bp = self:GetBlueprint()
        local economy = bp.Economy

        -- These values are used in world props like rocks / stones / trees
        self:SetMaxReclaimValues(
            economy.ReclaimTimeMultiplier or economy.ReclaimMassTimeMultiplier or economy.ReclaimEnergyTimeMultiplier or 1,
            economy.ReclaimMassMax or 0,
            economy.ReclaimEnergyMax or 0
        )

        local pos = self:GetPosition()
        self.CachePosition = pos
        local max = math.max(50, bp.Defense.MaxHealth)
        self:SetMaxHealth(max)
        self:SetHealth(self, max)
        self:SetCanTakeDamage(not EntityCategoryContains(categories.INVULNERABLE, self))
        self:SetCanBeKilled(true)
    end,

    --Returns the cache position of the prop, since it doesn't move, it's a big optimization
    GetCachePosition = function(self)
        return self.CachePosition or self:GetPosition()
    end,

    --Sets if the unit can take damage.  val = true means it can take damage.
    --val = false means it can't take damage
    SetCanTakeDamage = function(self, val)
        self.CanTakeDamage = val
    end,

    --Sets if the unit can be killed.  val = true means it can be killed.
    --val = false means it can't be killed
    SetCanBeKilled = function(self, val)
        self.CanBeKilled = val
    end,

    CheckCanBeKilled = function(self,other)
        return self.CanBeKilled
    end,

    OnKilled = function(self, instigator, type, exceessDamageRatio )
        if not self.CanBeKilled then return end
        self:Destroy()
    end,

    OnReclaimed = function(self, entity)
        self.CreateReclaimEndEffects( entity, self )
        self:Destroy()
    end,

    CreateReclaimEndEffects = function( self, target )
        EffectUtil.PlayReclaimEndEffects( self, target )
    end,

    Destroy = function(self)
        self.DestroyCalled = true
        Entity.Destroy(self)
    end,

    SyncMassLabel = function(self)
        if self.MaxMassReclaim >= RECLAIMLABEL_MIN_MASS then
            local data = {id = self:GetEntityId()}

            if self:BeenDestroyed() then
                data.mass = 0
            else
                data.mass = self.MaxMassReclaim * self.ReclaimLeft
                data.position = self:GetCachePosition()
            end

            table.insert(Sync.Reclaim, data)
        end
    end,

    OnDestroy = function(self)
        self:UpdateReclaimLeft()
        self.Trash:Destroy()
    end,

    OnDamage = function(self, instigator, amount, direction, damageType)
        if not self.CanTakeDamage then return end
        local preAdjHealth = self:GetHealth()
        self:AdjustHealth(instigator, -amount)
        local health = self:GetHealth()
        if health <= 0 then
            if damageType == 'Reclaimed' then
                self:Destroy()
            else
                local excessDamageRatio = 0.0
                -- Calculate the excess damage amount
                local excess = preAdjHealth - amount
                local maxHealth = self:GetMaxHealth()
                if excess < 0 and maxHealth > 0 then
                    excessDamageRatio = -excess / maxHealth
                end
                self:Kill(instigator, damageType, excessDamageRatio)
            end
        else
            self:UpdateReclaimLeft()
        end
    end,

    OnCollisionCheck = function(self, other)
        return true
    end,

    --- Set the mass/energy value of this wreck when at full health, and the time coefficient
    -- that determine how quickly it can be reclaimed.
    -- These values are used to set the real reclaim values as fractions of the health as the wreck
    -- takes damage.
    SetMaxReclaimValues = function(self, time, mass, energy)
        self.MaxMassReclaim = mass
        self.MaxEnergyReclaim = energy
        self.TimeReclaim = time

        self:UpdateReclaimLeft()
    end,

    -- This function mimics the engine's behavior when calculating what value is left of a prop
    UpdateReclaimLeft = function(self)
        if not self:BeenDestroyed() then
            local max = self:GetMaxHealth()
            local ratio = (max and max > 0 and self:GetHealth() / max) or 1
            -- we have to take into account if the wreck has been partly reclaimed by an engineer
            self.ReclaimLeft = ratio * self:GetFractionComplete()
        end

        -- Notify UI about the mass change
        self:SyncMassLabel()
    end,

    SetPropCollision = function(self, shape, centerx, centery, centerz, sizex, sizey, sizez, radius)
        self.CollisionRadius = radius
        self.CollisionSizeX = sizex
        self.CollisionSizeY = sizey
        self.CollisionSizeZ = sizez
        self.CollisionCenterX = centerx
        self.CollisionCenterY = centery
        self.CollisionCenterZ = centerz
        self.CollisionShape = shape
        if radius and shape == 'Sphere' then
            self:SetCollisionShape(shape, centerx, centery, centerz, radius)
        else
            self:SetCollisionShape(shape, centerx, centery + sizey, centerz, sizex, sizey, sizez)
        end
    end,

    --Prop reclaiming
    -- time = the greater of either time to reclaim mass or energy
    -- time to reclaim mass or energy is defined as:
    -- Mass Time =  mass reclaim value / buildrate of thing reclaiming it * BP set mass mult
    -- Energy Time = energy reclaim value / buildrate of thing reclaiming it * BP set energy mult
    -- The time to reclaim is the highest of the two values above.
    GetReclaimCosts = function(self, reclaimer)
        local time = self.TimeReclaim * (math.max(self.MaxMassReclaim, self.MaxEnergyReclaim) / reclaimer:GetBuildRate())
        time = math.max(time / 10, 0.0001)  -- this should never be 0 or we'll divide by 0!
        return time, self.MaxEnergyReclaim, self.MaxMassReclaim
    end,

    --
    -- Split this prop into multiple sub-props, placing one at each of our bone locations.
    -- The child prop names are taken from the names of the bones of this prop.
    --
    -- If this prop has bones named
    --           "one", "two", "two_01", "two_02"
    --
    -- We will create props named
    --           "../one_prop.bp", "../two_prop.bp", "../two_prop.bp", "../two_prop.bp"
    --
    -- Note that the optional _01, _02, _03 ending to the bone name is stripped off.
    --
    -- You can pass an optional 'dirprefix' arg saying where to look for the child props.
    -- If not given, it defaults to one directory up from this prop's blueprint location.
    --
    SplitOnBonesByName = function(self, dirprefix)
        if not dirprefix then
            -- default dirprefix to parent dir of our own blueprint
            dirprefix = self:GetBlueprint().BlueprintId

            -- trim ".../groups/blah_prop.bp" to just ".../"
            dirprefix = string.gsub(dirprefix, "[^/]*/[^/]*$", "")
        end

        local newprops = {}

        for ibone=1, self:GetBoneCount()-1 do
            local bone = self:GetBoneName(ibone)

            -- construct name of replacement mesh from name of bone, trimming off optional _01 _02 etc
            local btrim = string.gsub(bone, "_?[0-9]+$", "")
            local newbp = dirprefix .. btrim .. "_prop.bp"

            local p = safecall("Creating prop", self.CreatePropAtBone, self, ibone, newbp)
            if p then
                table.insert(newprops, p)
            end
        end

        self:Destroy()
        return newprops
    end,


    PlayPropSound = function(self, sound)
        local bp = self:GetBlueprint().Audio
        if bp and bp[sound] then
            --LOG( 'Playing ', sound )
            self:PlaySound(bp[sound])
            return true
        end
        --LOG( 'Could not play ', sound )
        return false
    end,


    -- Play the specified ambient sound for the unit, and if it has
    -- AmbientRumble defined, play that too
    PlayPropAmbientSound = function(self, sound)
        if sound == nil then
            self:SetAmbientSound( nil, nil )
            return true
        else
            local bp = self:GetBlueprint().Audio
            if bp and bp[sound] then
                if bp.Audio['AmbientRumble'] then
                    self:SetAmbientSound( bp[sound], bp.Audio['AmbientRumble'] )
                else
                    self:SetAmbientSound( bp[sound], nil )
                end
                return true
            end
            return false
        end
    end,
}
