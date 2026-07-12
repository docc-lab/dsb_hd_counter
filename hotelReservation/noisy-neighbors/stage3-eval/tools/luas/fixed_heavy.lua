-- param-sweep arm: single constant HEAVY request (max 15-day span, corner coords)
package.cpath ="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
package.path = "/usr/share/lua/5.1/?.lua;" .. package.path
local url = "http://localhost:5000"
request = function()
  return wrk.format("GET", url .. "/hotels?inDate=2015-04-09&outDate=2015-04-24&lat=38.264&lon=-122.252", {}, nil)
end
