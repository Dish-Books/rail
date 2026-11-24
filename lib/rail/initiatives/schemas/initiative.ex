defmodule Rail.Initiatives.Schemas.Initiative do
  @moduledoc "A project's named group of tickets across cycles, with notes and update briefs."
  use Rail.Schema

  alias Rail.Initiatives.Schemas.InitiativeComment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project

  @primary_key {:id, UXID, autogenerate: true, prefix: "ini"}
  schema "initiatives" do
    field :name, :string
    field :notes, :string, default: ""
    field :expected_on, :date
    # Set only by `list_initiatives/2` and `get_initiative/3`: Done tickets, and every ticket not Canceled.
    field :done_count, :integer, virtual: true, default: 0
    field :ticket_count, :integer, virtual: true, default: 0

    belongs_to :project, Project
    has_many :issues, Issue, preload_order: [asc: :number]
    has_many :comments, InitiativeComment, preload_order: [desc: :inserted_at, desc: :id]

    timestamps()
  end

  def changeset(initiative, attrs) do
    initiative
    |> cast(attrs, [:name, :expected_on])
    |> cast(attrs, [:notes], empty_values: [nil])
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, max: 200)
    |> unique_constraint(:name, name: :initiatives_project_id_name_index, message: "is already an initiative here")
  end

  @doc "Done tickets as a whole percent of the counted ones, rounded down; 0 with none counted."
  def calculate_percent(%__MODULE__{ticket_count: 0}), do: 0
  def calculate_percent(%__MODULE__{done_count: done, ticket_count: total}), do: div(done * 100, total)

  @doc "nil with no expected date, else `{:left, days}`, `:today` or `{:late, days}`."
  def calculate_due(%__MODULE__{expected_on: nil}, _today), do: nil

  def calculate_due(%__MODULE__{expected_on: %Date{} = on}, %Date{} = today) do
    case Date.diff(on, today) do
      0 -> :today
      days when days > 0 -> {:left, days}
      days -> {:late, -days}
    end
  end

  @doc ~s(The due date in words, such as "19 days left", "due today" or "1 day late"; nil with none.)
  def calculate_due_text(%__MODULE__{} = initiative, %Date{} = today) do
    case calculate_due(initiative, today) do
      :today -> "due today"
      {:left, 1} -> "1 day left"
      {:left, days} -> "#{days} days left"
      {:late, 1} -> "1 day late"
      {:late, days} -> "#{days} days late"
      nil -> nil
    end
  end
end
