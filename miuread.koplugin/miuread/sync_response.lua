-- Sync response/progress parsing deep module, extracted from sync.lua.
--
-- MiuRead 4.5.34 moved the pure response-confirmation, progress-node, remote
-- progress selection and position-matching helpers out of sync.lua so they are
-- independently unit-testable. sync.lua keeps thin local aliases.
local U = require("miuread.util")
local Protocol = require("miuread.protocol")
local ProgressPosition = require("miuread.progress_position")
local chapter_uid = ProgressPosition.chapter_uid
local chapter_index = ProgressPosition.chapter_index
local chapter_words = ProgressPosition.chapter_words

local M = {}

local function report_ratio_from_position(position)
    position = type(position) == "table" and position or {}
    if position.standalone == true and tonumber(position.chapter_ratio) ~= nil then
        return U.clamp(tonumber(position.chapter_ratio), 0, 1)
    end
    if position.standalone == true and tonumber(position.chapter_percent) ~= nil then
        return U.clamp(tonumber(position.chapter_percent) / 100, 0, 1)
    end
    return U.clamp((tonumber(position.progress) or 0) / 100, 0, 1)
end

local function response_confirmation(value, depth, path, seen)
    if type(value) ~= "table" or (depth or 0) > 6 then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    path = path or "$"
    local succ = rawget(value, "succ")
    if succ == true or tonumber(succ) == 1 then return true, path .. ".succ", value end
    for _, key in ipairs({"data", "result", "payload", "response", "book", "reader"}) do
        local child = rawget(value, key)
        if type(child) == "table" then
            local ok, found_path, node = response_confirmation(child, (depth or 0) + 1, path .. "." .. key, seen)
            if ok then return true, found_path, node end
        end
    end
    for key, child in pairs(value) do
        if type(child) == "table" then
            local ok, found_path, node = response_confirmation(child, (depth or 0) + 1, path .. "." .. tostring(key), seen)
            if ok then return true, found_path, node end
        end
    end
    return false
end

local function accepted(value)
    return response_confirmation(value, 0, "$", {})
end

local function deep_field(value, names, depth, seen)
    if type(value) ~= "table" or (depth or 0) > 6 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    for _, name in ipairs(names) do
        local found = rawget(value, name)
        if found ~= nil and type(found) ~= "table" then return found end
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            local found = deep_field(child, names, (depth or 0) + 1, seen)
            if found ~= nil then return found end
        end
    end
end

local function response_synckey(value)
    return deep_field(value, {"synckey", "syncKey"}, 0, {})
end

local function response_summary(value, meta)
    local out = {}
    if type(meta) == "table" then
        if meta.code then out[#out + 1] = "HTTP=" .. tostring(meta.code) end
        if meta.length then out[#out + 1] = "bytes=" .. tostring(meta.length) end
        if meta.content_type then out[#out + 1] = "type=" .. tostring(meta.content_type) end
    end
    if type(value) ~= "table" then
        out[#out + 1] = "non-table-response"
        return table.concat(out, ", ")
    end
    local ok, path = accepted(value)
    out[#out + 1] = ok and ("succ=1@" .. tostring(path)) or "succ=not-found"
    local code = deep_field(value, {"errCode", "errcode", "code"}, 0, {})
    local message = deep_field(value, {"errMsg", "errmsg", "message", "msg"}, 0, {})
    if code ~= nil then out[#out + 1] = "code=" .. tostring(code) end
    if message ~= nil then out[#out + 1] = "message=" .. U.first_line(message, 140) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    if #keys > 0 then out[#out + 1] = "keys=" .. table.concat(keys, "|") end
    return table.concat(out, ", ")
end

local function progress_from_node(node, expected_book_id)
    if type(node) ~= "table" then return nil end
    local node_book_id = rawget(node, "bookId") or rawget(node, "book_id")
    if node_book_id ~= nil and tostring(node_book_id) ~= tostring(expected_book_id or "") then return nil end
    local p = tonumber(rawget(node, "progress") or rawget(node, "readingProgress")
        or rawget(node, "progressPercent") or rawget(node, "bookProgress"))
    if p == nil then return nil end
    -- The Web API normally returns 0-100. Only true fractions are expanded;
    -- a literal 1 must remain 1%, not be mistaken for 100%.
    if p > 0 and p < 1 then p = p * 100 end
    return {
        percent = U.clamp(p, 0, 100),
        chapter_uid = rawget(node, "chapterUid") or rawget(node, "chapterId") or rawget(node, "chapter_uid"),
        chapter_idx = rawget(node, "chapterIdx") or rawget(node, "chapterIndex") or rawget(node, "chapter_idx"),
        offset = rawget(node, "chapterOffset") or rawget(node, "chapterPos") or rawget(node, "offset"),
        updated_at = rawget(node, "updateTime") or rawget(node, "updatedAt") or rawget(node, "update_time"),
        raw = node,
    }
end

local function response_progress(value, expected_book_id)
    if type(value) ~= "table" then return nil end
    local queue = {value}
    local seen = {}
    local allowed = {"book", "data", "result", "reader", "progressInfo", "bookProgress", "payload", "books", "bookList", "progresses"}
    local index = 1
    while index <= #queue and index <= 32 do
        local node = queue[index]; index = index + 1
        if type(node) == "table" and not seen[node] then
            seen[node] = true
            local found = progress_from_node(node, expected_book_id)
            if found then return found end
            for _, key in ipairs(allowed) do
                local child = rawget(node, key)
                if type(child) == "table" then queue[#queue + 1] = child end
            end
            for i = 1, math.min(#node, 20) do
                if type(node[i]) == "table" then queue[#queue + 1] = node[i] end
            end
        end
    end
end

local function normalize_timestamp(value)
    local ts=tonumber(value)
    if not ts then return nil end
    if ts>100000000000 then ts=math.floor(ts/1000) end
    return ts
end

local function sourced_progress(value, expected_book_id, source)
    local progress=response_progress(value, expected_book_id)
    if not progress then return nil end
    progress.source=tostring(source or "unknown")
    progress.updated_at=normalize_timestamp(progress.updated_at)
    progress.fetched_at=os.time()
    return progress
end

local function choose_remote_progress(web,agent,threshold)
    threshold=math.max(0,tonumber(threshold) or 2)
    if web and agent then
        local delta=math.abs((tonumber(web.percent) or 0)-(tonumber(agent.percent) or 0))
        if delta>threshold then
            return {
                conflict=true,
                web=web,
                agent=agent,
                source="conflict",
                fetched_at=os.time(),
            }
        end
        local wt,at=normalize_timestamp(web.updated_at) or 0,normalize_timestamp(agent.updated_at) or 0
        local selected=wt>at and web or agent
        if wt==at then selected=web end
        selected.sources={web=web,agent=agent}
        selected.source=(wt==at and "web_cookie" or selected.source)
        return selected
    end
    local selected=web or agent
    if selected then selected.sources={web=web,agent=agent} end
    return selected
end

local function positions_match(submitted,remote,threshold)
    submitted=type(submitted)=="table" and submitted or {}
    remote=type(remote)=="table" and remote or {}
    if remote.conflict then return false,"remote_source_conflict" end
    threshold=math.max(0,tonumber(threshold) or 2)
    local submitted_uid=tostring(submitted.chapter_uid or submitted.chapterUid or "")
    local remote_uid=tostring(remote.chapter_uid or remote.chapterUid or "")
    if submitted_uid~="" and remote_uid~="" and submitted_uid~=remote_uid then
        return false,"chapter_uid_mismatch"
    end

    -- chapterUid + chapterOffset are the authoritative reading coordinates.
    -- Whole-book percentages may differ when the catalog contains a different
    -- number of structural chapters, so never reject an exact coordinate match
    -- merely because the derived percentages disagree.
    if submitted_uid~="" and remote_uid~="" then
        local a,b=tonumber(submitted.offset or submitted.chapter_offset),tonumber(remote.offset or remote.chapter_offset)
        local chapter_words=tonumber(submitted.chapter_word_count) or 0
        if a~=nil and b~=nil then
            local tolerance=submitted.native_offset==true and 12
                or math.max(12,math.floor(chapter_words*0.005))
            if math.abs(a-b)<=tolerance then return true,"chapter_offset_match" end
            return false,"chapter_offset_mismatch"
        end
    end

    local submitted_percent=tonumber(submitted.progress)
    local remote_percent=tonumber(remote.percent)
    if submitted_percent~=nil and remote_percent~=nil
        and math.abs(submitted_percent-remote_percent)>threshold then
        return false,"progress_mismatch"
    end
    return true,"percent_match"
end

local function context_from(state, fallback)
    fallback = fallback or {}
    if type(state) ~= "table" then state = {} end
    return {
        psvts = Protocol.optional(state.psvts) or Protocol.optional(fallback.psvts),
        pclts = Protocol.optional(state.pclts) or Protocol.optional(fallback.pclts),
        token = Protocol.optional(state.token) or Protocol.optional(fallback.token),
        reader_url = state.url or fallback.reader_url,
        app_id = fallback.app_id or Protocol.app_id(Protocol.USER_AGENT),
        chapters = fallback.chapters,
        context_updated_at = tonumber(fallback.context_updated_at or 0) or 0,
    }
end

local function catalog_progress_from_remote(remote, chapters)
    if type(remote)~="table" then return remote end
    chapters=type(chapters)=="table" and chapters or {}
    remote.raw_percent=tonumber(remote.raw_percent or remote.percent)
    if #chapters==0 then return remote end

    local wanted_uid=tostring(remote.chapter_uid or "")
    local wanted_idx=tonumber(remote.chapter_idx)
    local selected,selected_pos,before,total=nil,nil,0,0
    for index,chapter in ipairs(chapters) do
        local words=chapter_words(chapter)
        local uid=tostring(chapter_uid(chapter) or "")
        local idx=chapter_index(chapter,index)
        local matches=(wanted_uid~="" and uid==wanted_uid)
            or (wanted_uid=="" and wanted_idx~=nil and (idx==wanted_idx or index==wanted_idx or index-1==wanted_idx))
        if not selected and matches then selected=chapter; selected_pos=index end
        if not selected then before=before+words end
        total=total+words
    end
    if not selected or total<=0 then return remote end

    local words=chapter_words(selected)
    local offset=tonumber(remote.offset)
    if offset==nil then return remote end
    offset=math.max(0,math.min(words,offset))
    local calculated=U.clamp(((before+offset)/total)*100,0,100)
    remote.calculated_percent=calculated
    remote.percent=calculated
    remote.position_basis="chapter_offset"
    remote.chapter_uid=chapter_uid(selected) or remote.chapter_uid
    remote.chapter_idx=chapter_index(selected,selected_pos)
    remote.offset=offset
    remote.chapter_word_count=words
    remote.total_word_count=total
    remote.words_before=before
    return remote
end

M.report_ratio_from_position = report_ratio_from_position
M.response_confirmation = response_confirmation
M.accepted = accepted
M.deep_field = deep_field
M.response_synckey = response_synckey
M.response_summary = response_summary
M.progress_from_node = progress_from_node
M.response_progress = response_progress
M.normalize_timestamp = normalize_timestamp
M.sourced_progress = sourced_progress
M.choose_remote_progress = choose_remote_progress
M.positions_match = positions_match
M.context_from = context_from
M.catalog_progress_from_remote = catalog_progress_from_remote

return M
