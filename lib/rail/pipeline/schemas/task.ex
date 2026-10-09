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
  # `:split` is a parent whose children carry the work, and it waits there until they merge.
  @stages [
    :plan,
    :engineer,
    :review,
    :merged,
    :debugger,
    :split
  ]

  @primary_key {:id, UXID, autogenerate: true, prefix: "tsk"}
  schema "tasks" do
    field :stage, Ecto.Enum, values: @stages, default: :plan
    field :worktree_name, :string
    field :worktree_path, :string
    field :scratch_path, :string
    field :merged_at, :utc_datetime_usec
    field :cleaned_up_at, :utc_datetime_usec
    # A block of ports on this machine, unique across every project's tasks.
    field :worktree_slot, :integer
    field :worktree_setup_at, :utc_datetime_usec
    # The pull request Rail opened, as a draft, the first time the branch was pushed.
    field :pr_number, :integer
    field :pr_url, :string
    field :pr_is_draft, :boolean
    # The default branch is being merged in, and has stopped on conflicts or not yet been sent on.
    field :is_updating_branch, :boolean, default: false
    # Set once the curator has distilled the finished task, so it is never read twice.
    field :learnings_extracted_at, :utc_datetime_usec
    # A child of a split: its place in it, from 1, and the earlier places it waits on to merge.
    field :split_position, :integer
    field :builds_on, {:array, :integer}, default: []

    belongs_to :project, Project
    belongs_to :issue, Issue
    belongs_to :parent_task, __MODULE__

    has_many :children, __MODULE__, foreign_key: :parent_task_id, preload_order: [asc: :split_position]

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
    :worktree_setup_at,
    :pr_number,
    :pr_url,
    :pr_is_draft,
    :is_updating_branch,
    :learnings_extracted_at,
    :split_position,
    :builds_on
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
    |> unique_constraint(:split_position, name: :tasks_parent_task_id_split_position_index)
    |> validate_number(:split_position, greater_than: 0)
    |> validate_builds_on()
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

  @doc """
  The stage of the role that works a task at `stage`: Review is led by the Review lead, whose
  subagents are the review, QA, engineer and demo roles.
  """
  def role_stage(:review), do: :review_lead
  def role_stage(stage) when is_atom(stage), do: stage

  @doc "True when Review's demo recorder has a video on disk for `task`."
  def demo_recorded?(%__MODULE__{scratch_path: scratch_path}) do
    File.regular?(Path.join([scratch_path, "demo", "demo.webm"]))
  end

  @doc """
  The siblings a child of a split builds on that will never merge: `{canceled, removed}`, the canceled
  ones by identifier and those deleted in Linear, task and all, as `child N`. Needs the siblings' issues.
  """
  def split_blockers(%__MODULE__{builds_on: builds_on}, siblings) do
    by_position = Map.new(siblings, &{&1.split_position, &1})

    canceled =
      for position <- builds_on,
          %__MODULE__{issue: %Issue{completed_at: nil, state: state} = issue} <- [by_position[position]],
          state in [:canceled, :duplicate],
          do: issue.identifier

    {canceled, for(position <- builds_on, not Map.has_key?(by_position, position), do: "child #{position}")}
  end

  def stage_label(:plan), do: "Plan"
  def stage_label(:engineer), do: "Engineer"
  def stage_label(:review), do: "Review"
  def stage_label(:merged), do: "Merged"
  def stage_label(:debugger), do: "Debugger"
  def stage_label(:split), do: "Split"
  def stage_label(_other), do: nil

  def cast_stage(stage) when is_atom(stage) do
    if stage in @stages, do: {:ok, stage}, else: :error
  end

  def cast_stage(stage) when is_binary(stage) do
    found = Enum.find(@stages, fn s -> Atom.to_string(s) == stage end)
    if found, do: {:ok, found}, else: :error
  end

  def cast_stage(_other), do: :error

  # A child waits only on siblings before it, so the order it is listed in is an order it can run in.
  defp validate_builds_on(changeset) do
    position = get_field(changeset, :split_position)

    validate_change(changeset, :builds_on, fn :builds_on, builds_on ->
      if is_integer(position) and Enum.all?(builds_on, &(&1 in 1..(position - 1)//1)),
        do: [],
        else: [builds_on: "must name only earlier children"]
    end)
  end

  defp maybe_put_project_id(changeset, nil), do: changeset
  defp maybe_put_project_id(changeset, project_id), do: put_change(changeset, :project_id, project_id)
end
