-- Pure progress-position math for MiuRead sync.
--
-- sync.lua keeps orchestration; this module owns chapter-field normalisation,
-- local-chapter scanning, ratio -> chapter/offset mapping and the two-stage
-- resolve used by Sync:position (precise map first, local fallback second).
-- Everything is injectable and testable without KOReader.

local U = require("miuread.util")
local BookIntegrity = require("miuread.book_integrity")

local ProgressPosition = {}

function ProgressPosition.chapter_uid(chapter)
    return chapter and (chapter.chapterUid or chapter.uid or chapter.chapter_uid)
end

function ProgressPosition.chapter_index(chapter, fallback)
    return tonumber(chapter and (chapter.chapterIdx or chapter.index or chapter.chapter_index or chapter.chapter_idx))
        or tonumber(fallback or 0) or 0
end

function ProgressPosition.chapter_words(chapter)
    return math.max(1, tonumber(chapter and (chapter.wordCount or chapter.word_count) or 0) or 0)
end

function ProgressPosition.readable_local_chapter_count(chapters)
    local count = 0
    for _, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        if type(chapter) == "table" and chapter.structural ~= true
            and tostring(ProgressPosition.chapter_uid(chapter) or "") ~= "" then
            count = count + 1
        end
    end
    return count
end

function ProgressPosition.local_chapter_by_uid(chapters, wanted_uid)
    wanted_uid = tostring(wanted_uid or "")
    if wanted_uid == "" then return nil end
    for index, chapter in ipairs(type(chapters) == "table" and chapters or {}) do
        if type(chapter) == "table" and tostring(ProgressPosition.chapter_uid(chapter) or "") == wanted_uid then
            return chapter, index
        end
    end
end

function ProgressPosition.map_position(chapters, ratio, fallback)
    chapters = type(chapters) == "table" and chapters or {}
    ratio = U.clamp(tonumber(ratio) or 0, 0, 1)
    fallback = fallback or {}
    if #chapters == 0 then
        return {
            progress = U.clamp(ratio * 100, 0, 100),
            chapter_uid = fallback.chapter_uid or 0,
            chapter_index = tonumber(fallback.chapter_index or 0) or 0,
            offset = tonumber(fallback.offset or 0) or 0,
            summary = fallback.summary or "",
        }
    end
    local total = 0
    for _, ch in ipairs(chapters) do
        total = total + ProgressPosition.chapter_words(ch)
    end
    local target, acc = ratio * total, 0
    for index, ch in ipairs(chapters) do
        local words = ProgressPosition.chapter_words(ch)
        if target <= acc + words or index == #chapters then
            return {
                progress = U.clamp(ratio * 100, 0, 100),
                chapter_uid = ch.uid or 0,
                chapter_index = tonumber(ch.index) or index,
                offset = math.max(0, math.floor(target - acc)),
                summary = ch.title or fallback.summary or "",
            }
        end
        acc = acc + words
    end
end

-- Two-stage resolve mirroring Sync:position. Returns the precise map result,
-- or a local-map fallback tagged with safety/source metadata.
function ProgressPosition.resolve(local_map, full_map, ratio, options)
    options = type(options) == "table" and options or {}
    local mapped, map_error = BookIntegrity.position_from_maps(local_map, full_map, ratio, options)
    if mapped then return mapped end
    local fallback = ProgressPosition.map_position(local_map, ratio, options)
    fallback.safe = BookIntegrity.maps_equivalent(local_map, full_map)
    fallback.mapping_error = map_error
    fallback.source = fallback.safe and "equivalent_local_map" or "unsafe_local_ratio"
    return fallback
end

return ProgressPosition
