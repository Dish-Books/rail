defmodule Rail.Tools.Schemas.BrowserSession do
  @moduledoc """
  The browser one task is being driven in, as a row rather than only a process.

  A QA pass needs a Chrome that outlives every call made against it, and anything
  that outlives a call is something Rail can lose track of. The row is what makes
  it findable again: the OS pid to kill and the profile directory to remove. A
  session whose process is gone is still a Chrome holding a core until somebody
  reaps it.

  One live session per task, so a second `start` finds the first rather than
  leaving a browser behind. A task is QA'd more than once and each pass gets its
  own; the finished rows stay as the record of what was launched.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task

  @statuses [:starting, :running, :finished]

  @primary_key {:id, UXID, autogenerate: true, prefix: "bws"}
  schema "browser_sessions" do
    field :os_pid, :integer
    field :debug_port, :integer
    field :profile_path, :string
    field :target_id, :string
    field :cdp_session_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :starting
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :task, Task

    timestamps()
  end

  @cast_fields [
    :task_id,
    :os_pid,
    :debug_port,
    :profile_path,
    :target_id,
    :cdp_session_id,
    :status,
    :started_at,
    :finished_at
  ]

  @required_fields [:task_id, :status]

  @doc """
  Builds a changeset for a browser session.
  """
  def changeset(browser_session, attrs) do
    browser_session
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:task_id], name: :browser_sessions_live_task_index)
  end
end
