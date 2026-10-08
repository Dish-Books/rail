defmodule Rail.Tools.Schemas.BrowserSession do
  @moduledoc """
  The browser one task is being driven in, as a row rather than only a process.

  Every task's browser is a browser context and a tab in the one shared Chrome
  (`Rail.Tools.Utils.EnsureBrowserHost`), which outlives Rail. The row is what
  finds the tab again after a restart - the context and target it was given - and
  what says which contexts are still somebody's, so the rest can be closed.

  Each agent names its browser, and a task has one live session per name, so a
  second `start` finds the first rather than leaving a browser behind. `account`
  is who the project's seed signed it in as, and `signed_in_at` when it was signed
  in or left bare on purpose. The finished rows stay as the record.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task

  @statuses [:starting, :running, :finished]

  @primary_key {:id, UXID, autogenerate: true, prefix: "bws"}
  schema "browser_sessions" do
    field :name, :string
    field :account, :string
    field :signed_in_at, :utc_datetime_usec
    field :debug_port, :integer
    field :browser_context_id, :string
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
    :name,
    :account,
    :signed_in_at,
    :debug_port,
    :browser_context_id,
    :target_id,
    :cdp_session_id,
    :status,
    :started_at,
    :finished_at
  ]

  @required_fields [:task_id, :name, :status]

  @doc """
  Builds a changeset for a browser session.
  """
  def changeset(browser_session, attrs) do
    browser_session
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:task_id, :name], name: :browser_sessions_live_task_name_index)
  end
end
