# lje-http

This is an LJE module restoring the HTTP functionality that was removed from LJE's GMod API as it was unsafe and incompatible with LJE 2's design. It is essentially the same exact thing as the GMod HTTP function, utilizing cURL to perform the requests, but with a few differences:

- No restrictions on what URLs can be requested
- No header filtering, you can send any headers you want
- Supports arbitrary HTTP methods and request bodies

This module is asynchronous just like the original GMod HTTP function, and is designed to be used in a similar way.

## API

Once the script is loaded it exposes a global `http` table.

The module is loaded from `boot.lua` and lives for the whole process. It is pumped by a
menu-state engine call hook, so requests also work in the main menu and survive map
changes and reconnects. The global `http` is set at boot, so other scripts can use it from
their own `boot.lua` as well as `main.lua`. If loading at boot fails, `main.lua`
falls back to a per-session instance that is cleaned up on disconnect.

### `http.request(opts) -> id?, err?`

Starts a request. Returns an integer `id` you can correlate with the result, or
`nil` plus an error string on failure to start.

`opts` fields:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `url` | `string` | *(required)* | Target URL. |
| `method` | `string` | `"GET"` (or `"POST"` if `body` is set) | HTTP method. Any method is allowed. |
| `headers` | `table<string,string>` | `nil` | Request headers, as a `name = value` map. |
| `body` | `string` | `nil` | Request body. Sent binary-safe; defaults the method to `POST`. |
| `timeout` | `integer` | `nil` | Overall timeout in milliseconds. |
| `on_complete` | `fun(res)` | `nil` | Called when the transfer succeeds (and on failure if no `on_error` is given). |
| `on_error` | `fun(res)` | `nil` | Called on a transport-level failure (DNS, connection, timeout, TLS, …). |

### `http.get(url, headers?, on_complete?, on_error?) -> id?, err?`

Convenience wrapper for a `GET` request. `headers` is the same `name = value`
map accepted by `request`.

### `http.post(url, body, headers?, on_complete?, on_error?) -> id?, err?`

Convenience wrapper for a `POST` request with a body. `headers` is the same
`name = value` map accepted by `request`.

### `http.poll() -> events`

Drains and returns an array of all results that have completed since the last
call (and clears the queue). Every request appears here regardless of its
callbacks.

### `http.pending() -> integer`

Number of requests currently in flight.

### The result table (`res`)

Passed to `on_complete` / `on_error` and returned in `poll()` events:

| Field | Type | Description |
|-------|------|-------------|
| `id` | `integer` | The id returned by `request`. |
| `url` | `string` | The requested URL. |
| `ok` | `boolean` | `true` if the transfer succeeded at the transport level. |
| `status` | `integer` | HTTP response status code (e.g. `200`, `404`). |
| `body` | `string` | The full response body. |
| `error` | `string?` | curl error description when `ok` is `false`, otherwise `nil`. |

> **Note:** `ok` reflects the *transport*, not the HTTP status. A `404` or `500`
> is still `ok == true` — check `res.status` for HTTP-level errors.

### Example

```lua
http.request({
  url = "https://api.example.com/thing",
  method = "POST",
  headers = { ["Content-Type"] = "application/json" },
  body = '{"hello":"world"}',
  timeout = 10000,
  on_complete = function(res)
    print(("%d: %d bytes"):format(res.status, #res.body))
  end,
  on_error = function(res)
    print("request failed: " .. tostring(res.error))
  end,
})
```
