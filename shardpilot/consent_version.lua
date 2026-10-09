-- The policy and receipt paths share one pure, bounded identifier rule.
-- "/" is permitted because the resolver names its fallback "strict-fallback/1".
local function version_ok(value)
	return type(value) == "string" and #value > 0 and #value <= 64
		and value:match("^[A-Za-z0-9._+/-]+$") ~= nil
end

return version_ok
