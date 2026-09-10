defmodule Rail.Pipeline.Schemas.Task do
  @moduledoc """
  Schema for a task moving through the development pipeline.
  """
  use Rail.Schema

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.Enums.Mergeability
  alias Rail.Domain.Enums.TaskStage
  alias Rail.Domain.Enums.TaskStageState
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Users.Schemas.User

  @derive {LiveSync.Watch, subscription_key: :project_id, table: "tasks"}
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
    field :viewed_diff_files, Rail.Pipeline.Types.ViewedDiffFiles, default: %{}
    field :merged_at, :utc_datetime_usec

    has_many :questions, Question
    has_many :plans, Plan
    has_many :role_runs, RoleRun
    has_many :designs, Design
    has_many :demos, Demo

    field :demo, :any, virtual: true
    field :design, :any, virtual: true

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
      viewed_diff_files: %{}
    }
  end

  @doc """
  Returns true if the task is currently busy with an in-flight run:
  - stage_state is :running, or
  - active_chat_role_id is non-nil, or
  - an OS process is actively running for this task.
  """
  def busy?(%__MODULE__{} = task) do
    task.stage_state == :running or
      is_binary(task.active_chat_role_id) or
      (is_binary(task.id) and Rail.Runs.running?(task.id))
  end

  def busy?(_other), do: false

  @doc """
  Returns whether the task uses the Designer stage:
  true while the task has not yet advanced past Design (i.e. stage in [:product, :design]),
  or if a Designer run exists in its history.
  """
  def uses_design?(task, role_runs \\ [])

  def uses_design?(%__MODULE__{stage: stage}, _role_runs) when stage in [:product, :design], do: true

  def uses_design?(%__MODULE__{id: task_id, project_id: project_id}, role_runs)
      when is_list(role_runs) and role_runs != [] do
    Enum.any?(role_runs, fn r ->
      (r.task_id == task_id or is_nil(r.task_id)) and designer_role_run?(r, project_id)
    end)
  end

  def uses_design?(%__MODULE__{id: task_id, project_id: project_id}, _empty)
      when is_binary(task_id) and is_binary(project_id) do
    case Rail.Roles.role_for_stage(project_id, :design) do
      {:ok, %{id: designer_role_id}} ->
        Repo.exists?(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^designer_role_id)

      _no_role ->
        false
    end
  end

  def uses_design?(%__MODULE__{}, _opts), do: false
  def uses_design?(_other, _opts), do: false

  defp designer_role_run?(%{role_id: "designer"}, _project_id), do: true
  defp designer_role_run?(%{role: %{stage: :design}}, _project_id), do: true

  defp designer_role_run?(%{role_id: role_id}, project_id) when is_binary(role_id) and is_binary(project_id) do
    case Rail.Roles.role_for_stage(project_id, :design) do
      {:ok, %{id: ^role_id}} -> true
      _other -> false
    end
  end

  defp designer_role_run?(_other, _project_id), do: false

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end
