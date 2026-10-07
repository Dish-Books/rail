defmodule Rail.Learnings.Schemas.Observation do
  @moduledoc """
  One sighting a rule could come from, recorded once per source; a distilled one has no source id and is guarded
  by its task's extraction marker instead.
  """
  use Rail.Schema

  alias Rail.Learnings.Schemas.CuratorPass
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Users.Schemas.User

  @source_kinds [
    :diff_comment,
    :design_comment,
    :review_finding,
    :qa_finding,
    :answer,
    :override,
    :pr_review_comment,
    :pr_review,
    :extraction
  ]

  @primary_key {:id, UXID, autogenerate: true, prefix: "obs"}
  schema "observations" do
    field :source_kind, Ecto.Enum, values: @source_kinds
    field :source_id, :string
    field :source_url, :string
    field :actor_name, :string
    field :text, :string
    field :excerpt, :string
    field :abandoned, :boolean, default: false
    # A design comment's element as it was captured, its HTML and box, for the Learnings page to draw.
    field :capture, :map

    belongs_to :project, Project
    belongs_to :task, Task
    belongs_to :actor, User
    belongs_to :learning, Learning
    belongs_to :curator_pass, CuratorPass

    timestamps()
  end

  @doc """
  Builds a changeset for an observation. The project is set by the caller.
  """
  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :task_id,
      :source_kind,
      :source_id,
      :source_url,
      :actor_id,
      :actor_name,
      :text,
      :excerpt,
      :abandoned,
      :learning_id,
      :capture
    ])
    |> validate_required([:source_kind, :text])
    |> unique_constraint([:project_id, :source_kind, :source_id])
  end

  def source_kinds, do: @source_kinds

  def source_label(:diff_comment), do: "Diff comment"
  def source_label(:design_comment), do: "Design comment"
  def source_label(:review_finding), do: "Fix on a review finding"
  def source_label(:qa_finding), do: "Fix on a QA finding"
  def source_label(:answer), do: "Answer"
  def source_label(:override), do: "Fixed anyway"
  def source_label(:pr_review_comment), do: "PR review comment"
  def source_label(:pr_review), do: "PR review"
  def source_label(:extraction), do: "Seen in a finished task"

  @doc "Who the observation is from, a Rail user or a GitHub login."
  def actor_label(%__MODULE__{actor: %User{name: name}}) when is_binary(name), do: name
  def actor_label(%__MODULE__{actor_name: name}) when is_binary(name), do: name
  def actor_label(%__MODULE__{}), do: "Rail"
end
