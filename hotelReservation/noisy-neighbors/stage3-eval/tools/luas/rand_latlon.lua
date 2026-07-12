-- param-sweep arm: random COORDS only (dates fixed 2-day span)
package.cpath ="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
package.path = "/usr/share/lua/5.1/?.lua;" .. package.path
local socket = require("socket")
math.randomseed(socket.gettime()*1000)
local url = "http://localhost:5000"
request = function()
  local lat = 38.0235 + (math.random(0, 481) - 240.5)/1000.0
  local lon = -122.095 + (math.random(0, 325) - 157.0)/1000.0
  return wrk.format("GET", url .. "/hotels?inDate=2015-04-10&outDate=2015-04-12&lat=" ..
    tostring(lat) .. "&lon=" .. tostring(lon), {}, nil)
end
