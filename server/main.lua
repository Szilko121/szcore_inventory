local function registerSzCoreCallback(name, fn)
    CreateThread(function()
        local deadline = GetGameTimer() + 15000

        while GetGameTimer() < deadline do
            if GetResourceState('szcore') == 'started' then
                local ok, success, err = pcall(function()
                    return exports['szcore']:CreateCallback(name, fn)
                end)

                if ok and success ~= false then
                    return
                end

                if ok and success == false then
                    print(('[%s] SzCore callback registration rejected: %s (%s)'):format(
                        GetCurrentResourceName(),
                        tostring(name),
                        tostring(err)
                    ))
                    return
                end
            end

            Wait(100)
        end

        print(('[%s] SzCore callback registration timed out: %s'):format(
            GetCurrentResourceName(),
            tostring(name)
        ))
    end)
end

local I = { cache = {}, usable = {}, dirty = {}, sourceInventory = {}, saving = {}, loading = {} }
local netRate={}
local function netAllowed(src,key,ms)local now=GetGameTimer();netRate[src]=netRate[src] or {};local prev=netRate[src][key] or 0;if now-prev<ms then return false end;netRate[src][key]=now;return true end
local function idForCitizen(cid) return 'player:' .. cid end
local serialCounter=0
local function copyTable(v) if type(v)~='table' then return v end;local o={};for k,x in pairs(v) do o[k]=copyTable(x) end;return o end
local function prepareMetadata(item,metadata)
    local def=SzCoreItems[item];local out=copyTable(metadata or {})
    if def and def.weapon then
        if not out.serial then serialCounter=serialCounter+1;out.serial=('SZW-%X-%04X'):format(os.time(),serialCounter%65536) end
        out.ammo=math.max(0,tonumber(out.ammo) or 0);if out.durability==nil then out.durability=100 end
    end
    return out
end
local function ensure(id, ownerType, ownerId, slots, maxWeight)
    MySQL.prepare.await([[INSERT INTO szcore_inventories (inventory_id,owner_type,owner_id,max_slots,max_weight)
        VALUES (?,?,?,?,?) ON DUPLICATE KEY UPDATE owner_type=VALUES(owner_type),owner_id=VALUES(owner_id)]],
        { id, ownerType or 'custom', ownerId or '', slots or 40, maxWeight or 120000 })
end
local function loadRaw(id)
    if I.cache[id] then return I.cache[id] end
    local inv = MySQL.single.await('SELECT * FROM szcore_inventories WHERE inventory_id=?', { id })
    if not inv then return nil end
    inv.max_slots = tonumber(inv.max_slots) or 40;inv.max_weight = tonumber(inv.max_weight) or 120000;inv.items = {}
    local rows = MySQL.query.await('SELECT slot,item,amount,metadata FROM szcore_inventory_items WHERE inventory_id=? ORDER BY slot', { id }) or {}
    for i = 1, #rows do
        local r = rows[i];local ok, metadata = pcall(json.decode, r.metadata or '{}')
        inv.items[tonumber(r.slot)] = { name = r.item, amount = tonumber(r.amount) or 0, metadata = ok and metadata or {} }
    end
    I.cache[id] = inv;return inv
end
local recoveryReady=false
local function load(id)
    local deadline=GetGameTimer()+10000
    while not recoveryReady or I.loading[id] do if GetGameTimer()>deadline then return nil end;Wait(5) end
    if I.cache[id] then return I.cache[id]end
    I.loading[id]=true;local ok,result=pcall(loadRaw,id);I.loading[id]=nil
    if not ok then print('[SzCore inventory] Load failed: '..tostring(result));return nil end
    return result
end
local function markDirty(id, slot)local d=I.dirty[id];if not d then d={};I.dirty[id]=d end;d[slot]=true end
local detached={}
local function checkpoint()
    local pending={};for id in pairs(I.dirty) do if I.cache[id] then pending[id]=I.cache[id] end end
    return SaveResourceFile(GetCurrentResourceName(),'inventory_recovery.json',json.encode(pending),-1)
end
local function flushMany(ids)
    for _,id in ipairs(ids) do if I.saving[id] then return false end end
    local queries={}
    for _,id in ipairs(ids) do
        I.saving[id]=true;local inv=I.cache[id]
        for slot in pairs(I.dirty[id] or {}) do
            local e=inv and inv.items[slot]
            if e then queries[#queries+1]={query=[[INSERT INTO szcore_inventory_items (inventory_id,slot,item,amount,metadata) VALUES (?,?,?,?,?)
                ON DUPLICATE KEY UPDATE item=VALUES(item),amount=VALUES(amount),metadata=VALUES(metadata)]],values={id,slot,e.name,e.amount,json.encode(e.metadata or {})}}
            else queries[#queries+1]={query='DELETE FROM szcore_inventory_items WHERE inventory_id=? AND slot=?',values={id,slot}} end
        end
    end
    local ok,result=true,true;if #queries>0 then ok,result=pcall(MySQL.transaction.await,queries) end
    local success=ok and result==true
    for _,id in ipairs(ids) do I.saving[id]=nil;if success then I.dirty[id]=nil;if detached[id] then I.cache[id]=nil;detached[id]=nil end end end
    checkpoint();return success
end
local function flush(id)return flushMany({id})end
local function currentWeight(inv)
    local total=0;for _,e in pairs(inv.items) do local d=SzCoreItems[e.name];if d then total=total+(d.weight or 0)*e.amount end end;return total
end
local function metadataEqual(a,b)return json.encode(a or {})==json.encode(b or {})end
local function findDestinationSlot(inv,item,metadata,requested)
    local def=SzCoreItems[item]
    if requested then
        if requested~=requested or requested%1~=0 or requested<1 or requested>inv.max_slots then return nil end
        local e=inv.items[requested];if not e then return requested end
        if def.stack~=false and e.name==item and metadataEqual(e.metadata,metadata) then return requested end
        return nil
    end
    if def.stack~=false then for slot,e in pairs(inv.items) do if e.name==item and metadataEqual(e.metadata,metadata) then return slot end end end
    for slot=1,inv.max_slots do if not inv.items[slot] then return slot end end
end
function I.ensure(id,ownerType,ownerId,slots,maxWeight)ensure(id,ownerType,ownerId,slots,maxWeight);return load(id)end
function I.player(source)
    local p=exports.szcore:GetPlayer(source);if not p then return nil end
    local id=idForCitizen(p.PlayerData.citizenid);if not I.cache[id] then ensure(id,'player',p.PlayerData.citizenid,40,120000) end
    detached[id]=nil;I.sourceInventory[source]=id;return load(id),id
end
function I.get(id)return load(id)end
function I.canCarry(inv,item,amount,metadata)
    local def=SzCoreItems[item];amount=math.floor(tonumber(amount) or 0)
    if not inv or not def or amount~=amount or amount==math.huge or amount<=0 then return false end
    if currentWeight(inv)+(def.weight or 0)*amount>inv.max_weight then return false end
    if def.stack==false then local free=0;for slot=1,inv.max_slots do if not inv.items[slot] then free=free+1 end end;return free>=amount end
    return findDestinationSlot(inv,item,metadata,nil)~=nil
end
function I.add(id,item,amount,metadata,slot)
    if I.saving[id] then return false,'inventory_busy' end
    local inv=load(id);local def=SzCoreItems[item];amount=math.floor(tonumber(amount) or 0)
    if not inv or not def or amount~=amount or amount==math.huge or amount<=0 then return false,'invalid_item' end
    metadata=prepareMetadata(item,metadata)
    if currentWeight(inv)+(def.weight or 0)*amount>inv.max_weight then return false,'too_heavy' end
    if def.stack==false and amount>1 then
        if not I.canCarry(inv,item,amount,metadata) then return false,'no_slot' end
        local slots={}
        for _=1,amount do local ok,sl=I.add(id,item,1,metadata,nil);if not ok then return false,sl end;slots[#slots+1]=sl;metadata=copyTable(metadata);metadata.serial=nil;metadata=prepareMetadata(item,metadata) end
        return true,slots[1]
    end
    slot=findDestinationSlot(inv,item,metadata,tonumber(slot));if not slot then return false,'no_slot' end
    local e=inv.items[slot] or {name=item,amount=0,metadata=metadata or {}};e.amount=e.amount+amount;inv.items[slot]=e;markDirty(id,slot);return true,slot
end
function I.remove(id,item,amount,metadata)
    if I.saving[id] then return false,'inventory_busy' end
    local inv=load(id);amount=math.floor(tonumber(amount) or 0)
    if not inv or amount~=amount or amount==math.huge or amount<=0 then return false end
    if I.count(id,item,metadata)<amount then return false end
    local left=amount
    for slot,e in pairs(inv.items) do
        if e.name==item and(metadata==nil or metadataEqual(e.metadata,metadata))and left>0 then
            local take=math.min(left,e.amount);e.amount=e.amount-take;left=left-take;if e.amount<=0 then inv.items[slot]=nil end;markDirty(id,slot)
        end
    end
    return left==0
end
function I.count(id,item,metadata)
    if I.saving[id] then return false,'inventory_busy' end
    local inv=load(id);if not inv then return 0 end
    local count=0;for _,e in pairs(inv.items) do if e.name==item and(metadata==nil or metadataEqual(e.metadata,metadata))then count=count+e.amount end end;return count
end
function I.getSlot(id,slot)if I.saving[id] then return false,'inventory_busy' end;local inv=load(id);return inv and inv.items[tonumber(slot)] or nil end
function I.removeSlot(id,slot,amount)
    if I.saving[id] then return false,'inventory_busy' end
    local inv=load(id);slot=tonumber(slot);amount=math.floor(tonumber(amount)or 0);local e=inv and inv.items[slot]
    if not e or amount~=amount or amount==math.huge or amount<=0 or e.amount<amount then return false end
    e.amount=e.amount-amount;if e.amount<=0 then inv.items[slot]=nil end;markDirty(id,slot);return true
end
function I.updateSlot(id,slot,metadata)
    if I.saving[id] then return false,'inventory_busy' end
    local inv=load(id);slot=tonumber(slot);local e=inv and inv.items[slot];if not e or type(metadata)~='table' then return false end
    e.metadata=copyTable(metadata);markDirty(id,slot);return true
end
function I.move(fromId,fromSlot,toId,amount,toSlot)
    if I.saving[fromId] or I.saving[toId] then return false,'inventory_busy' end
    local a,b=load(fromId),load(toId);fromSlot=tonumber(fromSlot);amount=math.floor(tonumber(amount)or 0);local e=a and a.items[fromSlot]
    if not a or not b or not e or amount~=amount or amount==math.huge or amount<=0 or e.amount<amount then return false,'invalid_move' end
    if fromId==toId and(not toSlot or tonumber(toSlot)==fromSlot)then return true,fromSlot end
    if fromId~=toId and not I.canCarry(b,e.name,amount,e.metadata)then return false,'cannot_carry'end
    local beforeA,beforeB=copyTable(a.items),copyTable(b.items);local dirtyA,dirtyB=copyTable(I.dirty[fromId]),copyTable(I.dirty[toId])
    if not I.removeSlot(fromId,fromSlot,amount)then return false,'source_changed'end
    local ok,slot=I.add(toId,e.name,amount,e.metadata,toSlot)
    if not ok then a.items=beforeA;b.items=beforeB;I.dirty[fromId]=dirtyA;I.dirty[toId]=dirtyB;return false,slot end
    local ids=fromId==toId and {fromId} or {fromId,toId}
    if not flushMany(ids) then a.items=beforeA;b.items=beforeB;I.dirty[fromId]=dirtyA;I.dirty[toId]=dirtyB;checkpoint();return false,'database_error' end
    return true,slot
end
function I.registerUsable(item,cb)assert(SzCoreItems[item],'invalid item');assert(type(cb)=='function','callback required');I.usable[item]=cb end
RegisterNetEvent('szcore_inventory:use',function(slot)
    local src=source;if not netAllowed(src,'use',150) then return end
    local inv=I.player(src);slot=tonumber(slot);local e=inv and inv.items[slot]
    if not e or not SzCoreItems[e.name] or not SzCoreItems[e.name].usable then return end
    local cb=I.usable[e.name];if cb then local ok,result=pcall(cb,src,e,slot);if not ok or result==false then return end end
    TriggerEvent('szcore_inventory:itemUsed',src,e.name,e.metadata,slot);TriggerClientEvent('szcore_inventory:refresh',src)
end)
RegisterNetEvent('szcore_inventory:give',function(target,slot,amount)
    local src=source;if not netAllowed(src,'give',250) then return end
    target,slot,amount=tonumber(target),tonumber(slot),math.floor(tonumber(amount)or 0)
    if not target or amount<=0 or not exports.szcore:ValidateDistance(src,target,3.0) then return end
    local a,aid=I.player(src);local b,bid=I.player(target);local e=a and a.items[slot]
    if not e or e.amount<amount or not I.canCarry(b,e.name,amount,e.metadata) then return end
    if I.move(aid,slot,bid,amount) then TriggerClientEvent('szcore_inventory:refresh',src);TriggerClientEvent('szcore_inventory:refresh',target) end
end)
AddEventHandler('szcore:server:playerLoaded',function(src,p)local id=idForCitizen(p.PlayerData.citizenid);ensure(id,'player',p.PlayerData.citizenid,40,120000);I.sourceInventory[src]=id;load(id)end)
AddEventHandler('playerDropped',function()local id=I.sourceInventory[source];if id then detached[id]=true;checkpoint();flush(id);I.sourceInventory[source]=nil end;netRate[source]=nil end)
AddEventHandler('onResourceStop',function(resource)if resource~=GetCurrentResourceName() then return end;checkpoint();for id in pairs(I.dirty) do flush(id) end;checkpoint()end)
CreateThread(function()while true do Wait(1500);local ids={};for id in pairs(I.dirty) do ids[#ids+1]=id end;for i=1,#ids do flush(ids[i]) end;if #ids>0 then checkpoint() end end end)
I.registerUsable('water',function(src)local _,id=I.player(src);if not I.remove(id,'water',1) then return false end;TriggerClientEvent('szcore_inventory:consume',src,'water');exports.szcore:SetMetadata(src,'thirst',math.min(100,(exports.szcore:GetMetadata(src,'thirst')or 0)+35))end)
I.registerUsable('sandwich',function(src)local _,id=I.player(src);if not I.remove(id,'sandwich',1) then return false end;TriggerClientEvent('szcore_inventory:consume',src,'sandwich');exports.szcore:SetMetadata(src,'hunger',math.min(100,(exports.szcore:GetMetadata(src,'hunger')or 0)+35))end)
I.registerUsable('weapon_pistol',function(src,item)TriggerClientEvent('szcore_inventory:equipWeapon',src,'WEAPON_PISTOL',tonumber(item.metadata and item.metadata.ammo)or 0)end)
exports('EnsureInventory',I.ensure);exports('GetPlayerInventory',function(src)local inv=I.player(src);return inv end);exports('GetInventory',I.get);exports('AddItem',I.add);exports('RemoveItem',I.remove);exports('GetItemCount',I.count);exports('GetItemBySlot',I.getSlot);exports('RemoveItemBySlot',I.removeSlot);exports('UpdateItemMetadata',I.updateSlot);exports('MoveItem',I.move);exports('RegisterUsableItem',I.registerUsable);exports('CanCarryItem',I.canCarry);exports('FlushInventory',flush)
registerSzCoreCallback('szcore_inventory:self',function(source)local inv=I.player(source);return inv end)
AddEventHandler('szcore:server:playerUnloaded',function(src)local id=I.sourceInventory[src];I.sourceInventory[src]=nil;if id then detached[id]=true;checkpoint();flush(id)end end)
CreateThread(function()
    MySQL.ready.await();while not exports.szcore:IsReady()do Wait(100)end
    local raw=LoadResourceFile(GetCurrentResourceName(),'inventory_recovery.json');local ok,rows=pcall(json.decode,raw or '{}')
    if not ok or type(rows)~='table' then print('[SzCore inventory] Invalid recovery file: preserve it for manual recovery.');return end
    for id,inv in pairs(rows)do
        if type(inv)=='table' and type(inv.items)=='table' and not I.cache[id] then
            ensure(id,inv.owner_type,inv.owner_id,inv.max_slots,inv.max_weight)
            local restored={};for slot,e in pairs(inv.items) do restored[tonumber(slot)]=e end;inv.items=restored
            I.cache[id]=inv;I.dirty[id]={};for slot=1,inv.max_slots do I.dirty[id][slot]=true end;detached[id]=true;flush(id)
        end
    end
    checkpoint();recoveryReady=true
end)
