defmodule Rail.Pipeline.Schemas.QaFinding do
  @moduledoc """
  One thing QA found wrong with a change, and what is being done about it.

  QA works the running application rather than the diff, so a finding is told
  the way it was found: the `check` it came out of, the acceptance `criterion`
  it fails, the `screen` it was seen on, the `steps` that reproduce it, and what
  was `expected` against what was `observed`. It points at no file - QA sees the
  app, and a file it guessed at costs the engineer a round.

  `caused_by_change` is what separates this change's fault from someone else's.
  QA is asked to look around the change as well as at it, so it finds things
  nobody here broke; those are worth writing down and are rarely worth fixing on
  this branch, which is why the panel sorts them below the regressions.

  `decision` starts as nothing and only a human ever writes it, as it does for
  [`ReviewFinding`](`Rail.Pipeline.Schemas.ReviewFinding`). The two schemas share
  six predicates and two enum lists and that duplication is deliberate: they are
  raised against the same task, so one table would collide on the key both
  agents pick, and most of the columns of either are meaningless to the other. A
  third stage that raises findings is where extracting them earns its keep.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.Task

  @severities [:blocker, :major, :minor, :nit]
  @recommendations [:fix, :skip]
  @statuses [:open, :fixed, :not_fixed]

  @primary_key {:id, UXID, autogenerate: true, prefix: "qaf"}
  schema "qa_findings" do
    field :key, :string
    field :title, :string
    field :check, :string
    field :criterion, :string
    field :screen, :string
    field :steps, :string
    field :expected, :string
    field :observed, :string
    field :detail, :string
    field :suggestion, :string
    field :severity, Ecto.Enum, values: @severities
    field :recommendation, Ecto.Enum, values: @recommendations
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :caused_by_change, :boolean, default: true
    field :decision, Ecto.Enum, values: @recommendations

    embeds_many :evidence, QaEvidence, on_replace: :delete

    belongs_to :task, Task

    timestamps()
  end

  # `decision` is deliberately absent: it is the human's, and a QA pass that
  # could cast it would overwrite them every time it ran again.
  @cast_fields [
    :task_id,
    :key,
    :title,
    :check,
    :criterion,
    :screen,
    :steps,
    :expected,
    :observed,
    :detail,
    :suggestion,
    :severity,
    :recommendation,
    :status,
    :caused_by_change
  ]

  @required_fields [
    :task_id,
    :key,
    :title,
    :check,
    :severity,
    :recommendation,
    :status
  ]

  @doc """
  Builds a changeset for a finding QA raised.
  """
  def changeset(qa_finding, attrs) do
    qa_finding
    |> cast(attrs, @cast_fields)
    |> cast_embed(:evidence)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:task_id, :key])
  end

  @doc """
  Builds a changeset for the human's call on a finding.
  """
  def decision_changeset(qa_finding, decision) when decision in @recommendations do
    change(qa_finding, decision: decision)
  end

  @doc """
  True when this finding is one the engineer is being asked to fix.

  Only what a human ruled on: a finding nobody has decided yet is not something
  to send, it is something to decide.
  """
  def outstanding?(%__MODULE__{status: :fixed}), do: false
  def outstanding?(%__MODULE__{decision: :fix}), do: true
  def outstanding?(%__MODULE__{}), do: false

  @doc """
  True when this finding is still waiting on a human to rule on it.
  """
  def undecided?(%__MODULE__{status: :fixed}), do: false
  def undecided?(%__MODULE__{decision: nil}), do: true
  def undecided?(%__MODULE__{}), do: false

  @doc """
  True when this change is what broke it, rather than something it stands next to.
  """
  def regression?(%__MODULE__{caused_by_change: caused_by_change}), do: caused_by_change

  @doc """
  Where a finding sits right now, as the one word the panel groups by.
  """
  def state(%__MODULE__{status: :fixed}), do: :fixed
  def state(%__MODULE__{decision: :skip}), do: :dismissed
  def state(%__MODULE__{decision: nil}), do: :undecided
  def state(%__MODULE__{status: :not_fixed}), do: :not_fixed
  def state(%__MODULE__{}), do: :to_fix

  def severities, do: @severities
  def recommendations, do: @recommendations
  def statuses, do: @statuses

  def severity_label(:blocker), do: "Blocker"
  def severity_label(:major), do: "Major"
  def severity_label(:minor), do: "Minor"
  def severity_label(:nit), do: "Nit"
end
