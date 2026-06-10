# Events

All events use app-first ShardPilot ingest fields:

- `event_id`
- `schema_version`
- `event_name`
- `source`
- `event_ts`
- `workspace_id`
- `app_id`
- `environment_id`
- `session_id`
- `session_sequence`
- `platform`
- `app_version`
- `app_build`
- `props`
- `context`

Do not use legacy public SDK fields: `project_id`, `game_id`, `env`,
`event_ts_server`, `event_seq_session`, or top-level `build_version`.

Built-in helpers enqueue (wire `event_name`, with the helper in parentheses
where it differs):

- `app.session_started` (from the `session_start()` helper)
- `session_end`
- `app.screen_view` (from the `screen_view()` helper)
- `tutorial_start`
- `tutorial_step_complete`
- `tutorial_complete`
- `perf_summary`
- `network_summary`

`perf_summary` aggregates frame samples from `update(dt)` and uses
`avg_fps`, `p50_frame_time_ms`, `p95_frame_time_ms`, `max_frame_time_ms`,
`frames_sampled`, and `duration_ms`.

`network_summary` aggregates `observe_ping_ms(ms)` and
`observe_disconnect(reason)` using `avg_ping_ms`, `p50_ping_ms`,
`p95_ping_ms`, `max_ping_ms`, `ping_sample_count`, `disconnect_count`, and
`transport`.

Project Tower-specific event names should be sent through generic `track()`
from the game integration later; they are not hardcoded SDK core behavior.
