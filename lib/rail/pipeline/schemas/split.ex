defmodule Rail.Pipeline.Schemas.Split do
  @moduledoc """
  A split the architect saved while Plan is open, as it stands on disk. There is no table behind this:
  approval turns each child into an issue and a task of its own.
  """
  use Rail.Schema

  @heading ~r/\A## Implementation plan\s*(\n|\z)/

  @primary_key false
  embedded_schema do
    embeds_many :children, Child, primary_key: false do
      field :title, :string
      field :ticket, :string
      field :estimate, :integer
      field :plan, :string
      field :builds_on, {:array, :integer}, default: []
    end
  end

  @doc """
  Builds a split from what the architect handed in, refusing one with a single child or any child
  short of its title, ticket or part of the plan.
  """
  def changeset(split, attrs) do
    split
    |> cast(attrs, [])
    |> cast_embed(:children,
      with: &child_changeset/3,
      required: true,
      required_message: "a split needs at least two children"
    )
    |> validate_length(:children, min: 2, message: "a split needs at least two children")
  end

  defp child_changeset(child, attrs, index) do
    child
    |> cast(attrs, [:title, :ticket, :estimate, :plan, :builds_on])
    |> update_change(:title, &String.trim/1)
    |> update_change(:ticket, &String.trim/1)
    |> update_change(:plan, &String.trim/1)
    |> validate_required([:title, :ticket, :plan])
    |> validate_format(:title, ~r/\A[^\n]*\z/, message: "must be one line")
    |> validate_number(:estimate, greater_than_or_equal_to: 0, message: "must be zero or more")
    |> validate_format(:plan, @heading, message: "must open with the `## Implementation plan` heading")
    |> validate_change(:builds_on, fn :builds_on, builds_on ->
      # Positions count from 1, and a child builds only on the ones before it.
      if Enum.all?(builds_on, &(&1 in 1..index//1)),
        do: [],
        else: [builds_on: "must name only earlier children, numbered from 1"]
    end)
  end
end
