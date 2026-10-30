defmodule Rail.Issues.Schemas.Issue do
  @moduledoc false
  use Rail.Schema

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Users.Schemas.User
  alias Rail.Workflows.Schemas.Workflow

  @priorities [:urgent, :high, :medium, :low]
  @states [:backlog, :triage, :todo, :in_progress, :in_review, :done, :canceled, :duplicate]
  @finished_states [:done, :canceled, :duplicate]
  @optional_steps [:product, :design, :architect, :demo]
  @plan_steps [:product, :design, :architect]

  @primary_key {:id, UXID, autogenerate: true, prefix: "iss"}
  schema "issues" do
    field :external_id, :string
    field :identifier, :string
    field :title, :string
    field :description, :string
    field :priority, Ecto.Enum, values: @priorities, default: :medium
    field :estimate, :integer
    field :state, Ecto.Enum, values: @states
    field :state_name, :string
    field :branch_name, :string
    field :url, :string
    field :completed_at, :utc_datetime

    # Set while the tracker has it archived. It still counts as shipped, but leaves the Issues list unless a task holds it.
    field :archived_at, :utc_datetime
    # Copied from the project when the issue is made, so it keeps talking to the tracker it came from.
    field :tracker, Ecto.Enum, values: [:linear, :github], default: :linear
    # GitHub's issue number, which its REST paths take; nil for Linear.
    field :number, :integer
    # The tracker's own updated_at: where a poll resumes, and how a stale webhook is told apart.
    field :external_updated_at, :utc_datetime_usec
    # The open pull request its work was opened as outside Rail, kept once found so it is not looked up again.
    field :pr_number, :integer
    field :pr_url, :string
    field :pr_title, :string
    # Copied from the workflow's file when it opened the issue, so a later change to the file leaves its task alone.
    field :skipped_steps, {:array, Ecto.Enum}, values: @optional_steps, default: []
    # The stages its workflow's file named, custom ones with their prompts, copied the same way; empty runs the built-ins.
    embeds_many :stages, IssueStage, on_replace: :delete
    # Linear's ids for its cycle and its parent, which only the tracker sets.
    field :cycle_external_id, :string

    belongs_to :parent, __MODULE__,
      foreign_key: :parent_external_id,
      references: :external_id,
      type: :string

    has_many :children, __MODULE__,
      foreign_key: :parent_external_id,
      references: :external_id,
      preload_order: [asc: :inserted_at, asc: :id]

    belongs_to :project, Project
    belongs_to :owner_user, User
    # The workflow that opened it, or nil for one somebody filed.
    belongs_to :workflow, Workflow

    # The live task. Cleaned-up tasks stay in the table as history.
    has_one :task, Task, where: [cleaned_up_at: nil]
    has_many :comments, Comment

    timestamps()
  end

  @cast_fields [
    :archived_at,
    :branch_name,
    :completed_at,
    :description,
    :estimate,
    :external_id,
    :external_updated_at,
    :identifier,
    :number,
    :owner_user_id,
    :priority,
    :project_id,
    :state_name,
    :state,
    :title,
    :tracker,
    :url,
    :workflow_id
  ]

  @required_fields [
    :project_id,
    :external_id,
    :identifier,
    :title,
    :state
  ]

  def changeset(issue, attrs) do
    issue
    |> base_changeset(attrs)
    |> sync_to_tracker()
  end

  @doc """
  For what the tracker itself reports: `changeset/2` with nothing queued to push back, plus the cycle and the parent,
  which Rail never sends. Either one, giving an unowned issue an owner, queues `Workers.AdvanceTrackerState`.
  """
  def tracker_changeset(issue, attrs) do
    issue
    |> cast(attrs, [:cycle_external_id, :parent_external_id])
    |> base_changeset(attrs)
  end

  @doc """
  A changeset moving the ticket back to `state`, `:todo` for Discard or `:in_progress` for Back to Plan. Forced, so
  the tracker is told even when Rail's copy already reads it, and its name waits for the tracker's own.
  """
  def reset_changeset(issue, state) when state in [:todo, :in_progress] do
    issue
    |> change(state_name: nil)
    |> force_change(:state, state)
    |> sync_to_tracker()
  end

  @doc """
  A changeset linking the issue to the pull request found for it, or clearing it with nils. It is Rail's own
  record, so nothing goes to the tracker.
  """
  def pull_request_changeset(issue, attrs), do: cast(issue, attrs, [:pr_number, :pr_url, :pr_title])

  def priorities, do: @priorities
  def states, do: @states
  def finished_states, do: @finished_states

  def priority_label(:urgent), do: "Urgent"
  def priority_label(:high), do: "High"
  def priority_label(:medium), do: "Medium"
  def priority_label(:low), do: "Low"
  def priority_label(_other), do: nil

  def tracker_label(:github), do: "GitHub"
  def tracker_label(:linear), do: "Linear"

  def state_label(:backlog), do: "Backlog"
  def state_label(:triage), do: "Triage"
  def state_label(:todo), do: "Todo"
  def state_label(:in_progress), do: "In Progress"
  def state_label(:in_review), do: "In Review"
  def state_label(:done), do: "Done"
  def state_label(:canceled), do: "Canceled"
  def state_label(:duplicate), do: "Duplicate"
  def state_label(_other), do: nil

  @doc "The steps a workflow can turn off: Product, Design and Architect in Plan, and the demo in Review."
  def optional_steps, do: @optional_steps

  def skips_step?(%__MODULE__{skipped_steps: skipped}, step) when step in @optional_steps, do: step in skipped

  def step_label(:product), do: "product"
  def step_label(:design), do: "design"
  def step_label(:architect), do: "architect"
  def step_label(:demo), do: "demo"

  @doc """
  The stages the issue's task runs, in order, a custom one as `{:custom, name}`: Plan, Engineer and Review when its
  workflow named none, and Plan left out when Product, Design and Architect are all off.
  """
  def calculate_stages(%__MODULE__{skipped_steps: skipped, stages: stages}) do
    sequence =
      case stages do
        [_first | _rest] -> Enum.map(stages, &sequence_stage/1)
        _none -> [:plan, :engineer, :review]
      end

    if Enum.all?(@plan_steps, &(&1 in skipped)), do: List.delete(sequence, :plan), else: sequence
  end

  @doc "The stage the issue's task enters after `stage`, as `calculate_stages/1` names them, or nil after the last."
  def calculate_next_stage(%__MODULE__{} = issue, stage) do
    issue |> calculate_stages() |> Enum.drop_while(&(&1 != stage)) |> Enum.at(1)
  end

  @doc "The custom stage of the issue's sequence named `name`, with its prompt, or nil."
  def custom_stage(%__MODULE__{stages: stages}, name) when is_list(stages),
    do: Enum.find(stages, &match?(%IssueStage{stage: :custom, name: ^name}, &1))

  @doc "The issue's parent when Rail holds it in the issue's own project, so no other project's title shows."
  def calculate_parent(%__MODULE__{project_id: project_id, parent: %__MODULE__{project_id: project_id} = parent}),
    do: parent

  def calculate_parent(%__MODULE__{}), do: nil

  @doc "The issue's sub-issues Rail holds in its own project, oldest first."
  def calculate_children(%__MODULE__{project_id: project_id, children: children}) when is_list(children),
    do: Enum.filter(children, &(&1.project_id == project_id))

  def calculate_children(%__MODULE__{}), do: []

  @doc "Its sub-issues in Done, out of all of them but canceled and duplicate ones, as `{done, total}`."
  def calculate_sub_issue_count(%__MODULE__{} = issue) do
    counted = issue |> calculate_children() |> Enum.reject(&(&1.state in [:canceled, :duplicate]))
    {Enum.count(counted, &(&1.state == :done)), length(counted)}
  end

  @doc """
  Nests `issues` one level deep, each tree where its first member was. A row is its issue, its key, whether it is a
  dimmed copy of a parent that is not a top-level row of the list, and its sub-issues.
  """
  def calculate_issue_tree(issues) when is_list(issues), do: build_tree(issues, nil)

  @doc """
  The cycle's issues in status groups: Linear's statuses, started ones furthest along first and finished ones last,
  then Rail's label for any status Linear does not list. Each has its rows, its count and its points, an unestimated
  issue counting its own project's default estimate from `default_estimates`.
  """
  def calculate_status_groups(issues, statuses, default_estimates) when is_list(issues) do
    names = MapSet.new(statuses, & &1.name)
    {named, unnamed} = Enum.split_with(issues, &MapSet.member?(names, &1.state_name))

    linear_groups =
      for status <- Enum.sort_by(statuses, &status_rank/1),
          do: {status.name, status_state(status), Enum.filter(named, &(&1.state_name == status.name))}

    rail_groups = for state <- @states, do: {state_label(state), state, Enum.filter(unnamed, &(&1.state == state))}

    (linear_groups ++ rail_groups)
    |> Enum.reject(&match?({_label, _state, []}, &1))
    |> Enum.with_index(fn {label, state, members}, index ->
      %{
        key: "group-#{index}",
        label: label,
        state: state,
        rows: build_tree(members, "group-#{index}"),
        count: length(members),
        points: members |> Enum.map(&(&1.estimate || default_estimates[&1.project_id])) |> Enum.sum()
      }
    end)
  end

  @doc """
  The state an issue's status icon shows: In Review for one Rail holds as In Progress under a status named In Review,
  since Linear gives both the same type.
  """
  def calculate_shown_state(%__MODULE__{state: :in_progress, state_name: name}) when is_binary(name) do
    if String.downcase(name) == "in review", do: :in_review, else: :in_progress
  end

  def calculate_shown_state(%__MODULE__{state: state}), do: state

  @doc "The entries of a blocked-by list whose issue is not finished yet."
  def calculate_open_blockers(entries) when is_list(entries), do: Enum.reject(entries, &finished_state?(&1.issue.state))

  def finished_state?(state) when is_atom(state), do: state in @finished_states
  def finished_state?(_other), do: false

  def finished?(state), do: finished_state?(state)
  def closed?(state), do: finished_state?(state)

  def active?(state) when is_atom(state), do: state in [:triage, :backlog, :todo, :in_progress, :in_review]
  def active?(_other), do: false

  defp base_changeset(issue, attrs) do
    issue
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:external_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:workflow_id)
    |> advance_when_claimed()
  end

  # Every write goes up to the tracker, so no caller can forget to say so. This runs
  # inside the write's own transaction, which is what makes the job and the row
  # land together or not at all. An insert has nothing to sync back: the ticket
  # is opened in the tracker first and the row is what came back from it.
  defp sync_to_tracker(%Ecto.Changeset{data: %__MODULE__{id: id}, changes: changes} = changeset)
       when is_binary(id) and changes != %{} do
    prepare_changes(changeset, fn prepared ->
      # GitHub unassigns by login, so the job carries who held the issue before.
      %{issue_id: id, fields: Map.keys(prepared.changes), previous_owner_user_id: prepared.data.owner_user_id}
      |> SyncIssue.new()
      |> Oban.insert!()

      prepared
    end)
  end

  defp sync_to_tracker(%Ecto.Changeset{} = changeset), do: changeset

  # An unowned ticket's tracker status is held back while its task runs, so whatever
  # gives it an owner also queues the move that catches it up. Here, for the same
  # reason as the sync above: no way of setting the owner can forget to.
  defp advance_when_claimed(
         %Ecto.Changeset{data: %__MODULE__{id: id, owner_user_id: nil}, changes: %{owner_user_id: owner_user_id}} =
           changeset
       )
       when is_binary(id) and is_binary(owner_user_id) do
    prepare_changes(changeset, fn prepared ->
      %{issue_id: id}
      |> AdvanceTrackerState.new()
      |> Oban.insert!()

      prepared
    end)
  end

  defp advance_when_claimed(%Ecto.Changeset{} = changeset), do: changeset

  defp build_tree(issues, prefix) do
    by_id = Map.new(issues, &{&1.id, &1})

    {roots, members} =
      Enum.reduce(issues, {[], %{}}, fn issue, {roots, members} ->
        {_kind, head} = root = tree_root(issue, by_id)

        if Map.has_key?(members, head.id),
          do: {roots, Map.update!(members, head.id, &[issue | &1])},
          else: {[root | roots], Map.put(members, head.id, [issue])}
      end)

    roots
    |> Enum.reverse()
    |> Enum.map(fn {kind, head} -> tree_row(kind, head, Enum.reverse(members[head.id]), prefix) end)
  end

  # Only an issue with no parent of its own is a head, so nesting stays one level deep.
  defp tree_root(issue, by_id) do
    parent = calculate_parent(issue)
    listed = parent && by_id[parent.id]

    cond do
      is_nil(parent) -> {:real, issue}
      listed != nil and is_nil(calculate_parent(listed)) -> {:real, listed}
      true -> {:copy, parent}
    end
  end

  defp tree_row(:real, head, members, _prefix) do
    sub_issues = for %{id: id} = issue <- members, id != head.id, do: %{issue: issue, key: id}
    %{issue: head, key: head.id, dimmed: false, sub_issues: sub_issues}
  end

  # A parent can be copied above several groups' sub-issues, so its key names the group and the first of them.
  defp tree_row(:copy, head, [first | _rest] = members, prefix) do
    key = Enum.join(Enum.reject([prefix, head.id, "above", first.id], &is_nil/1), "-")
    %{issue: head, key: key, dimmed: true, sub_issues: Enum.map(members, &%{issue: &1, key: &1.id})}
  end

  defp status_rank(%{type: "started", position: position}), do: {0, -position}
  defp status_rank(%{type: type, position: position}), do: {type_rank(type), position}

  defp type_rank("unstarted"), do: 1
  defp type_rank("backlog"), do: 2
  defp type_rank("triage"), do: 3
  defp type_rank("completed"), do: 4
  defp type_rank(_canceled_or_other), do: 5

  defp status_state(%{type: "started", name: name}),
    do: if(String.downcase(name) == "in review", do: :in_review, else: :in_progress)

  defp status_state(%{type: "unstarted"}), do: :backlog
  defp status_state(%{type: "triage"}), do: :triage
  defp status_state(%{type: "completed"}), do: :done
  defp status_state(%{type: "canceled"}), do: :canceled
  defp status_state(%{type: _backlog_or_other}), do: :backlog

  defp sequence_stage(%IssueStage{stage: :custom, name: name}), do: {:custom, name}
  defp sequence_stage(%IssueStage{stage: stage}), do: stage
end
