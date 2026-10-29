defmodule Rail.Pipeline.Workers.NotifyOwner do
  @moduledoc """
  Sends a task's owner one Slack direct message when a turn left the task waiting on them, or someone else merged
  it. It decides when it runs, so a round Rail answered itself, or a wait someone already ended, sends nothing.
  """
  use Oban.Worker, queue: :issues, max_attempts: 3, unique: [period: :infinity]

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Slack
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    with %Run{task_id: task_id} <- Repo.get(Run, run_id),
         %Task{issue: %Issue{owner_user_id: "" <> owner_id}} = task <-
           Task |> Repo.get(task_id) |> Repo.preload([:issue, runs: [:role, :questions]]),
         %Run{id: ^run_id} = run <- Task.stage_run(task),
         true <- Run.needs_attention?(%{run | task: task}),
         state when state in [:blocked, :failed, :done] <- Run.state(run),
         {:ok, owner, workspace} <- recipient(owner_id) do
      send_message(workspace, owner, task, reason(state, task, run))
    else
      _gone_not_waiting_or_not_subscribed -> :ok
    end
  end

  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    with %Task{merged_at: %DateTime{}, issue: %Issue{owner_user_id: "" <> owner_id}} = task <-
           Task |> Repo.get(task_id) |> Repo.preload([:issue, :merged_by]),
         false <- task.merged_by_id == owner_id,
         {:ok, owner, workspace} <- recipient(owner_id) do
      send_message(workspace, owner, task, merged_line(task.merged_by))
    else
      _gone_own_merge_or_not_subscribed -> :ok
    end
  end

  # Read when the job runs, so turning notifications off, or unlinking Slack, stops what was already queued.
  defp recipient(owner_id) do
    with {:ok, %User{slack_notifications: true, slack_user_id: "" <> _slack_id, slack_team_id: "" <> team_id} = owner} <-
           Users.get_user(id: owner_id),
         {:ok, workspace} <- Projects.get_slack_workspace(external_id: team_id) do
      {:ok, owner, workspace}
    end
  end

  defp send_message(workspace, %User{slack_user_id: slack_user_id}, %Task{issue: %Issue{} = issue} = task, line) do
    link = "<#{RailWeb.Endpoint.url()}/tasks/#{task.id}|#{escape("#{issue.identifier} #{issue.title}")}>"
    {:ok, _ts} = Slack.post_channel_message(workspace, slack_user_id, link <> "\n" <> line)
    :ok
  end

  defp reason(:blocked, %Task{stage: stage}, %Run{questions: questions}) do
    case Enum.count(questions, &(&1.status == :pending)) do
      0 -> "#{Task.stage_label(stage)} needs an answer from you."
      1 -> "#{Task.stage_label(stage)} has *a question* for you."
      count -> "#{Task.stage_label(stage)} has *#{count} questions* for you."
    end
  end

  # A changeset blanks an error of whitespace, so there is always a first line to give.
  defp reason(:failed, %Task{stage: stage}, %Run{error: error}) do
    first_line = error |> String.trim() |> String.split("\n") |> hd() |> String.slice(0, 200)
    "#{Task.stage_label(stage)} failed: #{escape(first_line)}"
  end

  defp reason(:done, %Task{stage: :plan, issue: %Issue{} = issue} = task, %Run{}) do
    cond do
      match?(%{options: [_first | _rest], picked: nil}, Pipeline.read_design(task, pages: false)) -> "Pick a design."
      Issue.skips_step?(issue, :architect) -> "The ticket is ready for you to review."
      true -> "The plan is ready for you to review."
    end
  end

  defp reason(:done, %Task{stage: :engineer}, %Run{}), do: "The diff is ready for you to review."

  defp reason(:done, %Task{stage: :review} = task, %Run{}) do
    case task |> Pipeline.list_findings() |> Enum.count(&Finding.undecided?/1) do
      0 -> "Review is waiting on you."
      1 -> "Review finished with *1 finding* for you to rule on."
      count -> "Review finished with *#{count} findings* for you to rule on."
    end
  end

  defp reason(:done, %Task{stage: :finalize}, %Run{}), do: "Ready to finalize."

  defp merged_line(%User{} = merger), do: "Merged by #{escape(merger.name || merger.login)}."
  defp merged_line(nil), do: "Merged on GitHub."

  # Slack reads these three as markup in a message's text.
  defp escape(text),
    do: text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
end
