defmodule Rail.Issues.Schemas.IssueStage do
  @moduledoc """
  One stage of an issue's sequence, as its workflow's file named it: Plan, Engineer, Review, or a custom stage with
  its own name and prompt.
  """
  use Rail.Schema

  @primary_key false
  embedded_schema do
    field :stage, Ecto.Enum, values: [:plan, :engineer, :review, :custom]
    field :name, :string
    field :prompt, :string
  end

  @doc """
  Builds a changeset for one stage. A custom stage needs its name and its prompt, and a built-in takes neither.
  """
  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:stage, :name, :prompt])
    |> update_change(:name, &String.trim/1)
    |> update_change(:prompt, &String.trim/1)
    |> validate_required([:stage])
    |> validate_custom()
  end

  defp validate_custom(changeset) do
    if get_field(changeset, :stage) == :custom,
      do: changeset |> validate_required([:name, :prompt]) |> validate_length(:name, max: 60),
      else: changeset |> put_change(:name, nil) |> put_change(:prompt, nil)
  end
end
