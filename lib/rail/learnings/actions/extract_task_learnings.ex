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
  import Rail.Learnings.Utils.WriteRulesFile

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

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
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "transcripts"))

    # The files are copies of what the database holds, so none outlive the pass.
    try do
      write_files(task, dir)

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

    abandoned = task.issue.state in [:canceled, :duplicate]

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

  defp write_files(%Task{issue: %Issue{} = issue} = task, dir) do
    File.write!(Path.join(dir, "ticket.md"), "# #{issue.identifier} #{issue.title}\n\n#{issue.description}\n")

    case Pipeline.get_implementation_plan(task) do
      {:ok, %ImplementationPlan{content: content}} -> File.write!(Path.join(dir, "plan.md"), content)
      {:error, :not_found} -> :ok
    end

    File.write!(Path.join(dir, "findings.md"), findings_file(task))
    File.write!(Path.join(dir, "questions.md"), questions_file(task))
    write_rules_file(task.project, Path.join(dir, "rules.md"))
    File.write!(Path.join(dir, "observations.md"), observations_file(task))

    runs = Pipeline.list_runs(task_id: task.id, include_cleaned_up: true, preload: :role)
    Enum.each(runs, &write_transcript(&1, dir))
    write_compare(task, runs, dir)
  end

  defp findings_file(%Task{} = task) do
    findings = task |> Pipeline.list_findings() |> Repo.preload(:decided_by)

    "# Every finding on this task, with who decided it\n\n" <> Enum.map_join(findings, "\n", &finding_entry/1)
  end

  defp finding_entry(%Finding{decided_by: decided_by} = finding) do
    who = if decided_by, do: decided_by.name || decided_by.login, else: "nobody"

    """
    ## Round #{finding.round}, #{finding.kind}: #{finding.title}

    Recommended: #{finding.recommendation}. Decided: #{finding.decision || "not decided"} by #{who}. Status: #{finding.status}.#{rule_note(finding)}

    Rule: #{finding.rule}

    #{finding.problem}

    Fix: #{finding.fix}
    """
  end

  defp rule_note(%Finding{suppressed_by_id: id}) when is_binary(id), do: " Suppressed by rule #{id}."
  defp rule_note(%Finding{rule_id: id}) when is_binary(id), do: " Raised from rule #{id}."
  defp rule_note(%Finding{}), do: ""

  defp questions_file(%Task{} = task) do
    questions = task |> Pipeline.list_questions(order_by: [asc: :inserted_at]) |> Repo.preload(:answered_by)

    entries =
      Enum.map(questions, fn %Question{} = question ->
        who =
          cond do
            question.answered_by_rail -> "Rail, from a past answer"
            question.answered_by -> question.answered_by.name || question.answered_by.login
            true -> "nobody"
          end

        "## #{question.prompt}\n\n#{question.status}, answered by #{who}: #{question.answer}\n"
      end)

    "# Every question an agent asked on this task\n\n" <> Enum.join(entries, "\n")
  end

  defp observations_file(%Task{id: task_id}) do
    observations =
      Repo.all(from o in Observation, where: o.task_id == ^task_id, order_by: [asc: o.inserted_at, asc: o.id])

    entries = Enum.map(observations, &"- #{Observation.source_label(&1.source_kind)}: #{&1.text}")

    "# Already recorded for this task\n\n" <> Enum.join(entries, "\n") <> "\n"
  end

  defp write_transcript(%Run{role: %{stage: stage, cli: cli}} = run, dir) do
    lines = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    logs = cli |> Tools.parse_stream(lines) |> Map.fetch!(:logs)

    File.write!(Path.join([dir, "transcripts", "#{stage}-#{run.id}.md"]), Enum.join(logs, "\n"))
  end

  # What changed between the code Review last read and the code that merged is
  # what people did after Rail, which is the clearest correction there is.
  # The commit Review last read is on the lead's run row, since the review file goes with the scratch folder.
  defp write_compare(%Task{pr_number: number, project: %Project{} = project}, runs, dir) when is_integer(number) do
    base =
      runs
      |> Enum.filter(&(&1.role.stage == :review_lead and is_binary(&1.stage_fingerprint_head_sha)))
      |> List.last()

    with %Run{stage_fingerprint_head_sha: base_sha} <- base,
         {:ok, token} <- GitHub.installation_token(project.github_installation_id),
         {:ok, %{"head" => %{"sha" => head_sha}}} <- GitHub.get_pull_request(token, project.github_repo, number),
         {:ok, %{"files" => files}} <- GitHub.compare_commits(token, project.github_repo, base_sha, head_sha) do
      patches = Enum.map(files, &"--- #{&1["filename"]}\n#{&1["patch"]}\n")
      File.write!(Path.join(dir, "compare.diff"), Enum.join(patches, "\n"))
    end
  end

  defp write_compare(%Task{}, _runs, _dir), do: :ok

  defp brief(%Task{issue: %Issue{} = issue} = task, dir) do
    result = Path.join(dir, "result.json")
    ending = if issue.state in [:canceled, :duplicate], do: "was abandoned", else: "was merged"

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
