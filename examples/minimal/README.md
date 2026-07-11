# Minimal Defold Example

This example shows the intended source usage shape. It uses placeholder IDs and
tokens only.

```lua
local shardpilot = require "shardpilot.sdk"

shardpilot.init({
  ingest_url = "http://localhost:8080",
  workspace_id = "workspace-example",
  app_id = "app-example",
  environment_id = "develop",
  token_provider = function(callback)
    callback("client-token-placeholder", nil, nil)
  end,
})

shardpilot.identify("user-example")
shardpilot.set_consent(true) -- consent-first: nothing transmits until a grant
shardpilot.session_start()
shardpilot.track("play_cta_click", { cta_source = "main_menu" })
shardpilot.flush()
```
