defmodule Rail.Pipeline.Actions.HandleCoderabbitCheck do
  @moduledoc """
  Follows CodeRabbit's check run on a pull request Rail asked it to review. Its start marks the review as under way.
  Its completion reads the reviews CodeRabbit submitted since it was asked, with their inline comments, as CodeRabbit's
  report for the review lead. A skip, a rate limit or a failure ends it with nothing to report.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.FinishCoderabbitReview

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @app "coderabbitai"
  @bot "coderabbitai[bot]"
  @failed ["failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"]
  # Enough for a large review's comments without filling the lead's context with one.
  @comment_chars 4_000
  @report_chars 60_000

  @doc """
  Applies a `check_run` webhook `payload` on `project`'s repository. Returns `{:ok, review}` for a check of a review
  Rail is waiting on, and `:ignored` for any other check.
  """
  def handle_coderabbit_check(%Project{} = project, %{"action" => action, "check_run" => %{} = check}) do
    with true <- coderabbit?(check),
         %CoderabbitReview{} = review <- waiting_review(project, check) do
      apply_check(project, review, action, check)
    else
      _not_ours -> :ignored
    end
  end

  def handle_coderabbit_check(%Project{}, _payload), do: :ignored

  defp apply_check(%Project{} = project, %CoderabbitReview{} = review, "completed", %{} = check) do
    title = get_in(check, ["output", "title"]) || ""

    cond do
      title =~ ~r/rate limit/i -> finish_coderabbit_review(review, :rate_limited, %{}, nil)
      check["conclusion"] == "skipped" -> finish_coderabbit_review(review, :skipped, %{}, nil)
      check["conclusion"] in @failed -> finish_coderabbit_review(review, :failed, %{}, nil)
      true -> read_comments(project, review)
    end
  end

  defp apply_check(%Project{}, %CoderabbitReview{status: :requested} = review, _started, %{}) do
    {:ok, reviewing} = review |> CoderabbitReview.status_changeset(:reviewing) |> Repo.update()
    broadcast_pipeline_changed(Repo.get!(Task, review.task_id))
    {:ok, reviewing}
  end

  defp apply_check(%Project{}, %CoderabbitReview{} = review, _started, %{}), do: {:ok, review}

  defp read_comments(%Project{} = project, %CoderabbitReview{} = review) do
    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, reviews} <- GitHub.list_reviews(token, project.github_repo, review.pr_number),
         {:ok, comments} <- GitHub.list_review_comments(token, project.github_repo, review.pr_number) do
      submitted = Enum.filter(reviews, &(by_coderabbit?(&1) and since?(&1["submitted_at"], review.inserted_at)))
      ids = MapSet.new(submitted, & &1["id"])
      inline = Enum.filter(comments, &MapSet.member?(ids, &1["pull_request_review_id"]))
      report = if submitted != [], do: report(review, submitted, inline)

      finish_coderabbit_review(review, :done, %{comment_count: length(inline)}, report)
    else
      {:error, _unread} -> finish_coderabbit_review(review, :failed, %{}, nil)
    end
  end

  defp report(%CoderabbitReview{} = review, submitted, inline) do
    bodies = for %{"body" => body} <- submitted, body = String.trim(body || ""), body != "", do: clip(body)
    comments = Enum.map(inline, &comment/1)

    """
    CodeRabbit reviewed commit #{String.slice(review.head_sha, 0, 7)} on pull request ##{review.pr_number} and left #{length(inline)} inline comments.

    ## Review

    #{Enum.join(bodies, "\n\n")}

    ## Inline comments

    #{Enum.join(comments, "\n\n")}
    """
    |> String.trim()
    |> String.slice(0, @report_chars)
  end

  defp comment(%{"path" => path} = comment) do
    to = comment["line"] || comment["original_line"]
    from = comment["start_line"] || comment["original_start_line"]
    lines = if is_integer(from) and from != to, do: "#{from}-#{to}", else: "#{to}"
    "### #{path}:#{lines}\n\n#{clip(comment["body"] || "")}"
  end

  defp clip(text) do
    if String.length(text) > @comment_chars, do: String.slice(text, 0, @comment_chars) <> "\n[cut]", else: text
  end

  defp coderabbit?(%{"app" => %{"slug" => @app}}), do: true
  defp coderabbit?(%{"name" => "CodeRabbit"}), do: true
  defp coderabbit?(%{}), do: false

  defp by_coderabbit?(%{"user" => %{"login" => @bot}}), do: true
  defp by_coderabbit?(%{}), do: false

  defp since?(at, %DateTime{} = asked) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, submitted, _offset} -> DateTime.compare(submitted, DateTime.truncate(asked, :second)) != :lt
      _unreadable -> false
    end
  end

  defp since?(_never, %DateTime{}), do: false

  # The check names its pull request; one from a fork names none, and is matched on the commit Rail asked about.
  defp waiting_review(%Project{} = project, %{} = check) do
    numbers = for %{"number" => number} when is_integer(number) <- check["pull_requests"] || [], do: number
    head = check["head_sha"] || ""

    Repo.one(
      from r in CoderabbitReview,
        where: r.project_id == ^project.id and r.status in ^CoderabbitReview.pending_statuses(),
        where: r.pr_number in ^numbers or r.head_sha == ^head,
        order_by: [desc: r.inserted_at],
        limit: 1
    )
  end
end
