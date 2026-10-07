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
  A comment as GitHub's REST API and webhooks send it.
  """
  def github_comment_json(overrides \\ %{}) do
    Map.merge(
      %{
        "node_id" => "IC_kw#{System.unique_integer([:positive])}",
        "body" => "A comment",
        "user" => %{"id" => 9001, "login" => "octocat", "avatar_url" => "https://avatars.example/octocat"},
        "issue_url" => "https://api.github.com/repos/example/test-gh/issues/42",
        "created_at" => "2026-10-06T12:00:00Z",
        "updated_at" => "2026-10-06T12:00:00Z"
      },
      overrides
    )
  end

  @doc """
  A GitHub issue saved in `project` the way a sync saves one, so nothing is pushed back.
  """
  def github_issue(%Project{} = project, attrs \\ %{}) do
    number = attrs[:number] || System.unique_integer([:positive])

    %Issue{}
    |> Issue.tracker_changeset(
      Map.merge(
        %{
          project_id: project.id,
          tracker: :github,
          external_id: "I_kw#{System.unique_integer([:positive])}",
          number: number,
          identifier: "#{project.key}##{number}",
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
