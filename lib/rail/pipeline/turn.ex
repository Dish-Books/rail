defmodule Rail.Pipeline.Turn do
  @moduledoc """
  One block of a run's log, read back as something said in a conversation.

  `Rail.Pipeline.Actions.ParseTranscript` groups consecutive log lines into these:
  what the human typed, what the role said back, the tool calls in between, and
  the events the harness logged. Nothing persists them — the RunEvent log is the
  record, and this is a reading of it.

  `author` is who or what said it, and it is the whole of what the chat pane
  needs to decide how to draw a turn.

  `:turn_start` is the one author no log line produced: it is the boundary
  between one spawn of the agent and the next, carrying when that turn began and
  what it cost. The log says what was said, never when, so the time comes from
  the process row rather than from the transcript.
  """
  defstruct author: :role, content: "", at: nil, duration_seconds: nil

  @type t :: %__MODULE__{
          author: :human | :role | :activity | :event | :turn_start,
          content: String.t(),
          at: DateTime.t() | nil,
          duration_seconds: non_neg_integer() | nil
        }
end
