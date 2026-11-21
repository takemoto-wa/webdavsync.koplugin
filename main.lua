--[[
    WebDAV同步应用插件 (webdavsync.koplugin) v2.2 -- KOReader plugin

    Two features, both using the WebDAV account configured in KOReader itself
    (settings/cloudstorage.lua). No address, username or password is stored here.

    1) Upload screenshots  (<data>/screenshots/*.png) to
         <webdav>/<account url>/koreader-screenshots/
    2) Sync reading progress across devices via
         <webdav>/<account url>/koreader-progress/<book-digest>.txt
       Each book is identified by its partial_md5_checksum (fallback: md5 of the
       file name), so the same book on two devices shares one progress record.

    UI entries:
      * Tools menu: "WebDAV同步应用插件" -> "上传截图到云端" and
        "阅读进度同步" submenu; the same actions in the Gesture Manager
        (General section).
      * Automatic: on book open -> compare local vs remote progress and keep
        the furthest one (pushing local up when it is ahead); on page turn ->
        delayed push; on book close -> push progress.

    Install: copy this folder to koreader/plugins/webdavsync.koplugin,
    restart KOReader, then configure WebDAV in KOReader "Cloud storage".
]]

local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local ConfirmBox      = require("ui/widget/confirmbox")
local NetworkMgr      = require("ui/network/manager")
local WebDavApi       = require("apps/cloudstorage/webdavapi")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher      = require("dispatcher")
local Event           = require("ui/event")
local Math            = require("optmath")
local Device          = require("device")
local util            = require("util")
local md5             = require("ffi/sha2").md5
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")

local SCREENSHOT_DIR = "koreader-screenshots"
local PROGRESS_DIR   = "koreader-progress"
local STATE_FILE     = "webdavsync_upload.lua"
local SETTINGS_FILE  = "webdavsync_settings.lua"
local UPLOAD_KEY     = "uploaded"
local MAX_SIZE       = 150 * 1024 * 1024
local PUSH_DELAY     = 8   -- seconds after the last page turn
local AUTO_PULL_DELAY = 1  -- seconds after book open

local A_SCREENSHOT = "webdavsync_action"
local E_SCREENSHOT = "WebDavSyncAction"
local A_PUSH = "webdavsync_push_progress"
local E_PUSH = "WebDavSyncPushProgress"
local A_PULL = "webdavsync_pull_progress"
local E_PULL = "WebDavSyncPullProgress"

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 5 })
end

local function get_settings()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. SETTINGS_FILE)
end

local function is_auto_progress()
    local s = get_settings():readSetting("auto_progress")
    return s ~= false  -- enabled by default
end

local function toggle_auto_progress()
    local cfg = get_settings()
    local cur = is_auto_progress()
    cfg:saveSetting("auto_progress", not cur)
    cfg:flush()
    return not cur
end

local function get_device_info()
    local s = get_settings()
    local name = s:readSetting("device_name")
    if not name or name == "" then
        name = Device.model or "KOReader"
        s:saveSetting("device_name", name)
        s:flush()
    end
    local id = G_reader_settings:readSetting("device_id")
    if not id then
        id = md5(name .. tostring(os.time()))
        G_reader_settings:saveSetting("device_id", id)
    end
    return name, id
end

-- Read WebDAV credentials and the remote path from KOReader's own config.
local function get_server()
    local ok, settings = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/cloudstorage.lua")
    end)
    if not ok or not settings then return nil end
    local servers = settings:readSetting("cs_servers") or {}
    local candidates = {}
    for idx, server in pairs(servers) do
        if type(server) == "table" and server.type == "webdav" and server.address
                and server.username and server.password then
            table.insert(candidates, {
                server = server,
                order = tonumber(server.order) or tonumber(idx) or 0,
            })
        end
    end
    if #candidates == 0 then return nil end
    table.sort(candidates, function(a, b) return a.order > b.order end)
    return candidates[1].server
end

local function get_remote_dir(server, subdir)
    local sub = type(server.url) == "string" and server.url or ""
    if sub ~= "" and not sub:match("/$") then sub = sub .. "/" end
    return sub .. subdir
end

-- ------------------------- screenshot upload -------------------------

local function collect_new()
    local dir = DataStorage:getDataDir() .. "/screenshots"
    local mark = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. STATE_FILE)
    local uploaded = mark:readSetting(UPLOAD_KEY) or {}
    local files = {}
    -- lfs.dir returns TWO values (iterator, dir object); dropping the second
    -- makes generic-for fail with "directory metatable expected".
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or not iter then
        logger.warn("webdavsync: cannot open dir", dir, iter)
        return files, mark, uploaded
    end
    for name in iter, dir_obj do
        if name:lower():match("%.png$") then
            local path = dir .. "/" .. name
            local size = lfs.attributes(path, "size") or 0
            if size > 0 and size <= MAX_SIZE and not uploaded[name] then
                files[#files + 1] = { name = name, path = path }
            end
        end
    end
    if dir_obj then pcall(function() dir_obj:close() end) end
    table.sort(files, function(a, b) return a.name < b.name end)
    return files, mark, uploaded
end

local function start_upload()
    local server = get_server()
    if not server then
        notify("未找到 WebDAV 配置，请先在 KOReader 的「云存储」中添加账户。", 7)
        return
    end
    if NetworkMgr:willRerunWhenOnline(function() start_upload() end) then return end

    local files, mark, uploaded = collect_new()
    logger.info("webdavsync: new screenshots", #files)
    if #files == 0 then
        notify("没有待上传的新截图。", 3)
        return
    end

    local remote_dir = get_remote_dir(server, SCREENSHOT_DIR)
    local base = WebDavApi:getJoinedPath(server.address, remote_dir)
    logger.info("webdavsync: target", remote_dir)
    pcall(function()
        local code = WebDavApi:createFolder(base .. "/", server.username,
                                            server.password, remote_dir)
        logger.info("webdavsync: MKCOL", code)
    end)

    local index, ok_count, fail_count = 1, 0, 0
    local function step()
        if index > #files then
            notify(string.format("截图上传完成：成功 %d 张，失败 %d 张。",
                                 ok_count, fail_count), 7)
            return
        end
        local file = files[index]
        local url = WebDavApi:getJoinedPath(base, file.name)
        local code
        pcall(function()
            code = WebDavApi:uploadFile(url, server.username, server.password, file.path)
        end)
        if type(code) == "number" and code >= 200 and code < 300 then
            uploaded[file.name] = true
            ok_count = ok_count + 1
            pcall(function()
                mark:saveSetting(UPLOAD_KEY, uploaded)
                mark:flush()
            end)
        else
            fail_count = fail_count + 1
            logger.warn("webdavsync: failed", file.name, code)
        end
        index = index + 1
        UIManager:scheduleIn(0.05, step)
    end

    notify(string.format("开始上传 %d 张截图到云端…", #files), 4)
    UIManager:scheduleIn(0.1, step)
end

-- ------------------------- reading progress -------------------------

-- Minimal, safe line-based format: no code execution, human readable.
-- Fields: progress, percentage, timestamp, device, device_id, filename
local function encode_progress(t)
    local function esc(v)
        v = tostring(v or "")
        return (v:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("=", "\\="))
    end
    return string.format("progress=%s\npercentage=%s\ntimestamp=%s\ndevice=%s\ndevice_id=%s\nfilename=%s\n",
        esc(t.progress), tostring(t.percentage or 0), tostring(t.timestamp or 0),
        esc(t.device), esc(t.device_id), esc(t.filename))
end

local function decode_progress(content)
    if type(content) ~= "string" then return nil end
    local out = {}
    for line in content:gmatch("[^\n]+") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k and v then
            v = v:gsub("\\=", "="):gsub("\\n", "\n"):gsub("\\\\", "\\")
            out[k] = v
        end
    end
    if not out.progress or out.progress == "" then return nil end
    out.percentage = tonumber(out.percentage) or 0
    out.timestamp = tonumber(out.timestamp) or 0
    return out
end

local function get_doc_digest(ui)
    if not ui.doc_settings then return nil end
    local d = ui.doc_settings:readSetting("partial_md5_checksum")
    if type(d) == "string" and d ~= "" then return d end
    local file = ui.document and ui.document.file
    if not file then return nil end
    local _, name = util.splitFilePathName(file)
    if not name then return nil end
    return md5(name)
end

local function get_current_progress(ui)
    if not ui or not ui.document then return nil end
    local progress, percent
    if ui.document.info.has_pages then
        progress = ui.paging:getLastProgress()
        percent = ui.paging:getLastPercent()
    else
        progress = ui.rolling:getLastProgress()
        percent = ui.rolling:getLastPercent()
    end
    return progress, Math.roundPercent(percent or 0)
end

-- Comparable "how far" value. Paginated documents use the page number,
-- reflowable ones use the percentage (0..1). Larger always means further.
local function progress_metric(ui, progress, percentage)
    if ui and ui.document and ui.document.info.has_pages then
        return tonumber(progress) or 0
    end
    return tonumber(percentage) or 0
end

local function sync_to_progress(ui, progress)
    if not ui or not ui.document or progress == nil then return end
    if ui.document.info.has_pages then
        ui:handleEvent(Event:new("GotoPage", tonumber(progress)))
    else
        ui:handleEvent(Event:new("GotoXPointer", tostring(progress)))
    end
end

local function progress_paths(server, digest)
    local remote_dir = get_remote_dir(server, PROGRESS_DIR)
    local base = WebDavApi:getJoinedPath(server.address, remote_dir)
    local url = WebDavApi:getJoinedPath(base, digest .. ".txt")
    local tmp = DataStorage:getDataDir() .. "/webdavsync_progress.tmp"
    return remote_dir, base, url, tmp
end

-- interactive=true shows a result popup; closing=true means we are tearing down
-- the document (block until online); otherwise the network retry is non-blocking.
local function push_progress(ui, interactive, closing)
    if not ui or not ui.document then return end
    local server = get_server()
    if not server then
        if interactive then notify("未找到 WebDAV 配置，无法上传阅读进度。", 7) end
        return
    end
    local digest = get_doc_digest(ui)
    if not digest then
        if interactive then notify("无法确定当前书籍，进度未上传。", 6) end
        return
    end
    local progress, percent = get_current_progress(ui)
    if progress == nil then
        if interactive then notify("无法读取当前阅读进度。", 6) end
        return
    end
    local name, id = get_device_info()
    local filename = ui.document.file or ""
    local _, short_name = util.splitFilePathName(filename)
    local payload = {
        progress = tostring(progress), percentage = percent,
        timestamp = os.time(), device = name, device_id = id,
        filename = short_name or "",
    }
    local remote_dir, base, url, tmp = progress_paths(server, digest)
    local function do_push()
        pcall(function()
            WebDavApi:createFolder(base .. "/", server.username, server.password, remote_dir)
        end)
        local ok_write = pcall(function()
            local f = assert(io.open(tmp, "w"))
            f:write(encode_progress(payload)); f:close()
        end)
        if not ok_write then
            if interactive then notify("写入临时进度文件失败。", 6) end
            return
        end
        local code
        local ok_req = pcall(function()
            code = WebDavApi:uploadFile(url, server.username, server.password, tmp)
        end)
        logger.info("webdavsync: progress push", digest, percent, code)
        if interactive then
            if ok_req and type(code) == "number" and code >= 200 and code < 300 then
                notify(string.format("阅读进度已上传（%d%%）。", math.floor(percent * 100)), 4)
            else
                notify("阅读进度上传失败，请检查 WebDAV 配置或网络。", 7)
            end
        end
    end
    if closing then
        -- The document instance is going away: block until online so the push
        -- runs before teardown (goOnlineToRun also runs immediately if online).
        NetworkMgr:goOnlineToRun(do_push)
    elseif NetworkMgr:willRerunWhenOnline(do_push) then
        return  -- offline: callback will run once online
    else
        do_push()
    end
end

local function pull_progress(ui, interactive, auto)
    if not ui or not ui.document then return end
    local server = get_server()
    if not server then
        if interactive then notify("未找到 WebDAV 配置，无法拉取阅读进度。", 7) end
        return
    end
    local digest = get_doc_digest(ui)
    if not digest then
        if interactive then notify("无法确定当前书籍，进度未拉取。", 6) end
        return
    end
    local _, _, url, tmp = progress_paths(server, digest)
    local function do_pull()
        local code
        local ok_req = pcall(function()
            code = WebDavApi:downloadFile(url, server.username, server.password, tmp)
        end)
        if not ok_req or code ~= 200 then
            logger.info("webdavsync: no remote progress", digest, code)
            if interactive then notify("云端没有这本书的进度记录。", 5) end
            return
        end
        local content
        local ok_read = pcall(function()
            local f = assert(io.open(tmp, "r")); content = f:read("*a"); f:close()
        end)
        if not ok_read then
            if interactive then notify("读取云端进度失败。", 6) end
            return
        end
        local remote = decode_progress(content)
        if not remote then
            if interactive then notify("云端进度格式无效。", 6) end
            return
        end
        local _, _, my_id = get_device_info()
        if remote.device_id == my_id and interactive then
            notify("最新进度来自本设备，无需拉取。", 5)
            return
        end
        local cur_progress, cur_percent = get_current_progress(ui)
        if tostring(cur_progress) == tostring(remote.progress) then
            if interactive then notify("进度已是最新。", 4) end
            return
        end
        -- Auto pull compares how far each side is and keeps the fastest one.
        -- Paginated docs compare page numbers; reflowable docs compare percent.
        local local_metric = progress_metric(ui, cur_progress, cur_percent)
        local remote_metric = progress_metric(ui, remote.progress, remote.percentage)
        local function apply()
            sync_to_progress(ui, remote.progress)
            notify(string.format("已同步到云端进度（%d%%）", math.floor(remote.percentage * 100)), 5)
        end
        if interactive then
            -- Manual pull always applies without confirmation.
            apply()
        elseif remote_metric > local_metric then
            -- Cloud is further along: jump to the fastest progress.
            apply()
        elseif local_metric > remote_metric then
            -- Local is further along: keep it and push, so every device
            -- converges on the fastest progress.
            logger.info("webdavsync: local ahead, push", local_metric, remote_metric)
            push_progress(ui, false, false)
        end
    end
    if NetworkMgr:willRerunWhenOnline(do_pull) then return end
    do_pull()
end

-- ------------------------- plugin -------------------------

local WebDavSync = WidgetContainer:extend{
    name = "webdavsync",
    is_doc_only = false,
}

function WebDavSync:onDispatcherRegisterActions()
    Dispatcher:registerAction(A_SCREENSHOT, {
        category = "none", event = E_SCREENSHOT, title = "上传截图到云端", general = true,
    })
    Dispatcher:registerAction(A_PUSH, {
        category = "none", event = E_PUSH, title = "上传阅读进度", reader = true,
    })
    Dispatcher:registerAction(A_PULL, {
        category = "none", event = E_PULL, title = "拉取阅读进度", reader = true,
    })
end

function WebDavSync:onWebDavSyncAction()
    local ok, err = pcall(start_upload)
    if not ok then logger.err("webdavsync:", err); notify("截图上传出错：" .. tostring(err), 8) end
    return true
end
function WebDavSync:onPushProgressAction()
    local ok, err = pcall(push_progress, self.ui, true, false)
    if not ok then logger.err("webdavsync:", err); notify("进度上传出错：" .. tostring(err), 8) end
    return true
end
function WebDavSync:onPullProgressAction()
    local ok, err = pcall(pull_progress, self.ui, true, false)
    if not ok then logger.err("webdavsync:", err); notify("进度拉取出错：" .. tostring(err), 8) end
    return true
end

-- Automatic triggers (only meaningful inside the reader).
function WebDavSync:onReaderReady()
    if is_auto_progress() then
        UIManager:scheduleIn(AUTO_PULL_DELAY, function()
            if self.ui and self.ui.document then
                pcall(pull_progress, self.ui, false, true)
            end
        end)
    end
end

function WebDavSync:onPageUpdate(page)
    if page == nil then return end
    if not is_auto_progress() then return end
    UIManager:unschedule(self._push_task)
    self._push_task = function()
        if self.ui and self.ui.document then
            pcall(push_progress, self.ui, false, false)
        end
    end
    UIManager:scheduleIn(PUSH_DELAY, self._push_task)
end

function WebDavSync:onCloseDocument()
    UIManager:unschedule(self._push_task)
    if is_auto_progress() and self.ui then
        pcall(push_progress, self.ui, false, true)
    end
end

function WebDavSync:init()
    logger.info("webdavsync: plugin loaded (v2.2)")
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
end

function WebDavSync:addToMainMenu(menu_items)
    menu_items.webdavsync = {
        text = "WebDAV同步应用插件",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = "上传截图到云端",
                callback = function() self:onWebDavSyncAction() end,
            },
            {
                text = "阅读进度同步",
                sub_item_table = {
                    {
                        text = "上传当前阅读进度",
                        callback = function() self:onPushProgressAction() end,
                    },
                    {
                        text = "拉取云端阅读进度",
                        callback = function() self:onPullProgressAction() end,
                    },
                    {
                        text = "自动同步（开书对比/翻页与关书上传）",
                        keep_menu_open = true,
                        checked_func = function() return is_auto_progress() end,
                        callback = function()
                            local v = toggle_auto_progress()
                            notify("自动同步已" .. (v and "开启" or "关闭"), 3)
                        end,
                    },
                },
            },
        },
    }
end

return WebDavSync
