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

-- ---- demo (safe to delete) -------------------------------------------------
http.get("https://example.com", nil, function(res)
  if res.ok then
    lje.con_printf("$green{[lje-http]} GET %s -> %d (%d bytes)", res.url, res.status, #res.body)
    lje.con_printf("$green{[lje-http]} Body: %s", res.body)
  else
    lje.con_printf("$red{[lje-http]} GET %s failed: %s", res.url, tostring(res.error))
  end
end)
