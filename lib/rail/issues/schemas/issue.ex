defmodule Rail.Issues.Schemas.Issue do
  @moduledoc false
  use Rail.Schema

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.IssueLink
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Issues.Schemas.TestingImage
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Users.Schemas.User
  alias Rail.Workflows.Schemas.Workflow

  @priorities [:urgent, :high, :medium, :low]
  @states [:todo, :in_progress, :in_review, :done, :canceled]
  @finished_states [:done, :canceled]
  @started_states [:in_progress, :in_review]
  @optional_steps [:product, :design, :architect, :demo]
  @plan_steps [:product, :design, :architect]
  @testing_states [:waiting, :testing, :tested, :sent_to_triage]
  @queued_testing_states [:waiting, :testing]

  @primary_key {:id, UXID, autogenerate: true, prefix: "iss"}
  schema "issues" do
    field :identifier, :string
    field :title, :string
    field :description, :string
    field :priority, Ecto.Enum, values: @priorities, default: :medium
    field :estimate, :integer
    field :state, Ecto.Enum, values: @states
    field :branch_name, :string
    field :url, :string
    # To the microsecond, so an update brief can tell a ticket finished just before it from one just after.
    field :completed_at, :utc_datetime_usec

    # Set while the tracker has it archived. It still counts as shipped, but leaves the Issues list unless a task holds it.
    field :archived_at, :utc_datetime
    # The number Postgres assigns the issue as it inserts it, which its identifier is named by.
    field :number, :integer
    # The open pull request its work was opened as outside Rail, kept once found so it is not looked up again.
    field :pr_number, :integer
    field :pr_url, :string
    field :pr_title, :string
    # Copied from the workflow's file when it opened the issue, so a later change to the file leaves its task alone.
    field :skipped_steps, {:array, Ecto.Enum}, values: @optional_steps, default: []
    # The stages its workflow's file named, custom ones with their prompts, copied the same way; empty runs the built-ins.
    embeds_many :stages, IssueStage, on_replace: :delete
    # Every ticket starts Waiting, is queued only while in Done, and keeps its testing when it leaves.
    field :testing_state, Ecto.Enum, values: @testing_states, default: :waiting
    field :testing_notes, :string
    embeds_many :testing_images, TestingImage, on_replace: :delete
    # The state a cycle's listing reads the issue in; set only by `list_issues/1` with `:cycle_id`.
    field :cycle_state, Ecto.Enum, values: @states, virtual: true
    # Written only by `Workers.EmbedIssues`, and left out of every query, so lists and broadcasts carry no vector.
    field :embedding, Pgvector.Ecto.Vector, load_in_query: false
    # The md5 of the title and description the embedding was made from, so an edit since shows as stale.
    field :embedding_digest, :string

    # Its cycle, which Rail sets itself.
    belongs_to :cycle, Cycle
    belongs_to :parent, __MODULE__
    # Its initiative, which Rail sets itself, apart from its parent.
    belongs_to :initiative, Initiative
    has_many :children, __MODULE__, foreign_key: :parent_id, preload_order: [asc: :inserted_at, asc: :id]

    belongs_to :project, Project
    belongs_to :owner_user, User
    # The workflow that opened it, or nil for one somebody filed.
    belongs_to :workflow, Workflow

    # The live task. Cleaned-up tasks stay in the table as history.
    has_one :task, Task, where: [cleaned_up_at: nil]
    # The task it merged with, which `task` drops once it is cleaned up, right after the merge.
    has_one :merged_task, Task, where: [stage: :merged]
    has_many :comments, Comment
    has_many :links, IssueLink, preload_order: [asc: :inserted_at, asc: :id]

    timestamps()
  end

  @cast_fields [
    :archived_at,
    :branch_name,
    :completed_at,
    :description,
    :estimate,
    :identifier,
    :number,
    :owner_user_id,
    :priority,
    :project_id,
    :state,
    :title,
    :url,
    :workflow_id
  ]

  @required_fields [
    :project_id,
    :identifier,
    :title,
    :state
  ]

  def changeset(issue, attrs) do
    issue
    |> base_changeset(attrs)
    |> announce_change()
  end

  @doc """
  `changeset/2` with no change announced, plus the cycle, the parent and the initiative, which Rail sets through it.
  """
  def tracker_changeset(issue, attrs) do
    issue
    |> cast(attrs, [:cycle_id, :parent_id, :initiative_id])
    |> foreign_key_constraint(:initiative_id)
    |> base_changeset(attrs)
  end

  @doc """
  A changeset moving the ticket back to `state`, `:todo` for Discard or `:in_progress` for Back to Plan. Forced, so
  open pages hear of it even when the row already reads it.
  """
  def reset_changeset(issue, state) when state in [:todo, :in_progress] do
    issue
    |> change()
    |> force_change(:state, state)
    |> announce_change()
  end

  @doc """
  A changeset linking the issue to the pull request found for it, or clearing it with nils. It is Rail's own
  record, so no change is announced.
  """
  def pull_request_changeset(issue, attrs), do: cast(issue, attrs, [:pr_number, :pr_url, :pr_title])

  @doc "Casts only the testing notes, and moves a Waiting ticket to In testing once they hold more than whitespace."
  def testing_notes_changeset(%__MODULE__{} = issue, attrs) do
    changeset = cast(issue, attrs, [:testing_notes], empty_values: [])

    if issue.testing_state == :waiting and String.trim(get_field(changeset, :testing_notes) || "") != "",
      do: put_change(changeset, :testing_state, :testing),
      else: changeset
  end

  @doc "Puts the testing pictures, and moves a Waiting ticket to In testing once it has one."
  def testing_images_changeset(%__MODULE__{} = issue, images) when is_list(images) do
    changeset = put_embed(change(issue), :testing_images, images)

    if issue.testing_state == :waiting and images != [],
      do: put_change(changeset, :testing_state, :testing),
      else: changeset
  end

  @doc """
  A person's edit of an issue's text and properties. `Rail.Issues.edit_issue/3` broadcasts the change itself, and sets
  the parent apart from the cast.
  """
  def edit_changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :description, :priority, :estimate])
    |> validate_required([:title])
    |> validate_number(:estimate, greater_than_or_equal_to: 0)
  end

  def priorities, do: @priorities
  def states, do: @states
  def finished_states, do: @finished_states

  def priority_label(:urgent), do: "Urgent"
  def priority_label(:high), do: "High"
  def priority_label(:medium), do: "Medium"
  def priority_label(:low), do: "Low"
  def priority_label(_other), do: nil

  def state_label(:todo), do: "Todo"
  def state_label(:in_progress), do: "In Progress"
  def state_label(:in_review), do: "In Review"
  def state_label(:done), do: "Done"
  def state_label(:canceled), do: "Canceled"
  def state_label(_other), do: nil

  def testing_states, do: @testing_states

  def testing_label(:waiting), do: "Waiting"
  def testing_label(:testing), do: "In testing"
  def testing_label(:tested), do: "Tested"
  def testing_label(:sent_to_triage), do: "Sent to triage"

  @doc "Whether the ticket is in the testing queue: in Done, and Waiting or In testing."
  def in_testing_queue?(%__MODULE__{state: :done, testing_state: testing}), do: testing in @queued_testing_states
  def in_testing_queue?(%__MODULE__{}), do: false

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
    counted = issue |> calculate_children() |> Enum.reject(&(&1.state == :canceled))
    {Enum.count(counted, &(&1.state == :done)), length(counted)}
  end

  @doc """
  Nests `issues` one level deep, each tree where its first member was. A row is its issue, its key, whether it is a
  dimmed copy of a parent that is not a top-level row of the list, and its sub-issues.
  """
  def calculate_issue_tree(issues) when is_list(issues), do: build_tree(issues, nil)

  @doc """
  The cycle's issues in status groups: the tracker's statuses, started ones furthest along first and finished ones last,
  then Rail's label for any status the tracker does not list. Each issue is grouped as its cycle holds it, with the live
  issue in the group's rows, its count and its points, an unestimated one counting `default_estimates` for its project.
  """
  def calculate_status_groups(issues, statuses, default_estimates) when is_list(issues) do
    names = MapSet.new(statuses, & &1.name)
    held = Enum.map(issues, &{as_cycle_holds(&1), &1})
    # By the shown name, since Discard and a closed cycle leave an issue with none of its own.
    {named, unnamed} =
      Enum.split_with(held, fn {as_held, _live} -> MapSet.member?(names, calculate_status_name(as_held)) end)

    tracker_groups =
      for status <- Enum.sort_by(statuses, &status_rank/1),
          do:
            {status.name, status_state(status),
             for({as_held, live} <- named, calculate_status_name(as_held) == status.name, do: live)}

    rail_groups =
      for state <- @states,
          do: {state_label(state), state, for({as_held, live} <- unnamed, as_held.state == state, do: live)}

    (tracker_groups ++ rail_groups)
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

  @doc "The state an issue's status icon shows."
  def calculate_shown_state(%__MODULE__{state: state}), do: state

  @doc "The name of the issue's status."
  def calculate_status_name(%__MODULE__{state: state}), do: state_label(state)

  @doc "The entries of a blocked-by list whose issue is not finished yet."
  def calculate_open_blockers(entries) when is_list(entries), do: Enum.reject(entries, &finished_state?(&1.issue.state))

  def finished_state?(state) when is_atom(state), do: state in @finished_states
  def finished_state?(_other), do: false

  def started_state?(state), do: state in @started_states

  def finished?(state), do: finished_state?(state)
  def closed?(state), do: finished_state?(state)

  def active?(state) when is_atom(state), do: state in [:todo, :in_progress, :in_review]
  def active?(_other), do: false

  defp base_changeset(issue, attrs) do
    issue
    |> cast(attrs, @cast_fields)
    |> validate_required_fields()
    |> unique_constraint(:number, name: :issues_project_id_number_index)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:workflow_id)
  end

  # Postgres names an issue as it inserts it, from the number it assigns.
  defp validate_required_fields(%Ecto.Changeset{data: %__MODULE__{id: nil}} = changeset),
    do: validate_required(changeset, List.delete(@required_fields, :identifier))

  defp validate_required_fields(changeset), do: validate_required(changeset, @required_fields)

  # Every write tells the pages showing the issue, so no caller can forget to. The job is queued inside the write's own
  # transaction, so it runs only once the change is there to read. An insert announces itself where it is made.
  defp announce_change(%Ecto.Changeset{data: %__MODULE__{id: id}, changes: changes} = changeset)
       when is_binary(id) and changes != %{} do
    prepare_changes(changeset, fn prepared ->
      %{issue_id: id} |> SyncIssue.new() |> Oban.insert!()
      prepared
    end)
  end

  defp announce_change(%Ecto.Changeset{} = changeset), do: changeset

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

  defp as_cycle_holds(%__MODULE__{cycle_state: nil} = issue), do: issue

  defp as_cycle_holds(%__MODULE__{cycle_state: state} = issue), do: %{issue | state: state}

  defp status_rank(%{type: "started", position: position}), do: {0, -position}
  defp status_rank(%{type: type, position: position}), do: {type_rank(type), position}

  defp type_rank("unstarted"), do: 1
  defp type_rank("backlog"), do: 2
  defp type_rank("triage"), do: 3
  defp type_rank("completed"), do: 4
  defp type_rank(_canceled_or_other), do: 5

  # Rail's own statuses say which state they are. A Triage, Backlog or Todo kind is Todo, a Duplicate one Canceled.
  defp status_state(%{state: state}) when is_atom(state), do: state

  defp status_state(%{type: "started", name: name}),
    do: if(String.downcase(name) == "in review", do: :in_review, else: :in_progress)

  defp status_state(%{type: "completed"}), do: :done
  defp status_state(%{type: type}) when type in ["canceled", "duplicate"], do: :canceled
  defp status_state(%{type: _unstarted_or_other}), do: :todo

  defp sequence_stage(%IssueStage{stage: :custom, name: name}), do: {:custom, name}
  defp sequence_stage(%IssueStage{stage: stage}), do: stage
end
