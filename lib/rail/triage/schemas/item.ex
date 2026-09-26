defmodule Rail.Triage.Schemas.Item do
  @moduledoc """
  One bug or feature request a thread raised: the verdict a pass reached on it,
  the evidence and assumptions behind that, and the issue and reply it proposes.
  Nothing it proposes reaches Linear or Slack until a person accepts it.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  @kinds [:bug, :feature_request]
  @verdicts %{bug: [:confirmed, :not_reproduced, :already_fixed], feature_request: [:built, :partly_built, :not_built]}
  @all_verdicts [:confirmed, :not_reproduced, :already_fixed, :built, :partly_built, :not_built]

  @primary_key {:id, UXID, autogenerate: true, prefix: "tit"}
  schema "triage_items" do
    field :key, :string
    field :position, :integer
    field :kind, Ecto.Enum, values: @kinds
    field :title, :string
    field :verdict, Ecto.Enum, values: @all_verdicts
    field :previous_verdict, Ecto.Enum, values: @all_verdicts
    field :summary, :string
    field :issue_note, :string
    field :issue_title, :string
    field :issue_description, :string
    field :issue_priority, Ecto.Enum, values: Issue.priorities()
    field :reply_text, :string
    field :reply_posted_at, :utc_datetime_usec
    field :retriaging, :boolean, default: false
    field :retriaged_at, :utc_datetime_usec
    field :error, :string

    embeds_many :evidence, Evidence, on_replace: :delete, primary_key: false do
      field :file, :string
      field :lines, :string
      field :excerpt, :string
      # Whether the code bears the claim out.
      field :holds, :boolean, default: true
    end

    embeds_many :assumptions, Assumption, on_replace: :delete, primary_key: false do
      field :text, :string
      field :corrected, :boolean, default: false
    end

    belongs_to :thread, Thread
    belongs_to :existing_issue, Issue
    belongs_to :created_issue, Issue
    belongs_to :issue_edited_by, User
    belongs_to :reply_edited_by, User
    belongs_to :issue_created_by, User
    belongs_to :reply_posted_by, User

    timestamps()
  end

  @triaged [
    :key,
    :position,
    :kind,
    :title,
    :verdict,
    :previous_verdict,
    :summary,
    :existing_issue_id,
    :issue_note,
    :issue_title,
    :issue_description,
    :issue_priority,
    :reply_text,
    :issue_edited_by_id,
    :reply_edited_by_id,
    :retriaging,
    :retriaged_at,
    :error
  ]

  @doc """
  What a triage pass wrote about the item.
  """
  def triage_changeset(item, attrs) do
    item
    |> cast(attrs, @triaged)
    |> cast_embed(:evidence, with: &evidence_changeset/2)
    |> cast_embed(:assumptions, with: &assumption_changeset/2)
    |> validate_required([:key, :position, :kind, :title, :verdict])
    |> validate_verdict()
    |> unique_constraint([:thread_id, :key])
  end

  @doc """
  A person's edit to the drafts, marking whichever draft changed as theirs.
  """
  def draft_changeset(item, attrs, user_id) do
    changeset = cast(item, attrs, [:issue_title, :issue_description, :issue_priority, :reply_text])

    changeset
    |> then(&if(issue_changed?(&1), do: put_change(&1, :issue_edited_by_id, user_id), else: &1))
    |> then(&if(changed?(&1, :reply_text), do: put_change(&1, :reply_edited_by_id, user_id), else: &1))
  end

  def issue_draft?(%__MODULE__{issue_title: title, existing_issue_id: nil}), do: is_binary(title) and title != ""
  def issue_draft?(%__MODULE__{}), do: false

  def reply_draft?(%__MODULE__{reply_text: text}), do: is_binary(text) and String.trim(text) != ""

  @doc """
  Whether nothing is left to accept: every proposal was, or the thread was dismissed.
  """
  def settled?(%__MODULE__{thread: %Thread{dismissed_at: %DateTime{}}}), do: true
  def settled?(%__MODULE__{} = item), do: pending_proposals(item) == 0

  def pending_proposals(%__MODULE__{} = item) do
    Enum.count(
      [
        issue_draft?(item) and is_nil(item.created_issue_id),
        reply_draft?(item) and is_nil(item.reply_posted_at)
      ],
      & &1
    )
  end

  def kinds, do: @kinds
  def verdicts(kind), do: Map.fetch!(@verdicts, kind)

  def verdict_label(:confirmed), do: "Confirmed"
  def verdict_label(:not_reproduced), do: "Could not reproduce"
  def verdict_label(:already_fixed), do: "Already fixed"
  def verdict_label(:built), do: "Built"
  def verdict_label(:partly_built), do: "Partly built"
  def verdict_label(:not_built), do: "Not built"

  def kind_label(:bug), do: "Bug"
  def kind_label(:feature_request), do: "Feature request"

  defp issue_changed?(changeset) do
    changed?(changeset, :issue_title) or changed?(changeset, :issue_description) or changed?(changeset, :issue_priority)
  end

  defp validate_verdict(changeset) do
    kind = get_field(changeset, :kind)

    validate_change(changeset, :verdict, fn :verdict, verdict ->
      if kind in @kinds and verdict not in Map.fetch!(@verdicts, kind),
        do: [verdict: "does not fit a #{String.downcase(kind_label(kind))}"],
        else: []
    end)
  end

  defp evidence_changeset(evidence, attrs), do: cast(evidence, attrs, [:file, :lines, :excerpt, :holds])
  defp assumption_changeset(assumption, attrs), do: cast(assumption, attrs, [:text, :corrected])
end
