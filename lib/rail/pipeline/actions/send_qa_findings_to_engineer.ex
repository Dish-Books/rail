defmodule Rail.Pipeline.Actions.SendQaFindingsToEngineer do
  @moduledoc """
  Sends the QA findings a human chose to address back to the engineer.

  Only what they marked fix goes: a dismissed finding is not the engineer's
  problem, and one already fixed has nothing left to do. The note is left on the
  engineer's own run as its pending answer, which is how every resumed stage is
  told something, so the engineer reads it as the first thing in the turn rather
  than as a brief it has already seen.

  What goes over is what QA saw rather than what it concluded: the steps, what
  was expected against what happened, and what each piece of evidence shows. A
  defect the engineer cannot reproduce is a defect it will argue with.

  This is a one-way door: the task leaves QA, and a task no longer there has
  nothing left to send. What the engineer fixes goes back through the reviewer
  before it reaches QA again.
  """

  import Rail.Pipeline.Utils.SendBack

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Sends `run`'s outstanding findings to the engineer and enters that stage.

  Returns `{:ok, run}`, the QA run that was handed in, latched done.
  """
  def send_qa_findings_to_engineer(%Run{} = run) do
    run = Repo.preload(run, [task: [:issue, :runs]], force: true)

    with :ok <- sendable(run.task),
         {:ok, findings} <- outstanding(run.task),
         {:ok, %Role{} = role} <- Roles.get_role(project_id: run.task.project_id, stage: :engineer) do
      brief_engineer(run.task, role, findings)
      enter_next(run)
    else
      {:error, :role_not_found} -> {:error, :no_engineer_role}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sendable(%Task{stage: stage}) when stage != :qa, do: {:error, {:invalid_stage, stage}}

  defp sendable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  # Everything has to have been ruled on first: sending while one is undecided
  # would drop it from the round without anyone having said to.
  defp outstanding(%Task{} = task) do
    findings = Pipeline.list_qa_findings(task)

    cond do
      Enum.any?(findings, &QaFinding.undecided?/1) -> {:error, :findings_undecided}
      Enum.filter(findings, &QaFinding.outstanding?/1) == [] -> {:error, :nothing_outstanding}
      true -> {:ok, Enum.filter(findings, &QaFinding.outstanding?/1)}
    end
  end

  # The engineer has run before, so the note waits on its existing run; a stage
  # `enter_stage/3` is about to spawn reads its pending answer on the way out.
  #
  # The pending answer is consumed by the spawn and never written anywhere, so
  # the note is also recorded on the engineer's log. Without it the engineer
  # simply starts working again with nothing in its conversation saying why, and
  # a reader has no way to see what it was asked to do.
  defp brief_engineer(%Task{} = task, %Role{id: role_id}, findings) do
    note = note(findings)
    send_back(task, :engineer, note)

    case Repo.get_by(Run, task_id: task.id, role_id: role_id) do
      %Run{} = engineer_run -> Pipeline.update_run(engineer_run, %{pending_answer: note})
      nil -> :ok
    end
  end

  defp note(findings) do
    """
    QA drove the running application against this ticket and a human has decided which of its findings to address. These are those findings, and they are all of them: anything QA raised that is not here was dismissed and is not yours to fix.

    #{Enum.map_join(findings, "\n\n", &finding/1)}

    Reproduce each one before you change anything - the steps are there because a defect you cannot see is a defect you will argue with rather than fix. Each carries QA's suggested fix, written for a finding that would be addressed, which is what this one is: apply it rather than weighing whether to. Work in the same worktree on the same branch, run the project's checks from the top, and write the commit message file as you did before - that round becomes a commit of its own, so describe what you changed this round rather than the whole ticket again. Where you disagree with a finding, say so and why rather than silently leaving it.
    """
  end

  # Tagged the way an issue's comments are, because the body is QA's own prose
  # and a heading inside it would otherwise read as the next finding.
  defp finding(%QaFinding{} = finding) do
    attrs =
      [key: finding.key, severity: finding.severity, screen: finding.screen]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.map_join("", fn {name, value} -> ~s( #{name}="#{value}") end)

    String.trim("""
    <finding#{attrs}>
    #{finding.title}

    Found by: #{finding.check}
    #{section("Fails acceptance criterion", finding.criterion)}#{section("Steps to reproduce", finding.steps)}#{section("Expected", finding.expected)}#{section("Observed", finding.observed)}#{section("Detail", finding.detail)}#{evidence(finding)}#{section("Suggested fix", finding.suggestion)}</finding>
    """)
  end

  # A field QA left blank never gets this far: the changeset reads whitespace as
  # nothing and stores it as nothing.
  defp section(_label, nil), do: ""
  defp section(label, value), do: "\n#{label}: #{String.trim(value)}\n"

  # The engineer cannot open a screenshot, so what it is handed is what each one
  # is of. That is enough to know a picture exists and to ask for it.
  defp evidence(%QaFinding{evidence: []}), do: ""

  defp evidence(%QaFinding{evidence: evidence}) do
    "\nEvidence: #{Enum.map_join(evidence, "; ", &one_evidence/1)}\n"
  end

  defp one_evidence(%QaEvidence{name: name, text: text}) when is_binary(text), do: "#{name} - #{text}"
  defp one_evidence(%QaEvidence{name: name, kind: kind}), do: "#{name} (#{kind})"

  defp enter_next(%Run{} = run) do
    {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
    {:ok, _next} = Pipeline.enter_stage(run.task, :engineer)

    {:ok, %{latched | task: run.task, role: run.role}}
  end
end
