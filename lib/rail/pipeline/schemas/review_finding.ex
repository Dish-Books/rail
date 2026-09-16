defmodule Rail.Pipeline.Schemas.ReviewFinding do
  @moduledoc """
  One problem the reviewer found in a change, and what is being done about it.

  Three things are said about a finding and each is said by someone different.
  The reviewer `recommends` fixing it or letting it stand, and on a later pass
  says whether it is `fixed`. The human `decides`, and that is the only column
  the reviewer may not write: a finding the human dismissed stays dismissed
  however many times the change comes back round.

  `key` is the reviewer's own stable name for the finding, which is what lets a
  second pass update the same row rather than raising the problem twice.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task

  @severities [:blocker, :major, :minor, :nit]
  @recommendations [:fix, :skip]
  @statuses [:open, :fixed, :not_fixed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "rvf"}
  schema "review_findings" do
    field :key, :string
    field :title, :string
    field :detail, :string
    field :file, :string
    field :line, :integer
    field :severity, Ecto.Enum, values: @severities
    field :recommendation, Ecto.Enum, values: @recommendations
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :decision, Ecto.Enum, values: @recommendations

    belongs_to :task, Task

    timestamps()
  end

  # `decision` is deliberately absent: it is the human's, and a review that could
  # cast it would overwrite them every time it ran again.
  @cast_fields [
    :task_id,
    :key,
    :title,
    :detail,
    :file,
    :line,
    :severity,
    :recommendation,
    :status
  ]

  @required_fields [
    :task_id,
    :key,
    :title,
    :severity,
    :recommendation,
    :status,
    :decision
  ]

  @doc """
  Builds a changeset for a finding the reviewer raised.

  A finding nobody has ruled on yet starts at the reviewer's recommendation, so
  accepting the review as it stands is the default and the human only has to
  touch what they disagree with.
  """
  def changeset(review_finding, attrs) do
    review_finding
    |> cast(attrs, @cast_fields)
    |> default_decision()
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:task_id, :key])
  end

  @doc """
  Builds a changeset for the human's call on a finding.
  """
  def decision_changeset(review_finding, decision) when decision in @recommendations do
    change(review_finding, decision: decision)
  end

  @doc """
  True when this finding is still asking something of the engineer.
  """
  def outstanding?(%__MODULE__{decision: :skip}), do: false
  def outstanding?(%__MODULE__{status: :fixed}), do: false
  def outstanding?(%__MODULE__{}), do: true

  @doc """
  Where a finding sits right now, as the one word the panel groups by.
  """
  def state(%__MODULE__{decision: :skip}), do: :dismissed
  def state(%__MODULE__{status: :fixed}), do: :fixed
  def state(%__MODULE__{status: :not_fixed}), do: :not_fixed
  def state(%__MODULE__{}), do: :to_fix

  def severities, do: @severities
  def recommendations, do: @recommendations
  def statuses, do: @statuses

  def severity_label(:blocker), do: "Blocker"
  def severity_label(:major), do: "Major"
  def severity_label(:minor), do: "Minor"
  def severity_label(:nit), do: "Nit"

  defp default_decision(changeset) do
    case {get_field(changeset, :decision), get_field(changeset, :recommendation)} do
      {nil, recommendation} when recommendation in @recommendations -> put_change(changeset, :decision, recommendation)
      _already_decided -> changeset
    end
  end
end
