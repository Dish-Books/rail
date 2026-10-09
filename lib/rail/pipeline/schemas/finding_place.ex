defmodule Rail.Pipeline.Schemas.FindingPlace do
  @moduledoc """
  One place a finding's rule applies: a code range with a short label, or a screen with its steps.
  A fix that leaves it says why in `left_reason`, which only the fix round writes.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Finding

  @primary_key false
  embedded_schema do
    field :file, :string
    field :line, :integer
    field :end_line, :integer
    field :label, :string
    field :screen, :string
    field :steps, {:array, :string}, default: []
    field :left_reason, :string
  end

  @doc """
  Builds a changeset for one place as the agent named it.
  """
  def changeset(place, attrs) do
    place
    |> cast(attrs, [:file, :line, :end_line, :label, :screen, :steps])
    |> validate_length(:label, max: 80)
    |> validate_length(:screen, max: 160)
    |> validate_number(:line, greater_than: 0, message: "must be a positive whole number")
    |> validate_number(:end_line, greater_than: 0, message: "must be a positive whole number")
    |> validate_change(:file, fn :file, file ->
      if relative?(file), do: [], else: [file: "is a path relative to the worktree, never climbing out with `..`"]
    end)
    |> validate_located()
    |> validate_plain([:label, :screen, :steps])
  end

  @doc """
  Records why a fix round left this place as it was.
  """
  def leave_changeset(place, reason) when is_binary(reason), do: change(place, left_reason: String.trim(reason))

  @doc """
  The place as one line a reader recognizes it by.
  """
  def describe(%__MODULE__{file: file, line: line, end_line: end_line}) when is_binary(file) do
    cond do
      is_integer(line) and is_integer(end_line) and end_line > line -> "#{file}:#{line}-#{end_line}"
      is_integer(line) -> "#{file}:#{line}"
      true -> file
    end
  end

  def describe(%__MODULE__{screen: screen}), do: screen

  defp relative?(file), do: Path.type(file) == :relative and ".." not in Path.split(file)

  defp validate_plain(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn ^field, value ->
        if value |> List.wrap() |> Enum.any?(&Finding.markup?/1), do: [{field, "holds tool-call markup"}], else: []
      end)
    end)
  end

  defp validate_located(changeset) do
    if get_field(changeset, :file) || get_field(changeset, :screen),
      do: changeset,
      else: add_error(changeset, :file, "a place is a `file` with its lines or a `screen` with its steps")
  end
end
