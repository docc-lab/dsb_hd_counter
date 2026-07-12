-- param-sweep arm: random DATES only (coords fixed at center)
package.cpath ="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
package.path = "/usr/share/lua/5.1/?.lua;" .. package.path
local socket = require("socket")
math.randomseed(socket.gettime()*1000)
local url = "http://localhost:5000"
request = function()
  local in_date = math.random(9, 14)
  local out_date = math.random(in_date + 1, 15)
  local i = (in_date <= 9) and ("2015-04-0" .. in_date) or ("2015-04-" .. in_date)
  local o = (out_date <= 9) and ("2015-04-0" .. out_date) or ("2015-04-" .. out_date)
  return wrk.format("GET", url .. "/hotels?inDate=" .. i .. "&outDate=" .. o ..
    "&lat=38.0235&lon=-122.095", {}, nil)
end
