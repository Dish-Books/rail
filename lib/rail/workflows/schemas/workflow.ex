defmodule Rail.Workflows.Schemas.Workflow do
  @moduledoc """
  One workflow file on a project's default branch, kept by project and path so its pause outlives changes
  to the file. The row stays once the file is gone, since the issues it opened point at it.
  """
  use Rail.Schema

  alias Oban.Cron.Expression
  alias Rail.Projects.Schemas.Project
  alias Rail.Workflows.Schemas.WorkflowDefinition

  @primary_key {:id, UXID, autogenerate: true, prefix: "wfl"}
  schema "workflows" do
    field :path, :string
    # Nil while the file does not parse.
    embeds_one :definition, WorkflowDefinition, on_replace: :update
    field :paused, :boolean, default: false
    # Taken while paused or on an inactive project too, so resuming never starts the ones missed.
    field :next_run_at, :utc_datetime
    field :removed_at, :utc_datetime_usec

    belongs_to :project, Project

    timestamps()
  end

  @doc """
  Pauses or resumes the workflow; everything else on the row is read from its file. Forced, so a struct read
  before another tab changed it still writes the state asked for.
  """
  def pause_changeset(workflow, paused) when is_boolean(paused) do
    workflow
    |> change()
    |> force_change(:paused, paused)
  end

  @doc """
  The workflow's name, or its file's while the file does not parse.
  """
  def name(%__MODULE__{definition: %WorkflowDefinition{name: name}}), do: name
  def name(%__MODULE__{definition: nil, path: path}), do: Path.basename(path)

  @doc """
  The first time the workflow's schedule matches after `at`, or nil when its file does not parse.
  """
  def calculate_next_run_at(%__MODULE__{definition: nil}, %DateTime{}), do: nil

  def calculate_next_run_at(%__MODULE__{definition: %WorkflowDefinition{schedule: schedule}}, %DateTime{} = at) do
    schedule
    |> Expression.parse!()
    |> Expression.next_at(at)
    |> DateTime.truncate(:second)
  end
end
