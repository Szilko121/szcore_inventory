local open = false
local function serialize(inv)
    local items = {}
    if inv and inv.items then
        for slot, entry in pairs(inv.items) do
            local def = SzCoreItems[entry.name] or {}
            items[#items + 1] = {slot=slot,name=entry.name,amount=entry.amount,metadata=entry.metadata or {},label=def.label or entry.name,weight=def.weight or 0,usable=def.usable == true}
        end
        table.sort(items, function(a,b) return a.slot < b.slot end)
    end
    return {items=items,maxSlots=inv and inv.max_slots or 40,maxWeight=inv and inv.max_weight or 120000}
end
local function refresh()
    local inv = exports.szcore:AwaitCallback('szcore_inventory:self')
    if open then SendNUIMessage({action='inventory',data=serialize(inv)}) end
end
local function setOpen(state)
    state = state == true
    if open == state then return end
    open = state
    SetNuiFocus(state, state)
    SendNUIMessage({action='visible',show=state})
    if state then refresh() end
end
RegisterCommand('inventory', function() if exports.szcore:IsPlayerLoaded() then setOpen(not open) end end, false)
RegisterKeyMapping('inventory', 'SzCore Inventory', 'keyboard', 'F2')
RegisterNUICallback('close', function(_,cb) setOpen(false);cb({ok=true}) end)
RegisterNUICallback('use', function(data,cb) local slot=tonumber(data.slot);if slot then TriggerServerEvent('szcore_inventory:use',slot);SetTimeout(250,refresh) end;cb({ok=true}) end)
RegisterNUICallback('give', function(data,cb) local slot,target,amount=tonumber(data.slot),tonumber(data.target),tonumber(data.amount);if slot and target and amount then TriggerServerEvent('szcore_inventory:give',target,slot,amount);SetTimeout(250,refresh) end;cb({ok=true}) end)
RegisterNetEvent('szcore_inventory:refresh', refresh)
RegisterNetEvent('szcore_inventory:consume',function(item)local ped=PlayerPedId();TaskStartScenarioInPlace(ped,item=='water' and 'WORLD_HUMAN_DRINKING' or 'WORLD_HUMAN_EATING',0,true);Wait(1800);ClearPedTasks(ped)end)
RegisterNetEvent('szcore_inventory:equipWeapon',function(weapon,ammo)local ped=PlayerPedId();local hash=joaat(weapon);GiveWeaponToPed(ped,hash,math.max(0,tonumber(ammo) or 0),false,true)end)
exports('OpenInventory',function()setOpen(true)end);exports('CloseInventory',function()setOpen(false)end);exports('UseSlot',function(slot)TriggerServerEvent('szcore_inventory:use',slot)end)
