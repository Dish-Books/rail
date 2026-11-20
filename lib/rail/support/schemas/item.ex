defmodule Rail.Support.Schemas.Item do
  @moduledoc """
  One bug or feature request a conversation raised: the agent's verdict, the ticket it
  drafts, and whether it was already forwarded.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue
  alias Rail.Support.Schemas.Conversation
  alias Rail.Triage.Schemas.Item, as: TriageItem

  @primary_key {:id, UXID, autogenerate: true, prefix: "sit"}
  schema "support_items" do
    field :key, :string
    field :position, :integer
    field :kind, Ecto.Enum, values: TriageItem.kinds()
    field :title, :string
    field :verdict, Ecto.Enum, values: [:confirmed, :not_reproduced, :already_fixed, :built, :partly_built, :not_built]
    field :summary, :string
    field :issue_title, :string
    field :issue_description, :string
    field :issue_priority, Ecto.Enum, values: Issue.priorities()
    field :issue_estimate, :integer
    field :forwarded_at, :utc_datetime_usec

    embeds_many :evidence, Evidence, on_replace: :delete, primary_key: false do
      field :file, :string
      field :lines, :string
      field :excerpt, :string
      field :holds, :boolean, default: true
    end

    embeds_many :assumptions, Assumption, on_replace: :delete, primary_key: false do
      field :text, :string
      field :corrected, :boolean, default: false
    end

    belongs_to :conversation, Conversation
    belongs_to :existing_issue, Issue

    timestamps()
  end

  @agent_fields [
    :key,
    :position,
    :kind,
    :title,
    :verdict,
    :summary,
    :existing_issue_id,
    :issue_title,
    :issue_description,
    :issue_priority,
    :issue_estimate
  ]

  @doc """
  What a pass wrote about the item. Every item names the ticket that tracks it or drafts one.
  """
  def agent_changeset(item, attrs) do
    item
    |> cast(attrs, @agent_fields)
    |> cast_embed(:evidence, with: &cast(&1, &2, [:file, :lines, :excerpt, :holds]))
    |> cast_embed(:assumptions, with: &cast(&1, &2, [:text, :corrected]))
    |> validate_required([:key, :position, :kind, :title, :verdict])
    |> then(&if(get_field(&1, :existing_issue_id), do: &1, else: validate_required(&1, [:issue_title])))
    |> validate_inclusion(:issue_estimate, TriageItem.estimates())
    |> validate_verdict()
    |> unique_constraint([:conversation_id, :key])
  end

  def forwardable?(%__MODULE__{existing_issue_id: nil, forwarded_at: nil, issue_title: title}),
    do: is_binary(title) and String.trim(title) != ""

  def forwardable?(%__MODULE__{}), do: false

  def tracked?(%__MODULE__{existing_issue_id: id}), do: is_binary(id)

  defp validate_verdict(changeset) do
    kind = get_field(changeset, :kind)

    validate_change(changeset, :verdict, fn :verdict, verdict ->
      if kind in TriageItem.kinds() and verdict not in TriageItem.verdicts(kind),
        do: [verdict: "does not fit the kind"],
        else: []
    end)
  end
end
