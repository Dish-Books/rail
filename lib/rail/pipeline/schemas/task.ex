defmodule Rail.Pipeline.Schemas.Task do
  @moduledoc """
  Schema for a task moving through the development pipeline.

  The stage enum spans the whole pipeline, including the stages nothing drives
  yet: a task can be parked at one of those, it just has no run to show for it.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects.Schemas.Project

  # The linear pipeline, then stages a task can be parked in off that path.
  # `:debugger` has no position in the sequence: nothing advances into or out of it.
  @stages [
    :product,
    :design,
    :architect,
    :engineer,
    :review,
    :qa,
    :demo,
    :ready_to_merge,
    :merged,
    :debugger
  ]

  @primary_key {:id, UXID, autogenerate: true, prefix: "tsk"}
  schema "tasks" do
    field :stage, Ecto.Enum, values: @stages, default: :product
    field :worktree_name, :string
    field :worktree_path, :string
    field :scratch_path, :string
    field :merged_at, :utc_datetime_usec
    field :cleaned_up_at, :utc_datetime_usec
    # A block of ports on this machine, unique across every project's tasks.
    field :worktree_slot, :integer
    field :worktree_setup_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :issue, Issue

    has_one :implementation_plan, ImplementationPlan

    has_many :questions, Question
    has_many :runs, Run

    timestamps()
  end

  @cast_fields [
    :issue_id,
    :stage,
    :worktree_name,
    :worktree_path,
    :scratch_path,
    :merged_at,
    :cleaned_up_at,
    :worktree_slot,
    :worktree_setup_at
  ]

  @required_fields [
    :project_id,
    :issue_id,
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
    |> unique_constraint(:issue_id)
    |> unique_constraint(:worktree_slot, name: :tasks_worktree_slot_index)
  end

  @doc """
  The first of the hundred ports the worktree of a task holding a slot owns.

  Starts well above the 4000s, where checkouts set up by hand pick their own.
  """
  def port_base(%__MODULE__{worktree_slot: slot}) when is_integer(slot), do: 20_000 + slot * 100

  @doc """
  True when the task's worktree directory is actually on disk.

  `worktree_path` is always set, so it says where the worktree belongs, not
  whether it is still there — cleanup removes the directory and leaves the path
  alone.
  """
  def worktree_present?(%__MODULE__{worktree_path: path}) do
    File.dir?(path)
  end

  @doc """
  True when any run on this task is executing.

  A task has no state of its own, so this is the whole of what "busy" can mean:
  not the one run something guessed was active, but every run there is. Requires
  `runs` to be preloaded.
  """
  def running?(%__MODULE__{runs: runs}) when is_list(runs), do: Enum.any?(runs, &Run.running?/1)
  def running?(%__MODULE__{}), do: false

  def stages, do: @stages

  def stage_label(:product), do: "Product"
  def stage_label(:design), do: "Design"
  def stage_label(:architect), do: "Architect"
  def stage_label(:engineer), do: "Engineer"
  def stage_label(:review), do: "Review"
  def stage_label(:qa), do: "QA"
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

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end
