defmodule Rail.Projects.Schemas.EnvFile do
  @moduledoc """
  A project's `.env` as the variables it sets, in order. There is no table behind this: the file in the
  clone is the copy, read when the editor opens and written back whole on save.
  """
  use Rail.Schema

  @primary_key false
  embedded_schema do
    # The id keys each row's inputs, so a shown value stays with its variable when a row above goes.
    embeds_many :variables, Variable, on_replace: :delete do
      field :name, :string
      field :value, :string, default: ""
    end
  end

  @doc """
  Casts the rows, added and removed through the form's sort and drop params, refusing a name that is
  blank, is no variable name or repeats one above it.
  """
  def changeset(env_file, attrs) do
    env_file
    |> cast(attrs, [])
    |> cast_embed(:variables,
      with: &variable_changeset/2,
      sort_param: :variables_sort,
      drop_param: :variables_drop
    )
    |> validate_distinct_names()
  end

  @doc """
  The variables `text` sets, one per `NAME=value` line with any `export ` dropped. Every other line is left out.
  """
  def from_text(text) when is_binary(text) do
    variables =
      for line <- String.split(text, ~r/\r?\n/),
          [_line, name, value] <- [Regex.run(~r/^\s*(?:export\s+)?([A-Za-z_]\w*)\s*=(.*)$/, line)],
          do: %__MODULE__.Variable{id: Ecto.UUID.generate(), name: name, value: value}

    %__MODULE__{variables: variables}
  end

  @doc """
  The file `env_file` is written as, one `NAME=value` line per variable.
  """
  def to_text(%__MODULE__{variables: variables}), do: Enum.map_join(variables, &"#{&1.name}=#{&1.value}\n")

  # A row added in the form has no id until it is cast, and keeps the one it is given from then on.
  defp variable_changeset(variable, attrs) do
    variable
    |> cast(attrs, [:id, :name])
    |> cast(attrs, [:value], empty_values: [nil])
    |> then(&if get_field(&1, :id), do: &1, else: put_change(&1, :id, Ecto.UUID.generate()))
    |> validate_required([:name])
    |> validate_format(:name, ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/,
      message: "Use letters, digits and _, not starting with a digit"
    )
  end

  # put_embed recomputes the parent's valid?, so a repeated name refuses the save.
  defp validate_distinct_names(changeset) do
    {rows, _seen} =
      changeset
      |> get_embed(:variables, :changeset)
      |> Enum.reject(&(&1.action == :replace))
      |> Enum.map_reduce(MapSet.new(), &mark_repeated_name/2)

    put_embed(changeset, :variables, rows)
  end

  defp mark_repeated_name(row, seen) do
    name = get_field(row, :name)

    if is_binary(name) and MapSet.member?(seen, name),
      do: {add_error(row, :name, "#{name} is already set above"), seen},
      else: {row, MapSet.put(seen, name)}
  end
end
