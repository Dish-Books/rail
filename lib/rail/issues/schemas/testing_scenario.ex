defmodule Rail.Issues.Schemas.TestingScenario do
  @moduledoc """
  One thing to check on a ticket in testing, written by the agent from the merged change or added by a tester.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.TestingImage

  @results [:passed, :failed]

  # A plain id: with an embedded primary key, Ecto drops a `put_embed` whose entries only changed.
  @primary_key false
  embedded_schema do
    field :id, :string
    field :title, :string
    field :source, Ecto.Enum, values: [:agent, :tester]
    field :result, Ecto.Enum, values: @results
    field :note, :string
    embeds_many :images, TestingImage, on_replace: :delete
  end

  @doc "A scenario the agent wrote, unmarked."
  def agent(title) when is_binary(title),
    do: %__MODULE__{id: UXID.generate!(prefix: "tsc"), title: String.slice(title, 0, 500), source: :agent}

  @doc "A scenario a tester adds, refusing a blank or overlong one."
  def tester_changeset(attrs) do
    %__MODULE__{id: UXID.generate!(prefix: "tsc"), source: :tester}
    |> cast(attrs, [:title])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 500)
  end

  @doc "A tester's result or note on an existing scenario."
  def result_changeset(%__MODULE__{} = scenario, attrs) do
    scenario
    |> cast(attrs, [:result, :note], empty_values: [])
    |> validate_length(:note, max: 10_000)
  end

  def results, do: @results

  def result_label(:passed), do: "Passed"
  def result_label(:failed), do: "Failed"
  def result_label(nil), do: "Not marked"
end
