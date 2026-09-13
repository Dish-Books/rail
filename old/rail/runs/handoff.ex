defmodule Rail.Runs.Handoff do
  @moduledoc """
  Work passed between two roles on one task, as it was written into the log.

  `Rail.Runs.Actions.ParseHandoff` reads these back out of a run's log; nothing
  persists them, because the log line is the record.

  Attributes:
    - `role_id`: the role at the other end — who sent it, or who it went to.
    - `summary`: one line on what was handed over.
    - `timestamp`: when the handoff happened.
    - `direction`: `:received` from another role, or `:sent` to one.
    - `note`: the findings passed along with it, when there were any.
  """
  defstruct [:role_id, :summary, :timestamp, :note, direction: :received]

  @type t :: %__MODULE__{
          role_id: String.t(),
          summary: String.t(),
          timestamp: DateTime.t() | nil,
          direction: :received | :sent,
          note: String.t() | nil
        }
end
