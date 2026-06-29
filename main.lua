---@module "lje-http.http"
local http = lje.require("http.lua")
if not http then
  lje.con_printf("$red{[lje-http]} failed to initialise; HTTP unavailable")
  return
end

-- Drive curl forward every frame.
hook.Add("Think", "lje-http.pump", function()
  http.pump()
end)
hook.Listen()

_G.http = http
