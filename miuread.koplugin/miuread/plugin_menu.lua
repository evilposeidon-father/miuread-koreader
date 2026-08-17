local PluginSettings=require("miuread.plugin_settings")

local M={}

local function comment_and_thought_menu(plugin)
    return {
        {text="我的想法",callback=function()
            plugin:_show_reader_records("thought",function() plugin:_show_koreader_reader_menu() end)
        end},
        {text="想法",post_text=plugin:_thoughts_enabled_label(),checked_func=function()
            return plugin:_thoughts_enabled()
        end,keep_menu_open=true,callback=function() plugin:_toggle_thoughts_enabled() end},
        {text="想法显示设置",sub_item_table_func=function() return plugin:thought_font_settings_menu() end},
        {text="评论数据管理",sub_item_table_func=function() return PluginSettings.comment_data(plugin) end},
    }
end

function M.home(plugin)
    plugin:maybe_auto_check_update(false)
    return {
        {text="我的书架",callback=plugin:safe("shelf",function() plugin:show_shelf(false,false,"account") end)},
        {text="搜索书籍",callback=plugin:safe("search",function() plugin:search_dialog() end)},
        {text=plugin:_download_menu_text(),callback=plugin:safe("downloads",function() plugin:show_downloads() end)},
        {text="公众号",callback=plugin:safe("mp-shelf",function() plugin:show_mp_shelf(false) end)},
        {text="账号",sub_item_table_func=function() return plugin:account_menu() end},
        {text="插件设置",sub_item_table_func=function() return PluginSettings.menu(plugin) end},
    }
end

function M.reader(plugin)
    plugin:maybe_auto_check_update(false)
    local current_path=plugin:_current_document_path()
    local mp_context=plugin.mp and plugin.mp:identify_path(current_path) or nil
    if mp_context then
        return {
            {text="返回文章列表",callback=plugin:safe("mp-back",function() plugin:open_mp_account_by_id(mp_context.bookId,mp_context.account_title) end)},
            {text="上一篇",callback=plugin:safe("mp-prev",function() plugin:open_mp_neighbor(-1) end)},
            {text="下一篇",callback=plugin:safe("mp-next",function() plugin:open_mp_neighbor(1) end)},
            {text="当前文章",sub_item_table_func=function() return plugin:current_mp_article_menu(mp_context) end},
            {text=plugin:_download_menu_text(),callback=function() plugin:show_downloads() end},
            {text="插件设置",sub_item_table_func=function() return PluginSettings.menu(plugin) end},
        }
    end
    local rows={
        {text="当前书籍",sub_item_table_func=function() return plugin:current_book_menu() end},
    }
    do
        local external_annotations_available=plugin:_external_annotations_menu_available()
        rows[#rows+1]={
            text="本地书划线与想法",
            post_text=external_annotations_available and nil or "仅支持本地重排书籍",
            enabled_func=function() return external_annotations_available end,
            sub_item_table_func=function() return plugin:external_annotations_menu_items() end,
        }
    end
    rows[#rows+1]={text="打开觅阅书架",callback=plugin:safe("shelf",function() plugin:show_shelf(false,false,"account") end)}
    rows[#rows+1]={text=plugin:_download_menu_text(),callback=function() plugin:show_downloads() end}
    rows[#rows+1]={text="评论与想法",sub_item_table_func=function() return comment_and_thought_menu(plugin) end}
    rows[#rows+1]={text="插件设置",sub_item_table_func=function() return PluginSettings.menu(plugin) end}
    return rows
end

return M
