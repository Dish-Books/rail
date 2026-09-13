defmodule Rail.Pipeline.Actions.RegisterQuestion do
  @moduledoc """
  Registers one question an agent asked, against the task and run that asked it.

  A prompt the run is already waiting on is reused rather than filed twice; another
  run asking the same thing files its own, since the answer goes back to whoever
  asked. The run parks (`status: :blocked_on_input`) and the questions queue in the
  order they were asked, so the human answers them one at a time without the stage
  resuming in between. The run goes to `:blocked_on_input` and `pipeline_changed` is
  broadcast either way.

  Nothing suppresses a question. A reply already queued on the run goes out alongside
  the answer when it resumes, so a question asked in that window is still filed rather
  than lost.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.DetectedQuestion
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Registers the question `run` asked.

  `run` carries its task and that task's issue, both preloaded — the title of the
  issue is what a question without its own context summary is filed under.
  """
  def register_question(%Run{task: %Task{} = task} = run, %DetectedQuestion{} = question) do
    with {:ok, attrs} <- question_attrs(question, task, run) do
      register_or_reuse_question(task, run, attrs)
    end
  end

  defp question_attrs(%DetectedQuestion{} = question, %Task{} = task, %Run{} = run) do
    case String.trim(to_string(question.prompt || "")) do
      "" ->
        {:error, :invalid_prompt}

      prompt ->
        {:ok,
         %{
           prompt: prompt,
           options: question.options || [],
           context_summary: question.context_summary || "Asked during: #{task_title(task)}",
           run_id: run.id
         }}
    end
  end

  defp register_or_reuse_question(%Task{} = task, %Run{} = run, attrs) do
    question = find_existing_pending_question(run.id, attrs.prompt) || insert_question(task, attrs)

    run |> Run.changeset(%{status: :blocked_on_input}) |> Repo.update!()

    {:ok, question}
  end

  defp insert_question(%Task{} = task, attrs) do
    %Question{}
    |> Question.changeset(%{
      task_id: task.id,
      run_id: attrs.run_id,
      prompt: attrs.prompt,
      options: attrs.options,
      context_summary: attrs.context_summary,
      status: :pending
    })
    |> Repo.insert!()
  end

  # Scoped to the run: the same prompt from a different role is a different question,
  # because the answer goes back to the run that asked it.
  defp find_existing_pending_question(run_id, prompt) do
    normalized_target = String.downcase(String.trim(prompt))

    from(q in Question,
      where: q.run_id == ^run_id and q.status == :pending,
      order_by: [desc: q.inserted_at]
    )
    |> Repo.all()
    |> Enum.find(&(String.downcase(String.trim(&1.prompt || "")) == normalized_target))
  end

  # The title lives on the issue the task links to. No clause covers an unloaded
  # association: a caller that skipped the preload finds out here.
  defp task_title(%Task{issue: %Issue{title: title}}), do: title
end
