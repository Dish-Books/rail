defmodule Rail.Issues.Actions.LinkPullRequest do
  @moduledoc """
  Links an issue to the open pull request its work was started on outside Rail: the one from the issue's own branch,
  or else one whose branch or title names the issue, as Linear links them. A linked one that has since closed is
  let go and looked for again.
  """

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  # Open pull requests come newest first, and one started for an issue still open is rarely older than these.
  @per_page 100

  @doc """
  Checks GitHub for `issue`'s open pull request and saves the link, or clears it when there is none. Returns
  `{:ok, pull_request}` with GitHub's pull request or nil, or `{:error, reason}`: `:not_found` for an issue the scope
  cannot see, or what GitHub refused.
  """
  def link_pull_request(%Scope{} = scope, %Issue{} = issue) do
    %Issue{project: %Project{} = project} = issue = Repo.preload(issue, :project)

    with true <- Scope.can_access_project?(scope, issue.project_id) || {:error, :not_found},
         {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, pull_request} <- open(token, project, issue) do
      attrs =
        if pull_request,
          do: %{pr_number: pull_request["number"], pr_url: pull_request["html_url"], pr_title: pull_request["title"]},
          else: %{pr_number: nil, pr_url: nil, pr_title: nil}

      {:ok, _linked} = issue |> Issue.pull_request_changeset(attrs) |> Repo.update()
      {:ok, pull_request}
    end
  end

  defp open(token, %Project{} = project, %Issue{pr_number: number} = issue) when is_integer(number) do
    case GitHub.get_pull_request(token, project.github_repo, number) do
      {:ok, %{"state" => "open"} = pull_request} -> {:ok, pull_request}
      {:ok, _closed} -> search(token, project, issue)
      {:error, reason} -> {:error, reason}
    end
  end

  defp open(token, %Project{} = project, %Issue{} = issue), do: search(token, project, issue)

  defp search(token, %Project{} = project, %Issue{} = issue) do
    with {:ok, open} <- GitHub.list_pull_requests(token, project.github_repo, state: "open", per_page: @per_page) do
      # Linear's `eng-301-title` and Rail's GitHub `key-12-title` both start with the identifier, `#` read as `-`.
      named = ~r/(?<![a-z0-9])#{Regex.escape(String.replace(issue.identifier, "#", "-"))}(?![0-9])/i

      {:ok,
       Enum.find(open, &(&1["head"]["ref"] == issue.branch_name)) ||
         Enum.find(open, &(&1["head"]["ref"] =~ named or (&1["title"] || "") =~ named))}
    end
  end
end
