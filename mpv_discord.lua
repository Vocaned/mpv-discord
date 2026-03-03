local mp = require("mp")
local opts = require("mp.options")
local utils = require("mp.utils")
local ffi = require("ffi")

local options = {
    enabled = true,
    application_id = "1031137720317263873",
}
opts.read_options(options, "mpv_discord")

ffi.cdef[[
    typedef int socklen_t;
    typedef unsigned short sa_family_t;
    struct sockaddr {
        sa_family_t sa_family;
        char sa_data[14];
    };
    struct sockaddr_un {
        sa_family_t sun_family;
        char sun_path[108];
    };
    int socket(int domain, int type, int protocol);
    int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
    ssize_t send(int sockfd, const void *buf, size_t len, int flags);
    ssize_t recv(int sockfd, void *buf, size_t len, int flags);
    int close(int fd);
]]

local AF_UNIX = 1
local SOCK_STREAM = 1

local function connect_discord()
    local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 then return nil end

    local addr = ffi.new("struct sockaddr_un")
    addr.sun_family = AF_UNIX

    local xdg = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    ffi.copy(addr.sun_path, xdg .. "/discord-ipc-0")

    if ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) < 0 then
        ffi.C.close(fd)
        return nil
    end

    return fd
end

local function send_ipc(fd, op, payload)
    local json_str = utils.format_json(payload)

    local header = ffi.new("uint32_t[2]")
    header[0] = op
    header[1] = string.len(json_str)

    ffi.C.send(fd, header, 8, 0)
    ffi.C.send(fd, json_str, string.len(json_str), 0)
end

local discord_fd = nil

local function update_presence()
    if not options.enabled then
        if discord_fd then
            ffi.C.close(discord_fd)
        end
        return
    end


    if not discord_fd then
        discord_fd = connect_discord()
        if discord_fd then
            send_ipc(discord_fd, 0, {v = 1, client_id = options.application_id})
        else
            return -- Cannot connect to Discord
        end
    end

    -- TODO: https://mpv.io/manual/stable/#properties

    local activity = {
        status_display_type = 1, -- state
        flags = 1,
        assets = {}
    }

    local has_video = mp.get_property_native("current-tracks/video") ~= nil
    local has_audio = mp.get_property_native("current-tracks/audio") ~= nil
    local is_image = has_video and mp.get_property_bool("current-tracks/video/image")

    if not has_audio and (not has_video or is_image) then
        return
    end

    if has_video and not is_image then
        -- media is a video
        activity["type"] = 3 -- watching
        activity["state"] = mp.get_property("filename")
        local time_pos = mp.get_property_number("time-pos")
        local duration = mp.get_property_number("duration")
        activity["timestamps"]["start_time"] = math.floor((os.time() - (time_pos or 0)) * 1000)
        activity["timestamps"]["end_time"] = math.floor((activity["timestamps"]["start_time"] + (duration or 0)) * 1000)

    else
        -- media is a track
        activity["type"] = 2 -- listening
        local metadata = mp.get_property_native("metadata")

        local function getMetadata(key)
            -- get metadata from table case insensitively
            local lowerKey = string.lower(key)
            for k, v in pairs(metadata) do
                if string.lower(tostring(k)) == lowerKey then
                    return v
                end
            end
            return nil
        end

        activity["state"] = mp.get_property("media-title")
        if metadata then
            activity["details"] = getMetadata("artistsort") or getMetadata("artist") or "Unknown Artist"
            activity["assets"]["large_text"] = getMetadata("album") or "Unknown Album"

            -- get urls and images from musicbrainz if mbid in metadata
            local albumid = getMetadata("musicbrainz_albumid")
            local artistid = getMetadata("musicbrainz_artistid") or getMetadata("musicbrainz_albumartistid")
            local trackid = getMetadata("musicbrainz_trackid")

            activity["state_url"] = artistid and ("https://musicbrainz.org/artist/" .. artistid) or nil
            activity["details_url"] = trackid and ("https://musicbrainz.org/recording/" .. trackid) or nil

            if albumid then
                activity["assets"]["large_image"] = string.format("https://coverartarchive.org/release/%s/front", albumid)
                activity["assets"]["large_url"] = "https://musicbrainz.org/release/" .. albumid
            end
        end
    end


    local is_paused = mp.get_property_native("pause")

    if is_paused or not activity["state"] then
        send_ipc(discord_fd, 1, {
            cmd = "SET_ACTIVITY",
            args = {
                pid = utils.getpid(),
                activity = nil
            },
            nonce = tostring(os.time())
        })
        return
    end


    send_ipc(discord_fd, 1, {
        cmd = "SET_ACTIVITY",
        args = {
            pid = utils.getpid(),
            activity = activity
        },
        nonce = tostring(os.time())
    })
end

mp.register_event("seek", update_presence)
mp.observe_property("metadata", "native", update_presence)
mp.observe_property("pause", "bool", update_presence)
