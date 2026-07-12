-- param-sweep arm: single constant CHEAP request (2-day span, center coords)
package.cpath ="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
package.path = "/usr/share/lua/5.1/?.lua;" .. package.path
local url = "http://localhost:5000"
request = function()
  return wrk.format("GET", url .. "/hotels?inDate=2015-04-10&outDate=2015-04-12&lat=38.0235&lon=-122.095", {}, nil)
end
