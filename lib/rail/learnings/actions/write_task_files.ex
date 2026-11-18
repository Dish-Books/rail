defmodule Rail.Learnings.Actions.WriteTaskFiles do
  @moduledoc """
  Writes what a curator reads about one task into a directory: ticket, plan, findings, questions, rules,
  observations, transcripts and, once there is a pull request, the code people changed after Review.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.WriteRulesFile

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @doc "Writes `task`'s files into `dir`, which it empties first, and returns `:ok`."
  def write_task_files(%Task{} = task, dir) do
    %Task{issue: %Issue{} = issue} = task = Repo.preload(task, [:project, :issue])
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "transcripts"))

    File.write!(Path.join(dir, "ticket.md"), "# #{issue.identifier} #{issue.title}\n\n#{issue.description}\n")

    case Pipeline.read_plan(task) do
      %Round{plan: content, approved_at: %DateTime{}} when is_binary(content) ->
        File.write!(Path.join(dir, "plan.md"), content)

      _unapproved ->
        :ok
    end

    File.write!(Path.join(dir, "findings.md"), findings_file(task))
    File.write!(Path.join(dir, "questions.md"), questions_file(task))
    write_rules_file(task.project, Path.join(dir, "rules.md"))
    File.write!(Path.join(dir, "observations.md"), observations_file(task))

    runs = Pipeline.list_runs(task_id: task.id, include_cleaned_up: true, preload: :role)
    Enum.each(runs, &write_transcript(&1, dir))
    write_compare(task, runs, dir)
    :ok
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
end
