defmodule Rail.Pipeline.Schemas.Task do
  @moduledoc """
  Schema for a task moving through the development pipeline.
  """
  use Rail.Schema

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  # The linear pipeline, then stages a task can be parked in off that path.
  # `:debugger` has no position in the sequence: nothing advances into or out of
  # it, so `stage_index/1` leaves it unranked and `next_stage/1` has no clause.
  @stages [
    :product,
    :design,
    :architect,
    :engineer,
    :review,
    :qa,
    :qa_lead,
    :demo,
    :ready_to_merge,
    :merged,
    :debugger
  ]

  @mergeabilities [:clean, :mergeable, :conflicting, :blocked, :unknown]

  @primary_key {:id, UXID, autogenerate: true, prefix: "tsk"}
  schema "tasks" do
    field :stage, Ecto.Enum, values: @stages, default: :product
    field :worktree_name, :string
    field :worktree_path, :string
    field :scratch_path, :string
    field :pr_number, :integer
    field :pr_url, :string
    field :mergeability, Ecto.Enum, values: @mergeabilities
    field :pr_is_draft, :boolean
    field :is_rebasing, :boolean, default: false
    field :error, :string
    field :rework_cycles, :integer, default: 0
    field :rework_budget_base, :integer, default: 0
    field :rework_cycles_by_gate, :map, default: %{}
    field :outstanding_reports, {:array, :string}, default: []
    field :viewed_diff_files, Rail.Pipeline.Types.ViewedDiffFiles, default: %{}
    field :merged_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :issue, Issue

    has_many :questions, Question
    has_many :plans, Plan
    has_many :runs, Run
    has_many :designs, Design
    has_many :demos, Demo

    field :demo, :any, virtual: true
    field :design, :any, virtual: true

    timestamps()
  end

  @cast_fields [
    :issue_id,
    :stage,
    :worktree_name,
    :worktree_path,
    :scratch_path,
    :pr_number,
    :pr_url,
    :mergeability,
    :pr_is_draft,
    :is_rebasing,
    :error,
    :rework_cycles,
    :rework_budget_base,
    :rework_cycles_by_gate,
    :outstanding_reports,
    :viewed_diff_files,
    :merged_at
  ]

  @required_fields [
    :project_id,
    :stage,
    :worktree_name,
    :worktree_path,
    :scratch_path
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
  end

  @doc """
  True when the task's worktree directory is actually on disk.

  `worktree_path` is always set, so it says where the worktree belongs, not
  whether it is still there — merge and cleanup remove the directory and leave
  the path alone.
  """
  def worktree_present?(%__MODULE__{worktree_path: path}) do
    File.dir?(path)
  end

  def stages, do: @stages
  def mergeabilities, do: @mergeabilities

  def next_stage(:product), do: :design
  def next_stage(:design), do: :architect
  def next_stage(:architect), do: :engineer
  def next_stage(:engineer), do: :review
  def next_stage(:review), do: :qa
  def next_stage(:qa), do: :qa_lead
  def next_stage(:qa_lead), do: :demo
  def next_stage(:demo), do: :ready_to_merge
  def next_stage(:ready_to_merge), do: :merged
  def next_stage(_other), do: nil

  def prev_stage(:product), do: nil
  def prev_stage(:design), do: :product
  def prev_stage(:architect), do: :design
  def prev_stage(:engineer), do: :architect
  def prev_stage(:review), do: :engineer
  def prev_stage(:qa), do: :review
  def prev_stage(:qa_lead), do: :qa
  def prev_stage(:demo), do: :qa_lead
  def prev_stage(:ready_to_merge), do: :demo
  def prev_stage(:merged), do: :ready_to_merge
  def prev_stage(_other), do: nil

  def previous_stage(stage), do: prev_stage(stage)

  def advanceable?(stage) when is_atom(stage) do
    stage in [
      :product,
      :design,
      :architect,
      :engineer,
      :review,
      :qa,
      :qa_lead,
      :demo,
      :ready_to_merge
    ]
  end

  def advanceable?(_other), do: false

  def gate?(stage) when is_atom(stage), do: stage in [:review, :qa, :qa_lead]
  def gate?(_other), do: false

  def terminal_stage?(:merged), do: true
  def terminal_stage?(_other), do: false

  def terminal?(stage), do: terminal_stage?(stage)

  def stage_index(:product), do: 0
  def stage_index(:design), do: 1
  def stage_index(:architect), do: 2
  def stage_index(:engineer), do: 3
  def stage_index(:review), do: 4
  def stage_index(:qa), do: 5
  def stage_index(:qa_lead), do: 6
  def stage_index(:demo), do: 7
  def stage_index(:ready_to_merge), do: 8
  def stage_index(:merged), do: 9
  def stage_index(_other), do: nil

  def index(stage), do: stage_index(stage)

  def before?(stage_a, stage_b) when is_atom(stage_a) and is_atom(stage_b) do
    idx_a = stage_index(stage_a)
    idx_b = stage_index(stage_b)

    if idx_a && idx_b, do: idx_a < idx_b, else: false
  end

  def before?(_a, _b), do: false

  def after?(stage_a, stage_b) when is_atom(stage_a) and is_atom(stage_b) do
    idx_a = stage_index(stage_a)
    idx_b = stage_index(stage_b)

    if idx_a && idx_b, do: idx_a > idx_b, else: false
  end

  def after?(_a, _b), do: false

  def stage_label(:product), do: "Product"
  def stage_label(:design), do: "Design"
  def stage_label(:architect), do: "Architect"
  def stage_label(:engineer), do: "Engineer"
  def stage_label(:review), do: "Review"
  def stage_label(:qa), do: "QA"
  def stage_label(:qa_lead), do: "QA Lead"
  def stage_label(:demo), do: "Demo"
  def stage_label(:ready_to_merge), do: "Ready to merge"
  def stage_label(:merged), do: "Merged"
  def stage_label(:debugger), do: "Debugger"
  def stage_label(_other), do: nil

  def cast_stage(stage) when is_atom(stage) do
    if stage in @stages, do: {:ok, stage}, else: :error
  end

  def cast_stage(stage) when is_binary(stage) do
    found = Enum.find(@stages, fn s -> Atom.to_string(s) == stage end)
    if found, do: {:ok, found}, else: :error
  end

  def cast_stage(_other), do: :error

  @doc """
  Returns whether the task uses the Designer stage:
  true while the task has not yet advanced past Design (i.e. stage in [:product, :design]),
  or if a Designer run exists in its history.
  """
  def uses_design?(task, runs \\ [])

  def uses_design?(%__MODULE__{stage: stage}, _runs) when stage in [:product, :design], do: true

  def uses_design?(%__MODULE__{id: task_id, project_id: project_id}, runs) when is_list(runs) and runs != [] do
    Enum.any?(runs, fn r ->
      (r.task_id == task_id or is_nil(r.task_id)) and designer_run?(r, project_id)
    end)
  end

  def uses_design?(%__MODULE__{id: task_id, project_id: project_id}, _empty)
      when is_binary(task_id) and is_binary(project_id) do
    case Rail.Roles.get_role(project_id: project_id, stage: :design) do
      {:ok, %{id: designer_role_id}} ->
        Repo.exists?(from r in Run, where: r.task_id == ^task_id and r.role_id == ^designer_role_id)

      _no_role ->
        false
    end
  end

  def uses_design?(%__MODULE__{}, _opts), do: false
  def uses_design?(_other, _opts), do: false

  defp designer_run?(%{role_id: "designer"}, _project_id), do: true
  defp designer_run?(%{role: %{stage: :design}}, _project_id), do: true

  defp designer_run?(%{role_id: role_id}, project_id) when is_binary(role_id) and is_binary(project_id) do
    case Rail.Roles.get_role(project_id: project_id, stage: :design) do
      {:ok, %{id: ^role_id}} -> true
      _other -> false
    end
  end

  defp designer_run?(_other, _project_id), do: false

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end
