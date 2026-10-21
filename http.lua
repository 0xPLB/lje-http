-- Asynchronous HTTP on top of libcurl's multi interface.

local log = lje.con_printf or function(fmt, ...)
  lje.con_print((string.format(fmt, ...):gsub("%$%a+(%b{})", function(s) return s:sub(2, -2) end)))
end
---@module "lje-http.curl"
local curl = (lje.require or lje.include)("curl.lua")
if not curl then
  return nil
end

local C, OPT, INFO = curl.C, curl.OPT, curl.INFO

local multi = C.multi_init()
if not multi or multi == 0 then
  log("$red{[lje-http]} curl_multi_init failed")
  return nil
end

-- Scratch buffer for the out-pointers of multi_perform / info_read / getinfo.
-- Single-threaded sequential use, so one buffer is enough.
local scratch = ffi.mem.alloc(16)

local active = {} ---@type table<integer, table>  -- [id]  = request record
local by_handle = {} ---@type table<number, integer> -- [easy] = id
local queue = {} ---@type table[]                 -- completed events awaiting poll()
local next_id = 1
local shut_down = false

-- Single shared write callback. curl passes our per-request id back as the
-- WRITEDATA pointer, which we use to find the right buffer.
--   size_t write(char *ptr, size_t size, size_t nmemb, void *userdata)
local write_handle, write_addr = ffi.callback.create("lpllp", function(ptr, size, nmemb, userid)
  local total = size * nmemb
  local req = active[userid]
  if req then
    req.chunks[#req.chunks + 1] = ffi.mem.to_binary_string(ptr, total)
  end
  return total -- signal all bytes consumed
end)

--- Start an async request. Returns an id you can correlate with the event from
--- poll() / on_complete, or nil + error on failure.
---@param opts { url: string, method?: string, headers?: table<string,string>, body?: string, timeout?: integer, on_complete?: fun(res: table), on_error?: fun(res: table) }
---@return integer? id, string? err
local function request(opts)
  if shut_down then
    return nil, "lje-http has been shut down"
  end
  local easy = C.easy_init()
  if not easy or easy == 0 then
    return nil, "curl_easy_init failed"
  end

  local id = next_id
  next_id = next_id + 1

  local req = {
    id = id,
    url = opts.url,
    easy = easy,
    chunks = {},
    headers_slist = 0,
    on_complete = opts.on_complete,
    on_error = opts.on_error,
  }

  C.easy_setopt_str(easy, OPT.URL, opts.url)
  C.easy_setopt_ptr(easy, OPT.WRITEFUNCTION, write_addr)
  C.easy_setopt_ptr(easy, OPT.WRITEDATA, id) -- id stored as the userdata pointer
  C.easy_setopt_long(easy, OPT.FOLLOWLOCATION, 1)
  C.easy_setopt_long(easy, OPT.NOSIGNAL, 1)
  C.easy_setopt_str(easy, OPT.ACCEPT_ENCODING, "") -- "" => all encodings curl was built with

  if opts.timeout then
    C.easy_setopt_long(easy, OPT.TIMEOUT_MS, opts.timeout)
  end

  local method = opts.method and string.upper(opts.method) or (opts.body and "POST" or "GET")
  if method ~= "GET" then
    C.easy_setopt_str(easy, OPT.CUSTOMREQUEST, method)
  end

  if opts.body then
    -- COPYPOSTFIELDS copies the buffer (binary-safe with an explicit size set first),
    -- so the Lua string doesn't need to outlive this call.
    C.easy_setopt_long(easy, OPT.POSTFIELDSIZE, #opts.body)
    C.easy_setopt_str(easy, OPT.COPYPOSTFIELDS, opts.body)
  end

  if opts.headers then
    local slist = 0
    for k, v in pairs(opts.headers) do
      slist = C.slist_append(slist, string.format("%s: %s", k, v))
    end
    req.headers_slist = slist
    C.easy_setopt_ptr(easy, OPT.HTTPHEADER, slist)
  end

  active[id] = req
  by_handle[easy] = id
  C.multi_add(multi, easy)

  return id
end

--- Finalizes a request by putting together all chunks, checking response code and finally calling the user callbacks.
local function finalize(easy, result_code)
  local id = by_handle[easy]
  if not id then
    return
  end
  local req = active[id]

  C.easy_getinfo_long(easy, INFO.RESPONSE_CODE, scratch)
  local status = ffi.mem.read_u32(scratch)

  local ok = (result_code == 0)
  local err = nil
  if not ok then
    err = C.easy_strerror(result_code) or ("CURLcode " .. tostring(result_code))
  end

  local res = {
    id = id,
    url = req.url,
    ok = ok,
    status = status,
    body = table.concat(req.chunks),
    error = err,
  }

  -- Teardown before we hand control to user code.
  C.multi_remove(multi, easy)
  C.easy_cleanup(easy)
  if req.headers_slist ~= 0 then
    C.slist_free_all(req.headers_slist)
  end
  active[id] = nil
  by_handle[easy] = nil

  local handler = (not ok and req.on_error) or req.on_complete
  if handler then
    local pcok, perr = pcall(handler, res)
    if not pcok then
      log("$red{[lje-http]} callback error: %s", tostring(perr))
    end
  end
  queue[#queue + 1] = res
end

--- Drive all in-flight transfers forward.
local function pump()
  if shut_down or next(active) == nil then
    return
  end

  C.multi_perform(multi, scratch) -- scratch <- running handle count (unused)

  while true do
    local msgptr = C.multi_info_read(multi, scratch) -- scratch <- msgs-in-queue (unused)
    if not msgptr or msgptr == 0 then
      break
    end
    -- struct CURLMsg { int msg; CURL *easy_handle; union { ...; CURLcode result; } data; }
    --   msg @ 0, easy_handle @ 8, data/result @ 16  (x86-64 layout)
    local msg = ffi.mem.read_i32(msgptr)
    if msg == curl.MSG_DONE then
      local easy = ffi.mem.read_ptr(msgptr + 8)
      local result_code = ffi.mem.read_i32(msgptr + 16)
      finalize(easy, result_code)
    end
  end
end

--- Drain and return all completed events since the last poll.
---@return table[] events
local function poll()
  if #queue == 0 then
    return {}
  end
  local out = queue
  queue = {}
  return out
end

--- Number of requests currently in flight.
local function pending()
  local n = 0
  for _ in pairs(active) do
    n = n + 1
  end
  return n
end

local function shutdown()
  if shut_down then
    return
  end
  shut_down = true
  for _, req in pairs(active) do
    C.multi_remove(multi, req.easy)
    C.easy_cleanup(req.easy)
    if req.headers_slist ~= 0 then
      C.slist_free_all(req.headers_slist)
    end
  end
  active, by_handle, queue = {}, {}, {}
  C.multi_cleanup(multi)
  ffi.callback.remove(write_handle)
  ffi.mem.free(scratch)
end

return {
  request = request,
  pump = pump,
  poll = poll,
  pending = pending,
  shutdown = shutdown,

  -- convenience wrappers
  get = function(url, headers, on_complete, on_error)
    return request({ url = url, headers = headers, on_complete = on_complete, on_error = on_error })
  end,
  post = function(url, body, headers, on_complete, on_error)
    return request({
      url = url,
      method = "POST",
      body = body,
      headers = headers,
      on_complete = on_complete,
      on_error = on_error,
    })
  end,

  _write_handle = write_handle, -- keep the closure alive for the module's lifetime
}
