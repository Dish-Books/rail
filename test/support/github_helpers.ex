defmodule RailTest.GithubHelpers do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  An issue as GitHub's REST API and webhooks send it, open with no labels unless `overrides` say otherwise.
  """
  def github_issue_json(overrides \\ %{}) do
    number = overrides["number"] || 42

    Map.merge(
      %{
        "node_id" => "I_kw#{System.unique_integer([:positive])}",
        "number" => number,
        "title" => "Short title",
        "body" => "More details here",
        "state" => "open",
        "state_reason" => nil,
        "labels" => [],
        "assignees" => [],
        "html_url" => "https://github.com/example/test-gh/issues/#{number}",
        "closed_at" => nil,
        "created_at" => "2026-10-06T12:00:00Z",
        "updated_at" => "2026-10-06T12:00:00.123456Z"
      },
      overrides
    )
  end

  @doc """
  An issue saved in `project` with `attrs`, as a fixture, so nothing is announced.
  """
  def github_issue(%Project{} = project, attrs \\ %{}) do
    number = attrs[:number] || System.unique_integer([:positive])

    %Issue{}
    |> Issue.tracker_changeset(
      Map.merge(
        %{
          project_id: project.id,
          number: number,
          identifier: "#{project.key}-#{number}",
          title: "A GitHub issue",
          state: :backlog
        },
        attrs
      )
    )
    |> Repo.insert!()
    |> Repo.preload(:project)
  end
end
