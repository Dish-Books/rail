## Implementation plan

### Approach

Sending a task back is a stage move, so it goes through `Rail.Pipeline.Actions.EnterStage`, the only thing that writes `task.stage`.

### Data changes

- New column `tasks.sent_back_note`: text, null until a task is sent back.

### Decisions

- Decision: the note is kept on the task, so the Architect reads it in its brief.
- Ruled out: a table of send-backs with their history.
- Assumption: the note is required.

### Changes

#### `lib/rail/pipeline/actions/send_back_to_architect.ex`

New action. Refuses unless the task is at `:review` and idle.

```elixir
def send_back_to_architect(%Run{} = run, note)
```

```elixir sketch
def send_back_to_architect(%Run{task: task} = run, note) do
  enter_stage(task, :architect, %{sent_back_note: note})
end
```

#### `lib/rail_web/live/review_stage.ex`

Adds the Send back button beside Send to QA.

#### `lib/rail/pipeline.ex`

Delegates `send_back_to_architect/2` beside `send_to_qa/1`.

```elixir
defdelegate send_back_to_architect(run, note), to: Actions.SendBackToArchitect
```

#### `priv/repo/migrations/20261022000000_add_sent_back_note.exs`

Adds the column.

#### `lib/rail/pipeline/actions/old_send_back.ex` deleted

The new action replaces it.

### Acceptance criteria

- 1: `lib/rail/pipeline/actions/send_back_to_architect.ex`, `lib/rail/pipeline/actions/send_back_to_architect_test.exs`
- 3: `lib/rail_web/live/review_stage.ex`

### Verification

- A task sent back from Review is at Architect with the note in its brief.
