-- Only these assignment units have treatment/application semantics here.
-- Other strings are valid response enum values, exposed as not assigned.
local M = {}
function M.known_unit(value)
	return value == "client_id" or value == "synthetic_subject_key"
end
return M
