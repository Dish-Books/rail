defmodule Rail.Learnings.Schemas.LearningProposal do
  @moduledoc """
  A change to the rules waiting on a person. `learning` is the draft for an add, merge or rewrite and the rule in question otherwise;
  at most one override is pending per rule.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings.Schemas.CuratorPass
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Projects.Schemas.Project
  alias Rail.Users.Schemas.User

  @actions [:add, :merge, :rewrite, :retire, :conflict, :promote, :override]
  @statuses [:pending, :approved, :rejected]
  @promote_targets [:credo_check, :role_prompt, :claude_md]

  @primary_key {:id, UXID, autogenerate: true, prefix: "lpr"}
  schema "learning_proposals" do
    field :action, Ecto.Enum, values: @actions
    field :title, :string
    field :summary, :string
    field :target_ids, {:array, :string}, default: []
    field :evidence_ids, {:array, :string}, default: []
    field :promote_to, Ecto.Enum, values: @promote_targets
    field :source_key, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :decided_at, :utc_datetime_usec

    # The rules and sightings `target_ids` and `evidence_ids` name, loaded by `get_learning_proposal/1`.
    field :targets, {:array, :any}, virtual: true, default: []
    field :evidence, {:array, :any}, virtual: true, default: []

    belongs_to :project, Project
    belongs_to :learning, Learning
    belongs_to :issue, Issue
    belongs_to :decided_by, User
    belongs_to :curator_pass, CuratorPass

    timestamps()
  end

  @doc """
  Builds a changeset for a proposal. The project, its status and who decided it
  are set by the caller.
  """
  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :action,
      :title,
      :summary,
      :learning_id,
      :target_ids,
      :evidence_ids,
      :promote_to,
      :source_key,
      :curator_pass_id
    ])
    |> validate_required([:action, :learning_id])
    |> unique_constraint([:project_id, :source_key])
    |> unique_constraint(:learning_id, name: :learning_proposals_pending_override_index)
  end

  def promote_targets, do: @promote_targets

  def action_label(:add), do: "Add"
  def action_label(:merge), do: "Merge"
  def action_label(:rewrite), do: "Rewrite"
  def action_label(:retire), do: "Retire"
  def action_label(:conflict), do: "Conflict"
  def action_label(:promote), do: "Promote"
  def action_label(:override), do: "Overridden"

  def promote_label(:credo_check), do: "a lint check"
  def promote_label(:role_prompt), do: "a role prompt"
  def promote_label(:claude_md), do: "a line in the repo's CLAUDE.md"

  @doc "True for the actions whose `learning` is a draft rather than an existing rule."
  def drafts?(%__MODULE__{action: action}), do: action in [:add, :merge, :rewrite]
end
