defmodule Rail.Issues.Schemas.IssueRelation do
  @moduledoc "One Rail-tracked issue blocking another in the same project. A pair holds one relation, either way round."
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project

  @primary_key {:id, UXID, autogenerate: true, prefix: "irl"}
  schema "issue_relations" do
    belongs_to :project, Project
    belongs_to :blocker_issue, Issue
    belongs_to :blocked_issue, Issue

    timestamps()
  end

  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [:blocker_issue_id, :blocked_issue_id])
    |> validate_required([:project_id, :blocker_issue_id, :blocked_issue_id])
    |> check_constraint(:blocked_issue_id, name: :issue_relations_distinct, message: "can't be the blocking issue")
    |> foreign_key_constraint(:blocker_issue_id)
    |> foreign_key_constraint(:blocked_issue_id)
  end
end
