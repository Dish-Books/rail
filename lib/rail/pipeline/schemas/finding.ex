defmodule Rail.Pipeline.Schemas.Finding do
  @moduledoc """
  One thing Review found wrong, in the code or on a screen, and what is being done about it.

  What a finding said when it was raised is never rewritten: its title, Problem, Where, Fix, Why, rule and
  places stay as raised, and every later pass, ruling and fix appends a dated note, in its round, to `notes`.
  The lead recommends and the human decides; `decision` is only ever written by a person.

  `key` is the lead's own stable name for the problem, which lets a later pass note the same row rather than
  raise it twice. `rule_id` is the checklist rule it came from; one a calibration rule says not to raise is
  kept, `suppressed_by` that rule, and sits apart until a person decides Fix anyway.
  """
  use Rail.Schema

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @kinds [:code, :screen]
  @raised_by [:code_reviewer, :explorer, :review_lead]
  @severities [:blocker, :major, :minor, :nit]
  @recommendations [:fix, :skip]
  @statuses [:open, :fixed, :not_fixed]
  @key ~r/\A[a-z0-9][a-z0-9-]*\z/
  # What a model's own tool calls look like when they leak into the text it writes.
  @markup ~r/<\/?(?:[\w-]+:)?(?:function_calls|invoke|parameter|tool_use|tool_result|tool_call)\b/i

  @primary_key {:id, UXID, autogenerate: true, prefix: "fnd"}
  schema "findings" do
    field :key, :string
    field :kind, Ecto.Enum, values: @kinds
    field :raised_by, Ecto.Enum, values: @raised_by
    field :round, :integer
    # The round a Fix finding a pass found still failing was carried into.
    field :carried_round, :integer
    field :title, :string
    field :problem, :string
    field :file, :string
    field :line, :integer
    field :end_line, :integer
    field :screen, :string
    field :steps, {:array, :string}, default: []
    # The QA checklist row a screen finding came out of.
    field :check, :string
    field :fix, :string
    field :why, :string
    field :rule, :string
    field :severity, Ecto.Enum, values: @severities
    field :recommendation, Ecto.Enum, values: @recommendations
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :decision, Ecto.Enum, values: @recommendations
    field :raised_in, :string
    field :fixed_in, :string

    embeds_many :places, FindingPlace, on_replace: :delete
    embeds_many :evidence, FindingEvidence, on_replace: :delete
    embeds_many :notes, FindingNote, on_replace: :delete

    belongs_to :task, Task
    belongs_to :checklist_rule, Learning, foreign_key: :rule_id

    belongs_to :suppressed_by, Learning
    belongs_to :decided_by, User

    timestamps()
  end

  # What the lead says when it raises a finding; the round, the commit and the links are Rail's.
  @raised [
    :key,
    :kind,
    :raised_by,
    :title,
    :problem,
    :file,
    :line,
    :end_line,
    :screen,
    :steps,
    :check,
    :fix,
    :why,
    :rule,
    :severity,
    :recommendation
  ]

  @required [:key, :kind, :raised_by, :title, :problem, :fix, :why, :rule, :severity, :recommendation]
  @texts [:title, :problem, :fix, :why, :rule, :screen, :steps]

  @doc """
  Builds a changeset for a finding as the lead raises it: evidence, a Where, a place, the rule and Why are
  required, every field is held to its limit, and nothing it says may hold tool-call markup.
  """
  def raise_changeset(finding, attrs) do
    finding
    |> cast(attrs, @raised)
    |> cast_embed(:places, with: &FindingPlace.changeset/2)
    |> cast_embed(:evidence, with: &FindingEvidence.changeset/2)
    |> validate_required(@required)
    |> validate_format(:key, @key, message: "must be lowercase letters, digits and hyphens")
    |> validate_length(:key, max: 60)
    |> validate_length(:title, max: 90)
    |> validate_length(:problem, max: 300)
    |> validate_length(:fix, max: 300)
    |> validate_length(:why, max: 200)
    |> validate_length(:rule, max: 160)
    |> validate_length(:screen, max: 160)
    |> validate_number(:line, greater_than: 0, message: "must be a positive whole number")
    |> validate_number(:end_line, greater_than: 0, message: "must be a positive whole number")
    |> validate_where()
    |> validate_some(:places, "needs every place the rule applies, at least one")
    |> validate_some(:evidence, "needs at least one highlighted code range, screenshot, file or note")
    |> validate_no_markup(@texts)
    |> foreign_key_constraint(:task_id)
    |> unique_constraint([:task_id, :key])
  end

  @doc """
  Appends `attrs[:note]` to the history, with any new `:evidence`, and moves `:status`, `:carried_round` and
  `:fixed_in`. Takes a finding or a changeset already ruling on one.
  """
  def note_changeset(finding_or_changeset, attrs) do
    changeset = cast(change(finding_or_changeset), attrs, [:status, :carried_round, :fixed_in])
    note = FindingNote.changeset(%FindingNote{}, Map.fetch!(attrs, :note))
    added = for evidence <- Map.get(attrs, :evidence, []), do: FindingEvidence.changeset(%FindingEvidence{}, evidence)

    changeset
    |> put_embed(:notes, List.insert_at(get_field(changeset, :notes), -1, note))
    |> put_embed(:evidence, get_field(changeset, :evidence) ++ added)
    |> validate_note(note)
  end

  @doc """
  Builds a changeset for the human's call on a finding, and who made it.
  """
  def decision_changeset(finding, decision, decided_by_id) when decision in @recommendations do
    change(finding, decision: decision, decided_by_id: decided_by_id)
  end

  @doc "True when `text` holds what a model's tool call looks like."
  def markup?(text) when is_binary(text), do: Regex.match?(@markup, text)
  def markup?(_not_text), do: false

  @doc """
  True when a calibration rule suppressed this finding and nobody has decided to fix it anyway.
  """
  def suppressed?(%__MODULE__{status: :fixed}), do: false
  def suppressed?(%__MODULE__{suppressed_by_id: rule_id, decision: nil}), do: is_binary(rule_id)
  def suppressed?(%__MODULE__{}), do: false

  @doc """
  True when this finding is one the next fix round fixes: ruled Fix and not fixed, which includes one a
  pass found still failing, since it keeps its ruling.
  """
  def outstanding?(%__MODULE__{status: :fixed}), do: false
  def outstanding?(%__MODULE__{decision: :fix}), do: true
  def outstanding?(%__MODULE__{}), do: false

  @doc """
  True when this finding is still waiting on a human to rule on it. A suppressed one is not: the rule has
  ruled, and it never holds up a fix round.
  """
  def undecided?(%__MODULE__{status: :fixed}), do: false
  def undecided?(%__MODULE__{decision: nil} = finding), do: not suppressed?(finding)
  def undecided?(%__MODULE__{}), do: false

  @doc """
  Where a finding sits right now, as the one word the list groups and colors by.
  """
  def state(%__MODULE__{status: :fixed}), do: :fixed
  def state(%__MODULE__{decision: :skip}), do: :dismissed
  def state(%__MODULE__{decision: nil, suppressed_by_id: rule_id}) when is_binary(rule_id), do: :suppressed
  def state(%__MODULE__{decision: nil}), do: :undecided
  def state(%__MODULE__{status: :not_fixed}), do: :not_fixed
  def state(%__MODULE__{}), do: :to_fix

  @doc "Where a finding is, as one line: its code range, or its screen."
  def where(%__MODULE__{file: file} = finding) when is_binary(file),
    do: FindingPlace.describe(%FindingPlace{file: file, line: finding.line, end_line: finding.end_line})

  def where(%__MODULE__{screen: screen}), do: screen

  def severities, do: @severities
  def kinds, do: @kinds
  def raised_by, do: @raised_by

  def severity_label(:blocker), do: "Blocker"
  def severity_label(:major), do: "Major"
  def severity_label(:minor), do: "Minor"
  def severity_label(:nit), do: "Nit"

  # A code finding is read off its range, and a screen finding is reproduced from its steps.
  defp validate_where(changeset) do
    case get_field(changeset, :kind) do
      :code ->
        if get_field(changeset, :file) && get_field(changeset, :line),
          do: changeset,
          else: add_error(changeset, :file, "a code finding's Where is the `file` and `line` it is in")

      :screen ->
        if get_field(changeset, :screen) && get_field(changeset, :steps) != [],
          do: changeset,
          else: add_error(changeset, :screen, "a screen finding's Where is the `screen` and the `steps` to it")

      nil ->
        changeset
    end
  end

  defp validate_some(changeset, field, message) do
    if get_field(changeset, field) == [], do: add_error(changeset, field, message), else: changeset
  end

  defp validate_no_markup(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        if value |> List.wrap() |> Enum.any?(&markup?/1),
          do: [{field, "holds tool-call markup; write it as plain text"}],
          else: []
      end)
    end)
  end

  # Said here rather than inside the history, so a refusal names the `note` the agent wrote.
  defp validate_note(changeset, %Ecto.Changeset{} = note) do
    text = get_field(note, :text)

    cond do
      markup?(text) -> add_error(changeset, :note, "holds tool-call markup; write it as plain text")
      is_binary(text) and String.length(text) > 300 -> add_error(changeset, :note, "should be at most 300 character(s)")
      true -> changeset
    end
  end
end
