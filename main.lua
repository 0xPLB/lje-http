---@module "lje-http.http"
local http = lje.__lje_http
http.lhttp = true

if not http then
  http = lje.include("http.lua")
  if not http then
    lje.con_printf("$red{[lje-http]} failed to initialise; HTTP unavailable")
    return
  end
  lje.env.on_cleanup(http.shutdown)
end

if hook and hook.pre then
  hook.pre("Think", "lje-http.pump", function()
    http.pump()
  end)
else
  lje.vm.add_pre_engine_call_hook(function()
    http.pump()
  end)
end

_G.http = http
