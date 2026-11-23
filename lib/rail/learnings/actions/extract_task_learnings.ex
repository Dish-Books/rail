defmodule Rail.Learnings.Actions.ExtractTaskLearnings do
  @moduledoc """
  Distills one finished task into observations, once: a task already extracted returns before anything is fetched or run.
  The observations and the task's marker are written together, so a failed pass marks nothing and runs again.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.EnqueuePullRequests
  import Rail.Learnings.Utils.InsertObservations
  import Rail.Learnings.Utils.RunCuratorRole

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Extracts `task`'s observations unless it already has been. Returns
  `{:ok, task}` as it now stands, or the error that stopped the pass.
  """
  def extract_task_learnings(%Task{id: task_id}) do
    case Repo.preload(Repo.get!(Task, task_id), [:project, :issue]) do
      %Task{learnings_extracted_at: %DateTime{}} = task -> {:ok, task}
      %Task{} = task -> extract(task)
    end
  end

  defp extract(%Task{project: %Project{} = project} = task) do
    if is_integer(task.pr_number), do: {:ok, _queued} = enqueue_pull_requests(project, task.pr_number)

    dir = Path.join([Rail.scratch_root(), project.id, "learnings", "tasks", task.id])

    # The files are copies of what the database holds, so none outlive the pass.
    try do
      :ok = Learnings.write_task_files(task, dir)

      with {:ok, result} <- run_curator_role(project, dir, brief(task, dir)) do
        record(task, result)
      end
    after
      File.rm_rf(dir)
    end
  end

  defp record(%Task{project_id: project_id} = task, result) do
    rule_ids =
      Repo.all(from l in Learning, where: l.project_id == ^project_id and l.status != :proposed, select: l.id)

    abandoned = task.issue.state == :canceled

    sightings =
      for %{"text" => text} = sighting <- List.wrap(result["observations"]),
          is_binary(text) and String.trim(text) != "" do
        %{
          task_id: task.id,
          source_kind: :extraction,
          text: String.trim(text),
          excerpt: if(is_binary(sighting["excerpt"]), do: sighting["excerpt"]),
          abandoned: abandoned,
          learning_id: if(sighting["rule"] in rule_ids, do: sighting["rule"])
        }
      end

    {:ok, task} =
      Repo.transaction(fn ->
        insert_observations(project_id, sightings)
        {:ok, task} = Pipeline.update_task(task, %{learnings_extracted_at: DateTime.utc_now()})
        task
      end)

    if sightings != [], do: broadcast_learnings_changed(project_id)
    {:ok, task}
  end

  defp brief(%Task{issue: %Issue{} = issue} = task, dir) do
    result = Path.join(dir, "result.json")
    ending = if issue.state == :canceled, do: "was abandoned", else: "was merged"

    String.trim("""
    #{issue.identifier}, "#{issue.title}", has finished: it #{ending}. Read what happened on it and write down what it teaches a later run: the corrections people made, the decisions they took, what an agent got wrong and was told, and anything about the environment it had to work around.

    You are writing observations, not rules. A person or the daily curator decides what becomes a rule, so record what was seen, plainly, and leave the generalizing to them. You are reading, not changing anything: write no file but #{result}.

    Everything is in #{dir}:

    - ticket.md and plan.md, what was asked for and how it was planned.
    - findings.md, every review and QA finding with who decided it and how.
    - questions.md, every question an agent asked and who answered it.
    - transcripts/, each run's transcript, named by stage.
    - compare.diff, when it is there: what changed between the code review last read and the code that was merged, which is what people changed after Rail.
    - rules.md, the project's rules, each under its id.
    - observations.md, what is already recorded for this task: diff comments, Fix decisions and answers. Do not restate any of it.

    Comments people left on the pull request in GitHub are collected separately, so do not distill those either.

    Write #{result} with a heredoc, the closing JSON line at column zero:

    cat > #{result} <<'JSON'
    {
      "observations": [
        {"text": "one lesson, in a sentence", "excerpt": "the words or code it rests on, quoted", "rule": "the id from rules.md it confirms, or null"}
      ]
    }
    JSON

    - One observation per lesson, specific enough that someone who never saw this task could act on it.
    - `rule` is the id of the rule in rules.md the observation is another sighting of, and null when none is.
    - `{"observations": []}` is the right answer for a task that taught nothing new.
    #{if task.pr_number, do: "", else: "- This task never opened a pull request, so there is no compare.diff."}
    """)
  end
end
