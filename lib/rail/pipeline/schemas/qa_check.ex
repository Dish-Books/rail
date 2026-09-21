defmodule Rail.Pipeline.Schemas.QaCheck do
  @moduledoc """
  One row of the checklist a QA pass wrote before it touched anything.

  A check is a thing to verify in the running application, named before the
  answer is known. That order is the whole point: a checklist written after the
  fact is a list of what happened to be noticed, and the question a reader has
  about a QA pass is never "what did it find" but "what did it look at".

  `group` is the heading a row sits under - the setup a pass had to do before it
  could check anything reads differently from the acceptance criteria, and a
  reader scanning forty rows wants them apart. QA chooses the headings, because
  what they should be depends on the change.

  `carried` marks a row this pass did not run: its outcome came from the pass
  before, kept because the change since could not have touched it. A reader
  seeing forty greens should be able to tell which of them were earned today.

  `outcome` starts `pending` and is set once, when the check has actually been
  run. A `fail` is expected to have a finding behind it, but nothing here
  enforces that - a check can fail for a reason too small to raise, and a
  checklist that quietly renamed itself to match the findings would be worth
  less than one that disagrees with them.
  """
  use Rail.Schema

  @outcomes [:pending, :pass, :fail, :skipped]

  @primary_key false
  embedded_schema do
    field :key, :string
    field :title, :string
    field :group, :string
    field :criterion, :string
    field :outcome, Ecto.Enum, values: @outcomes, default: :pending
    field :note, :string
    field :carried, :boolean, default: false
  end

  @key ~r/\A[a-z0-9][a-z0-9-]*\z/
  @cast_fields [:key, :title, :group, :criterion, :outcome, :note, :carried]
  @required_fields [:key, :title]

  @doc """
  Builds a changeset for one checklist row.
  """
  def changeset(qa_check, attrs) do
    qa_check
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_format(:key, @key)
    |> validate_length(:title, max: 200)
    |> validate_length(:group, max: 60)
  end

  def outcomes, do: @outcomes

  @doc """
  True once this check has been run, whatever it came to.
  """
  def run?(%__MODULE__{outcome: :pending}), do: false
  def run?(%__MODULE__{}), do: true

  def outcome_label(:pending), do: "Not yet run"
  def outcome_label(:pass), do: "Passed"
  def outcome_label(:fail), do: "Failed"
  def outcome_label(:skipped), do: "Skipped"
end
