defmodule Rail.Pipeline.Schemas.Task do
  @moduledoc """
  Schema for a task moving through the development pipeline.
  """
  use Rail.Schema

  alias Rail.Domain.Enums.Mergeability
  alias Rail.Domain.Enums.TaskStage
  alias Rail.Domain.Enums.TaskStageState
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Projects.Schemas.Project
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "tsk"}
  schema "tasks" do
    belongs_to :project, Project
    belongs_to :issue, Issue
    belongs_to :owner_user, User, foreign_key: :owner_user_id

    field :title, :string
    field :description, :string
    field :stage, TaskStage, default: :product
    field :stage_state, TaskStageState, default: :queued
    field :worktree_name, :string
    field :worktree_path, :string
    field :pr_number, :integer
    field :pr_url, :string
    field :mergeability, Mergeability
    field :pr_is_draft, :boolean
    field :is_rebasing, :boolean, default: false
    field :stage_state_before_rebase, TaskStageState
    field :active_chat_role_id, :string
    field :question_id, :string
    field :error, :string
    field :retry_after, :utc_datetime_usec
    field :rework_cycles, :integer, default: 0
    field :rework_budget_base, :integer, default: 0
    field :rework_cycles_by_gate, :map, default: %{}
    field :outstanding_reports, {:array, :string}, default: []
    field :viewed_diff_files, {:array, :string}, default: []
    field :merged_at, :utc_datetime_usec

    has_many :questions, Question
    has_many :plans, Plan
    has_many :role_runs, RoleRun

    timestamps()
  end

  @cast_fields [
    :issue_id,
    :owner_user_id,
    :title,
    :description,
    :stage,
    :stage_state,
    :worktree_name,
    :worktree_path,
    :pr_number,
    :pr_url,
    :mergeability,
    :pr_is_draft,
    :is_rebasing,
    :stage_state_before_rebase,
    :active_chat_role_id,
    :question_id,
    :error,
    :retry_after,
    :rework_cycles,
    :rework_budget_base,
    :rework_cycles_by_gate,
    :outstanding_reports,
    :viewed_diff_files,
    :merged_at
  ]

  @required_fields [
    :project_id,
    :title,
    :stage,
    :stage_state
  ]

  @doc """
  Builds a changeset for a task.
  The project_id cannot be set from attrs and must be supplied directly.
  """
  def changeset(task, attrs, project_id \\ nil) do
    task
    |> cast(attrs, @cast_fields)
    |> maybe_put_project_id(project_id)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:owner_user_id)
  end

  @doc """
  Builds a valid fixture struct for testing.
  """
  def factory do
    id = System.unique_integer([:positive])

    %__MODULE__{
      project_id: UXID.generate!(prefix: "prj"),
      title: "Task #{id}",
      description: "Description for task #{id}",
      stage: :product,
      stage_state: :queued,
      worktree_name: "task-#{id}",
      is_rebasing: false,
      rework_cycles: 0,
      rework_budget_base: 0,
      rework_cycles_by_gate: %{},
      outstanding_reports: [],
      viewed_diff_files: []
    }
  end

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end
