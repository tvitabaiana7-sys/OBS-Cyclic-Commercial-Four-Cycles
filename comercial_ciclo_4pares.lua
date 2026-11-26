obs = obslua

local SLOT_COUNT = 4
local slots = {}
local active_slot = nil
local active_ad_scene = nil
local return_scene_name = nil
local film_started_at = nil
local ad_finished = false
local in_ad_phase = false
local connected_media = {}
local warned = {}
local last_media_scan = 0
local MEDIA_RETRY_SECONDS = 2

for i = 1, SLOT_COUNT do
    slots[i] = { film = "", ad = "", minutes = 2, media_names = {} }
end

local function trim(s)
    if s == nil then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function source_by_name(name)
    name = trim(name)
    if name == "" then return nil end
    return obs.obs_get_source_by_name(name)
end

local function current_scene()
    local src = obs.obs_frontend_get_current_scene()
    if src == nil then return nil end
    local name = obs.obs_source_get_name(src)
    obs.obs_source_release(src)
    return name
end

local function switch_scene(name)
    local src = source_by_name(name)
    if src == nil then
        obs.script_log(obs.LOG_WARNING, "Ciclo de comerciais: cena não encontrada: " .. tostring(name))
        return false
    end
    obs.obs_frontend_set_current_scene(src)
    obs.obs_source_release(src)
    return true
end

local function slot_for_film(name)
    for i = 1, SLOT_COUNT do
        if slots[i].film ~= "" and slots[i].film == name then return i end
    end
    return nil
end

local function on_media_ended(calldata)
    if not in_ad_phase or active_slot == nil then return end
    local ended = obs.calldata_source(calldata, "source")
    if ended == nil then return end
    local name = obs.obs_source_get_name(ended)
    for _, media_name in ipairs(slots[active_slot].media_names) do
        if name == media_name then
            ad_finished = true
            obs.script_log(obs.LOG_INFO, "Ciclo de comerciais: terminou " .. name)
            return
        end
    end
end

local function disconnect_media()
    for _, media in ipairs(connected_media) do
        if media.handler ~= nil then
            obs.signal_handler_disconnect(media.handler, "media_ended", on_media_ended)
        end
        if media.source ~= nil then obs.obs_source_release(media.source) end
    end
    connected_media = {}
    for i = 1, SLOT_COUNT do slots[i].media_names = {} end
end

local function append_unique(list, value)
    for _, existing in ipairs(list) do
        if existing == value then return end
    end
    table.insert(list, value)
end

local function connect_one_media(src, slot_index, registered)
    local source_id = obs.obs_source_get_id(src)
    if source_id == "ffmpeg_source" or source_id == "vlc_source" then
        local media_name = obs.obs_source_get_name(src)
        append_unique(slots[slot_index].media_names, media_name)
        if not registered[media_name] then
            local ref = obs.obs_get_source_by_name(media_name)
            if ref ~= nil then
                local handler = obs.obs_source_get_signal_handler(ref)
                if handler ~= nil then
                    obs.signal_handler_connect(handler, "media_ended", on_media_ended)
                    table.insert(connected_media, { name = media_name, source = ref, handler = handler })
                    registered[media_name] = true
                else
                    obs.obs_source_release(ref)
                end
            end
        end
        return
    end

    -- Também percorre cenas e grupos aninhados dentro da cena do comercial.
    local child_scene = obs.obs_scene_from_source(src)
    if child_scene == nil and obs.obs_group_from_source ~= nil then
        child_scene = obs.obs_group_from_source(src)
    end
    if child_scene ~= nil then
        local items = obs.obs_scene_enum_items(child_scene)
        if items ~= nil then
            for _, child_item in ipairs(items) do
                local child_source = obs.obs_sceneitem_get_source(child_item)
                if child_source ~= nil then
                    connect_one_media(child_source, slot_index, registered)
                end
            end
            obs.sceneitem_list_release(items)
        end
    end
end

local function connect_media()
    disconnect_media()
    local registered = {}
    for i = 1, SLOT_COUNT do
        local ad_name = trim(slots[i].ad)
        if ad_name ~= "" then
            local scene_src = source_by_name(ad_name)
            if scene_src ~= nil then
                local scene = obs.obs_scene_from_source(scene_src)
                if scene ~= nil then
                    local items = obs.obs_scene_enum_items(scene)
                    if items ~= nil then
                        for _, item in ipairs(items) do
                            local src = obs.obs_sceneitem_get_source(item)
                            if src ~= nil then
                                connect_one_media(src, i, registered)
                            end
                        end
                        obs.sceneitem_list_release(items)
                    end
                end
                obs.obs_source_release(scene_src)
            end
        end
    end
end

local function restart_slot_media(index)
    for _, media_name in ipairs(slots[index].media_names) do
        local src = source_by_name(media_name)
        if src ~= nil then
            if obs.obs_source_media_restart ~= nil then obs.obs_source_media_restart(src) end
            obs.obs_source_release(src)
        end
    end
end

local function start_ad(index)
    if trim(slots[index].ad) == "" then
        if not warned["ad" .. index] then
            obs.script_log(obs.LOG_WARNING, "Ciclo " .. index .. ": selecione a cena do comercial nas propriedades.")
            warned["ad" .. index] = true
        end
        return
    end
    if #slots[index].media_names == 0 then
        if not warned["media" .. index] then
            obs.script_log(obs.LOG_WARNING, "Ciclo " .. index .. ": não encontrei fonte Mídia/VLC dentro da cena de comercial selecionada. Confira e recarregue o script.")
            warned["media" .. index] = true
        end
        return
    end
    if not switch_scene(slots[index].ad) then return end
    active_slot = index
    active_ad_scene = slots[index].ad
    return_scene_name = slots[index].film
    film_started_at = nil
    in_ad_phase = true
    ad_finished = false
    restart_slot_media(index)
    obs.script_log(obs.LOG_INFO, "Ciclo " .. index .. ": comercial iniciado; retornará para " .. return_scene_name)
end

local function tick()
    local current = current_scene()
    if current == nil then return end

    -- OBS pode carregar os scripts antes das cenas/fontes. Reprocura cenas de anúncio
    -- que ainda não têm mídia associada, sem exigir editar e recarregar o script.
    local now = os.time()
    if now - last_media_scan >= MEDIA_RETRY_SECONDS then
        local needs_scan = false
        for i = 1, SLOT_COUNT do
            if trim(slots[i].ad) ~= "" and #slots[i].media_names == 0 then
                needs_scan = true
                break
            end
        end
        if needs_scan then
            connect_media()
        end
        last_media_scan = now
    end

    if in_ad_phase then
        if current ~= active_ad_scene then
            -- Troca manual durante o comercial cancela apenas o retorno automático em curso.
            in_ad_phase = false
            ad_finished = false
            active_slot = nil
            active_ad_scene = nil
            return_scene_name = nil
            film_started_at = nil
            return
        end
        if ad_finished and return_scene_name ~= nil then
            local destination = return_scene_name
            if switch_scene(destination) then
                in_ad_phase = false
                ad_finished = false
                active_slot = nil
                active_ad_scene = nil
                return_scene_name = nil
                film_started_at = os.time()
                obs.script_log(obs.LOG_INFO, "Ciclo de comerciais: voltou para " .. destination)
            end
        end
        return
    end

    local index = slot_for_film(current)
    if index == nil then
        film_started_at = nil
        active_slot = nil
        return
    end

    if active_slot ~= index or film_started_at == nil then
        active_slot = index
        film_started_at = os.time()
        return
    end

    local minutes = math.max(1, tonumber(slots[index].minutes) or 2)
    if os.time() - film_started_at >= minutes * 60 then
        start_ad(index)
    end
end

local function populate_scene_list(prop)
    obs.obs_property_list_clear(prop)
    obs.obs_property_list_add_string(prop, "— selecione uma cena —", "")
    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, src in ipairs(scenes) do
            local name = obs.obs_source_get_name(src)
            obs.obs_property_list_add_string(prop, name, name)
        end
        obs.source_list_release(scenes)
    end
end

local function add_scene_selector(props, key, label)
    local prop = obs.obs_properties_add_list(props, key, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    populate_scene_list(prop)
end

function script_description()
    return "Quatro ciclos independentes com nova tentativa automática de localizar as mídias após o OBS carregar as cenas."
end

function script_defaults(settings)
    for i = 1, SLOT_COUNT do
        obs.obs_data_set_default_string(settings, "film_scene_" .. i, "")
        obs.obs_data_set_default_string(settings, "ad_scene_" .. i, "")
        obs.obs_data_set_default_int(settings, "film_minutes_" .. i, 2)
    end
end

function script_properties()
    local props = obs.obs_properties_create()
    for i = 1, SLOT_COUNT do
        obs.obs_properties_add_text(props, "slot_label_" .. i, "── CICLO " .. i .. " ──", obs.OBS_TEXT_INFO)
        add_scene_selector(props, "film_scene_" .. i, "Cena do filme " .. i)
        obs.obs_properties_add_int(props, "film_minutes_" .. i, "Minutos até o comercial " .. i, 1, 1440, 1)
        add_scene_selector(props, "ad_scene_" .. i, "Cena do comercial " .. i)
    end
    return props
end

function script_update(settings)
    for i = 1, SLOT_COUNT do
        slots[i].film = obs.obs_data_get_string(settings, "film_scene_" .. i)
        slots[i].ad = obs.obs_data_get_string(settings, "ad_scene_" .. i)
        slots[i].minutes = obs.obs_data_get_int(settings, "film_minutes_" .. i)
    end
    connect_media()
    film_started_at = nil
    active_slot = nil
    active_ad_scene = nil
    return_scene_name = nil
    in_ad_phase = false
    ad_finished = false
    warned = {}
    last_media_scan = 0
end

function script_load(settings)
    script_update(settings)
    obs.timer_add(tick, 500)
end

function script_unload()
    obs.timer_remove(tick)
    disconnect_media()
end
