defmodule Rail.Learnings.Utils.EnqueuePullRequests do
  @moduledoc """
  Queues pull requests to have their review comments read, skipping any already
  read. Extraction, the curator's window and the backfill all queue through here.
  """

  import Ecto.Query

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Learnings.Schemas.ProcessedPullRequest
  alias Rail.Learnings.Workers.CollectPullRequest
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @page_size 100

  @doc """
  Queues one PR by number, or every PR merged since a time, or ever when it is
  nil. Returns `{:ok, numbers}`, those it queued.
  """
  def enqueue_pull_requests(%Project{} = project, number) when is_integer(number), do: enqueue(project, [number])

  def enqueue_pull_requests(%Project{} = project, since) when is_nil(since) or is_struct(since, DateTime) do
    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, numbers} <- merged(token, project, since, 1, []) do
      enqueue(project, numbers)
    end
  end

  # Newest-updated first, so a page whose last PR was updated before `since` is the last one worth reading.
  defp merged(token, %Project{} = project, since, page, acc) do
    params = [state: "closed", sort: "updated", direction: "desc", per_page: @page_size, page: page]

    with {:ok, pull_requests} <- GitHub.list_pull_requests(token, project.github_repo, params) do
      numbers = for %{"number" => number, "merged_at" => merged_at} <- pull_requests, after?(merged_at, since), do: number
      last = List.last(pull_requests)

      if length(pull_requests) == @page_size and after?(last["updated_at"], since),
        do: merged(token, project, since, page + 1, acc ++ numbers),
        else: {:ok, acc ++ numbers}
    end
  end

  defp after?(nil, _since), do: false
  defp after?(_at, nil), do: true

  defp after?(at, since) do
    {:ok, at, _offset} = DateTime.from_iso8601(at)
    DateTime.compare(at, since) != :lt
  end

  defp enqueue(%Project{id: project_id}, numbers) do
    numbers = Enum.uniq(numbers)

    read =
      Repo.all(
        from p in ProcessedPullRequest, where: p.project_id == ^project_id and p.number in ^numbers, select: p.number
      )

    queued = numbers -- read
    Enum.each(queued, &(%{project_id: project_id, number: &1} |> CollectPullRequest.new() |> Oban.insert!()))
    {:ok, queued}
  end
end
