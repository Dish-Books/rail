defmodule Rail.Pipeline.Schemas.QaChecklist do
  @moduledoc """
  What a QA pass said it would check, as it stands on disk. There is no table
  behind this.

  It is written once, before the browser is opened, and each row is marked as the
  pass reaches it. That gives the human watching something better than a spinner:
  the shape of the pass is visible from the first minute, and a pass that stops
  half way says which rows it never got to rather than leaving them to be guessed
  at.

  Like the verdict, it belongs to one pass. The next pass replaces all of it, and
  it goes with the scratch directory when the task is cleaned up. The findings are
  what survives, and they name the check they came out of.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.QaCheck

  @primary_key false
  embedded_schema do
    embeds_many :checks, QaCheck
  end

  @doc """
  Builds a checklist from what was handed in, refusing one that checks nothing.
  """
  def changeset(qa_checklist, attrs) do
    qa_checklist
    |> cast(attrs, [])
    |> cast_embed(:checks)
    |> validate_listed()
    |> validate_distinct()
  end

  @doc """
  How far through the pass is: how many rows have been run, out of how many.
  """
  def progress(%__MODULE__{checks: checks}), do: {Enum.count(checks, &QaCheck.run?/1), length(checks)}

  # A checklist with no rows is a pass that planned nothing, and the panel would
  # show an empty box nobody could explain.
  defp validate_listed(changeset) do
    case get_field(changeset, :checks) do
      [] -> add_error(changeset, :checks, "a checklist needs at least one check")
      _listed -> changeset
    end
  end

  # The key is how a row is marked off later, so two rows sharing one would make
  # the second unreachable.
  defp validate_distinct(changeset) do
    keys = changeset |> get_field(:checks) |> Enum.map(& &1.key)

    if length(Enum.uniq(keys)) == length(keys) do
      changeset
    else
      add_error(changeset, :checks, "every check needs its own key")
    end
  end
end
