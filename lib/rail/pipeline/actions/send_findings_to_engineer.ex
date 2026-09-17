defmodule Rail.Pipeline.Actions.SendFindingsToEngineer do
  @moduledoc """
  Sends the findings a human chose to address back to the engineer.

  Only what they marked fix goes: a dismissed finding is not the engineer's
  problem, and one already fixed has nothing left to do. The note is left on the
  engineer's own run as its pending answer, which is how every resumed stage is
  told something, so the engineer reads it as the first thing in the turn rather
  than as a brief it has already seen.

  This is a one-way door: the task leaves review, and a task no longer there has
  nothing left to send.
  """

  import Rail.Pipeline.Utils.SendBack

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Sends `run`'s outstanding findings to the engineer and enters that stage.

  Returns `{:ok, run}`, the review run that was handed in, latched done.
  """
  def send_findings_to_engineer(%Run{} = run) do
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

  defp sendable(%Task{stage: stage}) when stage != :review, do: {:error, {:invalid_stage, stage}}

  defp sendable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  # Everything has to have been ruled on first: sending while one is undecided
  # would drop it from the round without anyone having said to.
  defp outstanding(%Task{} = task) do
    findings = Pipeline.list_review_findings(task)

    cond do
      Enum.any?(findings, &ReviewFinding.undecided?/1) -> {:error, :findings_undecided}
      Enum.filter(findings, &ReviewFinding.outstanding?/1) == [] -> {:error, :nothing_outstanding}
      true -> {:ok, Enum.filter(findings, &ReviewFinding.outstanding?/1)}
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
    The reviewer read the change you pushed and a human has decided which of its findings to address. These are those findings, and they are all of them: anything the reviewer raised that is not here was dismissed and is not yours to fix.

    #{Enum.map_join(findings, "\n\n", &finding/1)}

    Each carries the reviewer's suggested fix, written for a finding that would be addressed, which is what this one is: apply it rather than weighing whether to. Address every one of them in the same worktree on the same branch, run the project's checks from the top, and write the commit message file as you did before - that round becomes a commit of its own, so describe what you changed this round rather than the whole ticket again. Where you disagree with a finding, say so and why rather than silently leaving it.
    """
  end

  # Tagged the way an issue's comments are, because the detail is the reviewer's
  # own prose and a heading inside it would otherwise read as the next finding.
  defp finding(%ReviewFinding{} = finding) do
    attrs =
      [key: finding.key, severity: finding.severity, file: finding.file, line: finding.line]
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Enum.map_join("", fn {name, value} -> ~s( #{name}="#{value}") end)

    String.trim("""
    <finding#{attrs}>
    #{finding.title}

    #{String.trim(finding.detail || "")}
    #{suggestion(finding)}</finding>
    """)
  end

  # The reviewer wrote the remedy for this reader, so it goes over labelled
  # rather than run together with the reasoning the human ruled on.
  defp suggestion(%ReviewFinding{suggestion: suggestion}) when is_binary(suggestion) do
    case String.trim(suggestion) do
      "" -> ""
      trimmed -> "\nSuggested fix: #{trimmed}\n"
    end
  end

  defp suggestion(%ReviewFinding{}), do: ""

  defp enter_next(%Run{} = run) do
    {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
    {:ok, _next} = Pipeline.enter_stage(run.task, :engineer)

    {:ok, %{latched | task: run.task, role: run.role}}
  end
end
