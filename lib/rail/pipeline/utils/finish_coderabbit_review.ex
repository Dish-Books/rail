defmodule Rail.Pipeline.Utils.FinishCoderabbitReview do
  @moduledoc """
  Records how a CodeRabbit review ended and tells the task's review lead. Comments are saved as CodeRabbit's report
  and sent to the lead to raise as findings. A review that ended without comments is said too, so the lead's turn can
  finish the Review it was holding. While QA and the code reviewer are still checking, the lead has not started on the
  round yet and reads the report when it does.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Moves `review` to `status` with `attrs` unless it already ended, and hands `report`, CodeRabbit's comments or nil,
  to the lead. Returns `{:ok, review}`, or `{:ok, :already_finished}` when a timeout and CodeRabbit's answer race.
  """
  def finish_coderabbit_review(%CoderabbitReview{} = review, status, attrs, report) do
    changes = CoderabbitReview.status_changeset(review, status, attrs).changes

    from(r in CoderabbitReview,
      where: r.id == ^review.id and r.status in ^CoderabbitReview.pending_statuses(),
      select: r
    )
    |> Repo.update_all(set: Enum.to_list(Map.put(changes, :updated_at, DateTime.utc_now())))
    |> case do
      {1, [finished]} ->
        task = Task |> Repo.get_by!(id: review.task_id, project_id: review.project_id) |> Repo.preload(:issue)
        if task.stage == :review and is_nil(task.cleaned_up_at), do: tell_lead(task, finished, report)
        broadcast_pipeline_changed(task)
        {:ok, finished}

      {0, []} ->
        {:ok, :already_finished}
    end
  end

  defp tell_lead(%Task{} = task, %CoderabbitReview{} = review, report) do
    if is_binary(report) do
      :ok = write_scratch_file(Path.join([task.scratch_path, "reports", "coderabbit.md"]), report <> "\n")
      Pipeline.broadcast_output_saved(task)
    end

    runs = Pipeline.list_runs(task_id: task.id, preload: :role)
    checking? = Enum.any?(runs, &(&1.role.stage in [:qa, :review] and &1.stage_outcome == :in_progress))

    with false <- checking?,
         %Run{} = lead <- Enum.find(runs, &match?(%Run{role: %Role{stage: :review_lead}}, &1)) do
      Pipeline.send_message(Scope.for_system(), lead, note(review, report), from: :coderabbit)
    end
  end

  defp note(%CoderabbitReview{} = review, report) when is_binary(report) do
    """
    CodeRabbit finished the review #{asked(review)} and its comments are below. Treat them as a third reviewer's report: raise a finding for each that holds, with `raised_by: coderabbit`, and merge comments that are one problem. A comment on a problem already on the task is a `note` on that finding, never a second finding. Leave out a comment that does not hold, and say why in a line when you end your turn. Then call `save_review` and write or revise the next round's plan as a review does.

    <report from="coderabbit">
    #{report}
    </report>
    """
  end

  defp note(%CoderabbitReview{} = review, nil) do
    "CodeRabbit's review #{asked(review)} ended with nothing to add (#{CoderabbitReview.status_label(review)}). Nothing changes in the review: end your turn without saving anything."
  end

  defp asked(%CoderabbitReview{head_sha: head, command: command}),
    do:
      "of commit #{String.slice(head, 0, 7)} (#{if command == :full, do: "whole pull request", else: "commits since its last review"})"
end
