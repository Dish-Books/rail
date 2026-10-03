defmodule Rail.Learnings.Workers.CollectPullRequest do
  @moduledoc """
  Reads one PR's human review comments into observations and records it read, in one transaction. Unique while incomplete,
  so a PR queued twice is fetched once; a failed fetch writes nothing and is retried.
  """
  use Oban.Worker,
    queue: :learnings_embed,
    max_attempts: 5,
    unique: [keys: [:project_id, :number], states: :incomplete]

  import Ecto.Query
  import Rail.Learnings.Utils.InsertObservations

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings.Schemas.ProcessedPullRequest
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id, "number" => number}}) do
    with false <- Repo.exists?(from p in ProcessedPullRequest, where: p.project_id == ^project_id and p.number == ^number),
         %Project{} = project <- Repo.get(Project, project_id) do
      collect(project, number)
    else
      _read_or_gone -> :ok
    end
  end

  defp collect(%Project{} = project, number) do
    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, comments} <- GitHub.list_review_comments(token, project.github_repo, number),
         {:ok, reviews} <- GitHub.list_reviews(token, project.github_repo, number) do
      task =
        Repo.one(
          from t in Task,
            where: t.project_id == ^project.id and t.pr_number == ^number,
            order_by: [desc: t.inserted_at],
            limit: 1,
            preload: :issue
        )

      sightings =
        Enum.map(people(comments), &comment(&1, :pr_review_comment)) ++
          Enum.map(people(reviews), &comment(&1, :pr_review))

      users = users_by_login(sightings)

      {:ok, _inserted} =
        Repo.transaction(fn ->
          insert_observations(
            project.id,
            Enum.map(
              sightings,
              &Map.merge(&1, %{task_id: task && task.id, abandoned: abandoned?(task), actor_id: users[&1.actor_name]})
            )
          )

          Repo.insert!(%ProcessedPullRequest{project_id: project.id, number: number},
            on_conflict: :nothing,
            conflict_target: [:project_id, :number]
          )
        end)

      :ok
    end
  end

  # A bot's comment, or a review approved with nothing said, is nobody's correction.
  defp people(items) do
    Enum.filter(items, fn item ->
      get_in(item, ["user", "type"]) != "Bot" and is_binary(item["body"]) and String.trim(item["body"]) != ""
    end)
  end

  defp comment(item, kind) do
    %{
      source_kind: kind,
      source_id: to_string(item["id"]),
      source_url: item["html_url"],
      actor_name: get_in(item, ["user", "login"]),
      text: item["body"],
      excerpt: excerpt(item)
    }
  end

  defp excerpt(%{"path" => path, "diff_hunk" => hunk}) when is_binary(path), do: "#{path}\n#{hunk}"
  defp excerpt(_review), do: nil

  defp abandoned?(%Task{issue: %Issue{state: state}}), do: state in [:canceled, :duplicate]
  defp abandoned?(nil), do: false

  defp users_by_login(sightings) do
    logins = sightings |> Enum.map(& &1.actor_name) |> Enum.uniq()
    from(u in User, where: u.login in ^logins, select: {u.login, u.id}) |> Repo.all() |> Map.new()
  end
end
