-- ===========================================================================
-- Sockshop (Blueprint variant) mixed e2e workload.
--
-- Drives the Blueprint sockshop frontend's RPC-style HTTP endpoints
-- via wrk2. Paths are relative; wrk2 uses the target host:port passed
-- on its command line (set by lib/wrk2-driver.sh via ss_frontend_url).
--
-- Mix (lightweight, all-read or write-safe):
--   80% GET  /ListItems  ?pageSize=10&pageNum=<1..5>
--   15% POST /Register   ?sessionID=&username=u<N>&password=p<N>&email=...
--    5% GET  /ListTags
--
-- Why this mix:
--   - ListItems is the dominant browsing call -- exercises frontend,
--     catalogue, and catalogue-db (MySQL) on every request.
--   - Register exercises frontend + user + user-db (Mongo). It will
--     succeed with unique usernames; duplicate usernames may error but
--     still drive the same code path under load.
--   - ListTags is cheap but adds a third catalogue-path endpoint.
--
-- NOT included (extend later if your experiments need them):
--   - GetSock?itemID=<UUID> would 404 because sockshop's UUIDs are
--     generated at LoadCatalogue time; we'd need to parse a real one
--     from a ListItems response first.
--   - Cart / order endpoints need a session ID lifecycle (Login first,
--     then AddItem / GetCart / NewOrder with the returned session).
--     Add these only if cart/order/payment services need direct load.
--
-- All requests are sent as POST/GET with query-string params, matching
-- Blueprint's HTTP plugin convention (per
-- examples/sockshop/wiring/specs/docker.go's frontend setup -- the
-- HTTP server unmarshals named params from the query string into
-- the matching RPC method signature in workflow/frontend/frontend.go).
--
-- Counter-omission: every request uses wrk.format with NO body and an
-- empty headers table, which keeps wrk2's coordinated-omission-aware
-- scheduling working correctly.
-- ===========================================================================

-- Lua 5.1 cpath/path setup (matches the HR script's pattern; needed
-- when wrk2 was built against the system Lua on this host).
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
package.path  = "/usr/share/lua/5.1/?.lua;" .. package.path

local socket = require("socket")
math.randomseed(socket.gettime() * 1000)
math.random(); math.random(); math.random()

local empty_headers = {}

-- Browse the catalogue. pageNum cycles 1..5 to spread DB cache hits.
local function list_items()
    local page_num  = math.random(1, 5)
    local page_size = 10
    local path = "/ListItems?pageSize=" .. tostring(page_size) ..
                              "&pageNum="  .. tostring(page_num)
    return wrk.format("GET", path, empty_headers, nil)
end

-- Cheap tag-list lookup (exercises catalogue + catalogue-db).
local function list_tags()
    return wrk.format("GET", "/ListTags", empty_headers, nil)
end

-- Register a fresh user. sessionID is empty (server-generated), the
-- other fields are randomized so duplicates are rare across a run.
local function register()
    -- Per-thread unique-ish numeric tag. socket.gettime() is wall-clock
    -- seconds; math.random adds entropy across concurrent wrk threads
    -- that may sample the same gettime tick.
    local tag = math.floor(socket.gettime() * 1000) + math.random(1, 1000000)
    local user  = "u"  .. tostring(tag)
    local pass  = "p"  .. tostring(tag)
    local email = user .. "@example.com"
    local path = "/Register?sessionID=" ..
                 "&username=" .. user ..
                 "&password=" .. pass ..
                 "&email="    .. email ..
                 "&first="    .. user ..
                 "&last="     .. "sock"
    return wrk.format("POST", path, empty_headers, nil)
end

-- ===========================================================================
-- Request dispatcher
-- ===========================================================================
request = function()
    local list_items_ratio = 0.80
    local register_ratio   = 0.15
    -- list_tags fills the remaining 5%

    local coin = math.random()
    if coin < list_items_ratio then
        return list_items()
    elseif coin < list_items_ratio + register_ratio then
        return register()
    else
        return list_tags()
    end
end
