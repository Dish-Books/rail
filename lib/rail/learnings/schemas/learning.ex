defmodule Rail.Learnings.Schemas.Learning do
  @moduledoc """
  One rule a project has learned, the roles it applies to (none means every role), and how it got there.
  Changing its text clears its embedding until the embedding job runs again.
  """
  use Rail.Schema

  alias Rail.Learnings.Schemas.Observation
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles.Schemas.Role
  alias Rail.Users.Schemas.User

  @kinds [:convention, :decision, :environment, :product, :design, :qa, :calibration]
  @statuses [:proposed, :provisional, :active, :retired]
  @roles Role.canonical_stages() -- [:curator]

  @primary_key {:id, UXID, autogenerate: true, prefix: "lrn"}
  schema "learnings" do
    field :rule, :string
    field :why, :string
    field :kind, Ecto.Enum, values: @kinds
    field :roles, {:array, Ecto.Enum}, values: @roles, default: []
    field :path_glob, :string
    field :status, Ecto.Enum, values: @statuses
    field :auto, :boolean, default: false
    field :pinned, :boolean, default: false
    field :activated_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_model, :string

    # The per-card figures and a search's score, filled in by `list_learnings/1`.
    field :run_count, :integer, virtual: true, default: 0
    field :suppressed_count, :integer, virtual: true, default: 0
    field :broken_count, :integer, virtual: true, default: 0
    field :override_count, :integer, virtual: true, default: 0
    field :flagged, :boolean, virtual: true, default: false
    field :similarity, :float, virtual: true

    belongs_to :project, Project
    belongs_to :approved_by, User

    has_many :observations, Observation

    timestamps()
  end

  @doc """
  Builds a changeset for what a person or a pass writes of a rule. Changing its
  rule or its why clears the embedding, which was for the old text.
  """
  def changeset(learning, attrs) do
    learning
    |> cast(attrs, [:rule, :why, :kind, :roles, :path_glob, :pinned])
    |> update_change(:rule, &trim/1)
    |> update_change(:why, &trim/1)
    |> update_change(:path_glob, &trim/1)
    |> validate_required([:rule, :kind])
    |> validate_length(:rule, max: 2_000)
    |> clear_stale_embedding()
    |> foreign_key_constraint(:project_id)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
  def roles, do: @roles

  def kind_label(:convention), do: "Convention"
  def kind_label(:decision), do: "Decision"
  def kind_label(:environment), do: "Environment"
  def kind_label(:product), do: "Product"
  def kind_label(:design), do: "Design"
  def kind_label(:qa), do: "QA"
  def kind_label(:calibration), do: "Calibration"

  def status_label(:proposed), do: "Proposed"
  def status_label(:provisional), do: "Provisional"
  def status_label(:active), do: "Active"
  def status_label(:retired), do: "Retired"

  def role_label(:plan), do: "Plan"
  def role_label(:product), do: "Product"
  def role_label(:design), do: "Designer"
  def role_label(:architect), do: "Architect"
  def role_label(:engineer), do: "Engineer"
  def role_label(:review_lead), do: "Review lead"
  def role_label(:review), do: "Reviewer"
  def role_label(:qa), do: "QA"
  def role_label(:demo), do: "Demo"
  def role_label(:debugger), do: "Debugger"
  def role_label(:triage), do: "Triage"

  @doc "The roles a rule applies to, as a reader says them."
  def roles_label(%__MODULE__{roles: []}), do: "Every role"
  def roles_label(%__MODULE__{roles: roles}), do: Enum.map_join(roles, ", ", &role_label/1)

  @doc "What is embedded for a rule, and what a search is matched against."
  def embedding_text(%__MODULE__{rule: rule, why: why}) when is_binary(why), do: "#{rule}\n\n#{why}"
  def embedding_text(%__MODULE__{rule: rule}), do: rule

  @doc "The rule a person's answer makes: the question with its answer, so a later run can read it on its own."
  def answer_rule(prompt, answer), do: ~s(When asked "#{prompt}": #{answer}) |> String.slice(0, 2_000) |> String.trim()

  @doc """
  What a decision rule answers with: the person's own words while it reads as made from one of its answer `sources`,
  and the rule itself once a person has reworded it.
  """
  def calculate_answer(%__MODULE__{rule: rule}, sources) do
    Enum.find_value(sources, rule, fn
      %{source_kind: :answer, text: prompt, excerpt: answer} -> answer_rule(prompt, answer) == rule && answer
      _other_source -> nil
    end)
  end

  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(nil), do: nil

  defp clear_stale_embedding(changeset) do
    if changed?(changeset, :rule) or changed?(changeset, :why),
      do: change(changeset, embedding: nil, embedding_model: nil),
      else: changeset
  end
end
