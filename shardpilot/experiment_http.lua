-- Native Defold returns redirects to its callback. HTML5's XMLHttpRequest
-- follows them before Lua can inspect the status, so this credentialed plane
-- uses browser fetch with redirect="error" and polls its own bounded results.
local M = {}
local Transport = {}
Transport.__index = Transport
local serial = 0

local launch = [=[
(function(input) {
  var store = globalThis.__shardpilotExperimentHTTP;
  if (!store) store = globalThis.__shardpilotExperimentHTTP = Object.create(null);
  var job = { controller: new AbortController(), result: null };
  store[input.id] = job;
  var timer = setTimeout(function() { job.controller.abort(); }, input.timeout);
  fetch(input.url, { method: input.method, headers: input.headers,
    body: input.body || undefined, redirect: "error", credentials: "omit",
    cache: "no-store", signal: job.controller.signal
  }).then(async function(response) {
    var text = "", bytes = 0, reader = response.body && response.body.getReader();
    var decoder = new TextDecoder("utf-8", { fatal: true });
    if (reader) {
      while (true) {
        var chunk = await reader.read();
        if (chunk.done) break;
        bytes += chunk.value.byteLength;
        if (input.limit && bytes > input.limit) { job.controller.abort(); throw new Error("response_size"); }
        text += decoder.decode(chunk.value, { stream: true });
      }
      text += decoder.decode();
    }
    job.result = { status: response.status, response: text,
      headers: { "retry-after": response.headers.get("Retry-After") } };
  }).catch(function() {
    job.result = { status: 0, response: "" };
  }).finally(function() { clearTimeout(timer); });
  return "started";
})(]=]

function M.new()
	local info = sys and sys.get_sys_info and sys.get_sys_info({ ignore_secure = true }) or {}
	return setmetatable({ browser = info.system_name == "HTML5", jobs = {} }, Transport)
end

function Transport:available()
	if self.browser then return html5 and type(html5.run) == "function" end
	return http and type(http.request) == "function"
end

function Transport:request(url, method, callback, headers, body, options)
	if not self.browser then return http.request(url, method, callback, headers, body, options) end
	serial = serial + 1
	local key = tostring(serial)
	local input = json.encode({ id = key, url = url, method = method,
		headers = headers, body = body, limit = method == "POST" and 65536 or nil,
		timeout = math.max(1, options.timeout * 1000) })
	local ok, answer = pcall(html5.run, launch .. input .. ")")
	if not ok or answer ~= "started" then callback(nil, nil, { status = 0 }); return end
	self.jobs[key] = callback
end

function Transport:tick()
	local ready = {}
	for key, callback in pairs(self.jobs) do
		local ok, answer = pcall(html5.run, '(function(){var s=globalThis.__shardpilotExperimentHTTP;'
			.. 'var j=s&&s[' .. json.encode(key) .. '];if(!j||!j.result)return "";'
			.. 'delete s[' .. json.encode(key) .. '];return JSON.stringify(j.result);})()')
		if not ok then answer = '{"status":0}' end
		if type(answer) == "string" and answer ~= "" then
			local parsed, response = pcall(json.decode, answer)
			ready[#ready + 1] = { callback = callback, response = parsed and response or { status = 0 } }
			self.jobs[key] = nil
		end
	end
	for _, item in ipairs(ready) do item.callback(nil, nil, item.response) end
end

function Transport:teardown()
	for key in pairs(self.jobs) do
		pcall(html5.run, '(function(){var s=globalThis.__shardpilotExperimentHTTP;'
			.. 'var j=s&&s[' .. json.encode(key) .. '];if(j){j.controller.abort();delete s['
			.. json.encode(key) .. '];}return "";})()')
	end
	self.jobs = {}
end

return M
