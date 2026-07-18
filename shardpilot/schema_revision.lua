local M = {}

-- The revision of the analytics-service envelope-schema SET this SDK build
-- declares on batch ingest. NOT a secret and NOT a credential: it is a
-- public content identity — "sha256:" plus the hex sha256 digest computed
-- over the service's embedded `schemas/apicurio/*.schema.json` files
-- (filenames sorted lexicographically; each file fed to the hash
-- length-prefixed as "{len(name)}:{name}\n{len(content)}:" followed by the
-- raw file bytes and "\n"). Two service builds embedding byte-identical
-- schema sets share the value; any schema add, edit, or removal changes it.
--
-- Provisioned from the analytics service at coordination time. It MUST be
-- re-synced (updated here, with a version bump) whenever the service's
-- schema set changes — going stale on purpose is the point of the
-- handshake: once the server side is armed, a stale declaration identifies
-- exactly the writer builds that need redeploying. Distinct from the
-- per-event `schema_version` envelope field (the tracking-plan version):
-- this value identifies the whole schema set the SDK was built against.
M.REVISION = "sha256:e1ba01d4b76b9e73444e2edd5639281929fd89496cadc1dcc79eb68208c6a0a0"

-- The request header that carries the declaration, read by the ingest
-- service on `POST /v1/events:batch` only. The consent, crash, and
-- remote-config routes are outside the handshake and never send it.
M.HEADER = "X-ShardPilot-Schema-Revision"

return M
