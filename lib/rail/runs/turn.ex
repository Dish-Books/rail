defmodule Rail.Runs.Turn do
  @moduledoc """
  One block of a run's log, read back as something said in a conversation.

  `Rail.Runs.Actions.ParseTranscript` groups consecutive log lines into these:
  what the human typed, what the role said back, the tool calls in between, and
  the events the harness logged. Nothing persists them — the RunEvent log is the
  record, and this is a reading of it.

  `author` is who or what said it, and it is the whole of what the chat pane
  needs to decide how to draw a turn.
  """
  defstruct author: :role, content: ""

  @type t :: %__MODULE__{author: :human | :role | :activity | :event, content: String.t()}
end
