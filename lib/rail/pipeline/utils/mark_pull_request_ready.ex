defmodule Rail.Pipeline.Utils.MarkPullRequestReady do
  @moduledoc false

  import Rail.Pipeline.Utils.DraftBody
  import Rail.Pipeline.Utils.SplitDemoSection

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  require Logger

  @doc """
  Takes `task`'s draft pull request out of draft, once the demo is settled. Rail's
  placeholder description is replaced first, and each open question for the lead
  is then posted as a comment of its own.

  Neither the pull request nor its description is a reason to hold the task back,
  so a failure is logged and the task returned as it stands.
  """
  def mark_pull_request_ready(%Task{pr_number: number, pr_is_draft: true} = task) when is_integer(number) do
    task = Repo.preload(task, :issue)
    %Project{} = project = Repo.get!(Project, task.project_id)

    with {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, %{"node_id" => node_id} = pull_request} <- GitHub.get_pull_request(token, project.github_repo, number),
         :ok <- describe(token, project, task, pull_request),
         :ok <- GitHub.mark_pull_request_ready(token, node_id) do
      {:ok, task} = task |> Task.changeset(%{pr_is_draft: false}) |> Repo.update()
      post_open_questions(token, project, task)
      task
    else
      {:error, reason} ->
        Logger.warning("Could not mark #{project.github_repo}##{number} ready for review: #{inspect(reason)}")
        task
    end
  end

  def mark_pull_request_ready(%Task{} = task), do: task

  # Only Rail's own placeholder is replaced, so a description a person rewrote, or
  # one on a pull request Rail adopted, stays theirs.
  defp describe(token, %Project{} = project, %Task{issue: %Issue{} = issue} = task, pull_request) do
    {kept, demo} = (pull_request["body"] || "") |> String.replace("\r\n", "\n") |> split_demo_section()

    if String.trim(kept) == draft_body(issue) do
      written =
        case File.read(Path.join([task.scratch_path, "pr", "#{issue.identifier}.md"])) do
          {:ok, text} -> String.trim(text)
          {:error, _reason} -> nil
        end

      qa =
        case Pipeline.read_qa_report(task) do
          %QaReport{verdict: nil} ->
            nil

          %QaReport{verdict: verdict, summary: summary} ->
            String.trim(String.replace("**QA:** #{QaReport.verdict_label(verdict)}. #{summary}", ~r/\s+/, " "))

          nil ->
            nil
        end

      body = [issue.url, written, qa, demo] |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.join("\n\n")

      case GitHub.update_pull_request(token, project.github_repo, task.pr_number, %{body: body}) do
        {:ok, _updated} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not describe #{project.github_repo}##{task.pr_number}: #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  # Posted only once the pull request is out of draft, so a mark-ready that failed
  # and is tried again can never post them twice.
  defp post_open_questions(token, %Project{} = project, %Task{} = task) do
    questions = Pipeline.list_questions(task, status: [:pending, :unanswered], order_by: [asc: :inserted_at])

    assumptions =
      case Pipeline.get_implementation_plan(task) do
        {:ok, %ImplementationPlan{} = plan} -> ImplementationPlan.assumptions(plan)
        {:error, :not_found} -> []
      end

    comments =
      Enum.map(questions, &question_comment/1) ++
        Enum.map(assumptions, &"**Assumption in the approved plan, for the lead to confirm**\n\n#{&1}")

    Enum.each(comments, fn body ->
      case GitHub.create_issue_comment(token, project.github_repo, task.pr_number, body) do
        {:ok, _comment} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not comment on #{project.github_repo}##{task.pr_number}: #{inspect(reason)}")
      end
    end)
  end

  defp question_comment(%Question{prompt: prompt, context_summary: context, options: options}) do
    bullets =
      [context | Enum.map(options, &"Option: #{&1}")]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map_join("\n", &"- #{&1}")

    String.trim("**Open question for the lead**\n\n#{prompt}\n\n#{bullets}")
  end
end
