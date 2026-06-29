-- Low-level loader/binding for the bundled libcurl DLL.
-- Binds the subset of the easy + multi interfaces the async layer needs,
-- and performs the one-time curl_global_init.

local DLL_NAME = "bin/libcurl-x64.dll"

---@return string? path
local function resolve_dll_path()
  local script_path = lje.env.current_script_path()
  if not script_path then
    return nil
  end

  local dir = string.match(script_path, "^(.*[\\/])")
  if not dir then
    return nil
  end

  return dir .. DLL_NAME
end

local path = resolve_dll_path()
if not path then
  lje.con_printf("$red{[lje-http]} could not resolve a path for %s", DLL_NAME)
  return nil
end

local handle = ffi.module.load(path)
if not handle then
  lje.con_printf("$red{[lje-http]} ffi.module.load failed for %s", path)
  return nil
end

--- Bind an exported curl function. Signatures are compact: first char is the
--- return type, the rest are argument types (v void, i int32, l int64,
--- p pointer, s const char*).
---
--- NOTE: curl_easy_setopt / curl_easy_getinfo are C-variadic, but on the Win64
--- ABI integer/pointer arguments occupy the same registers whether variadic or
--- not, and curl never passes a float through them. So we bind them as plain
--- fixed-signature functions, one per value type.
local function bind(name, sig)
  local fn = ffi.module.bind_export(handle, name, sig)
  if not fn then
    lje.con_printf("$red{[lje-http]} missing curl export: %s", name)
  end
  return fn
end

local C = {
  -- easy interface
  easy_init = bind("curl_easy_init", "p"),
  easy_cleanup = bind("curl_easy_cleanup", "vp"),
  easy_setopt_str = bind("curl_easy_setopt", "ipis"), -- (CURL*, option, char*)
  easy_setopt_long = bind("curl_easy_setopt", "ipii"), -- (CURL*, option, long)  long is 32-bit on Win64
  easy_setopt_ptr = bind("curl_easy_setopt", "ipip"), -- (CURL*, option, void*)
  easy_getinfo_long = bind("curl_easy_getinfo", "ipip"), -- (CURL*, info, long* out)
  easy_strerror = bind("curl_easy_strerror", "si"),

  -- multi interface
  multi_init = bind("curl_multi_init", "p"),
  multi_cleanup = bind("curl_multi_cleanup", "ip"),
  multi_add = bind("curl_multi_add_handle", "ipp"),
  multi_remove = bind("curl_multi_remove_handle", "ipp"),
  multi_perform = bind("curl_multi_perform", "ipp"), -- (CURLM*, int* running)
  multi_info_read = bind("curl_multi_info_read", "ppp"), -- (CURLM*, int* msgs) -> CURLMsg*

  -- header lists
  slist_append = bind("curl_slist_append", "pps"),
  slist_free_all = bind("curl_slist_free_all", "vp"),

  -- global
  global_cleanup = bind("curl_global_cleanup", "v"),
}

-- One-time global init (CURL_GLOBAL_ALL = CURL_GLOBAL_SSL | CURL_GLOBAL_WIN32 = 3).
local global_init = bind("curl_global_init", "ii")
if global_init then
  local rc = global_init(3)
  if rc ~= 0 then
    lje.con_printf("$red{[lje-http]} curl_global_init failed (CURLcode %s)", tostring(rc))
  end
end

-- Smoke test / banner.
local curl_version = bind("curl_version", "s")
local version = curl_version and curl_version() or "<unknown>"
lje.con_printf("$green{[lje-http]} libcurl loaded: %s", tostring(version))

return {
  handle = handle,
  path = path,
  version = version,
  C = C,

  -- CURLOPT_* constants we use (value = type base + index).
  OPT = {
    URL = 10002, -- OBJECTPOINT + 2
    WRITEDATA = 10001, -- OBJECTPOINT + 1
    WRITEFUNCTION = 20011, -- FUNCTIONPOINT + 11
    FOLLOWLOCATION = 52, -- LONG + 52
    TIMEOUT_MS = 155, -- LONG + 155
    HTTPHEADER = 10023, -- OBJECTPOINT + 23
    CUSTOMREQUEST = 10036, -- OBJECTPOINT + 36
    POSTFIELDSIZE = 60, -- LONG + 60
    COPYPOSTFIELDS = 10165, -- OBJECTPOINT + 165
    NOSIGNAL = 99, -- LONG + 99
    ACCEPT_ENCODING = 10102, -- OBJECTPOINT + 102
  },

  -- CURLINFO_* constants.
  INFO = {
    RESPONSE_CODE = 2097154, -- CURLINFO_LONG + 2
  },

  MSG_DONE = 1, -- CURLMSG_DONE
}
