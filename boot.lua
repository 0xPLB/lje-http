---@module "lje-http.http"
local http = lje.include("http.lua")
http.lhttp = true

if not http then
  lje.con_print("[lje-http] failed to initialise at boot")
  return
end

lje.vm.add_pre_engine_call_hook(function()
  http.pump()
end, lje.state.menu)

lje.__lje_http = http

_G.http = http

