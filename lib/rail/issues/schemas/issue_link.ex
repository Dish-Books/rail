defmodule Rail.Issues.Schemas.IssueLink do
  @moduledoc "A URL Rail linked to a Rail-tracked issue under a title, such as the Slack thread triage filed it from."
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue

  @primary_key {:id, UXID, autogenerate: true, prefix: "ilk"}
  schema "issue_links" do
    field :url, :string
    field :title, :string

    belongs_to :issue, Issue

    timestamps()
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:url, :title])
    |> validate_required([:issue_id, :url, :title])
    |> unique_constraint([:issue_id, :url])
  end
end
