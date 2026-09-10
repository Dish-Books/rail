defmodule Rail.Pipeline.Actions.RegisterQuestion do
  @moduledoc """
  Action that registers an agent question detected during run execution.
  Enforces duplicate-question suppression, parks the stage (`stage_state: :blocked`),
  marks the role run as `:blocked_on_input`, and broadcasts `pipeline_changed`.
  """

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.QuestionDetector
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent

  require Logger

  @doc """
  Registers a detected question for a task and role run.
  """
  def register_question(task_or_id, role_run_or_id, question_or_attrs, opts) when is_list(opts) do
    do_register(task_or_id, role_run_or_id, question_or_attrs, opts)
  end

  def register_question(task_or_id, question_or_attrs, opts) when is_list(opts) do
    do_register(task_or_id, nil, question_or_attrs, opts)
  end

  def register_question(task_or_id, role_run_or_id, question_or_attrs) do
    do_register(task_or_id, role_run_or_id, question_or_attrs, [])
  end

  @doc """
  Convenience 2-arity variant.
  """
  def register_question(task_or_id, question_or_attrs) do
    do_register(task_or_id, nil, question_or_attrs, [])
  end

  defp do_register(task_or_id, role_run_or_id, question_or_attrs, _opts) do
    with %Task{} = task <- resolve_task(task_or_id),
         role_run = resolve_role_run(role_run_or_id, task),
         {:ok, prompt, options, context_summary, role_id} <- extract_question_attrs(question_or_attrs, task, role_run) do
      handle_registration(task, role_run, prompt, options, context_summary, role_id)
    else
      nil -> {:error, :task_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_registration(%Task{} = task, role_run, prompt, options, context_summary, role_id) do
    cond do
      task.stage_state == :blocked and is_binary(task.question_id) ->
        {:ok, :already_registered}

      undelivered_pending_answer?(role_run) ->
        drop_question(role_run)

      true ->
        register_or_reuse_question(task, role_run, prompt, options, context_summary, role_id)
    end
  end

  defp undelivered_pending_answer?(%RoleRun{pending_answer: pending}) when is_binary(pending) do
    String.trim(pending) != ""
  end

  defp undelivered_pending_answer?(_other), do: false

  defp drop_question(role_run) do
    msg =
      "[rail] Question asked before the human reply reached this role; " <>
        "it goes to the resumed run, not the inbox."

    Logger.info(msg)

    if role_run do
      append_run_event(role_run.id, msg)
    end

    {:ok, :dropped}
  end

  defp register_or_reuse_question(task, role_run, prompt, options, context_summary, role_id) do
    existing_question = find_existing_pending_question(task.id, prompt)

    {question, question_id} =
      case existing_question do
        %Question{} = existing ->
          {existing, existing.id}

        nil ->
          resolved_role_id = role_id || (role_run && role_run.role_id) || resolve_default_role_id(task)

          attrs = %{
            task_id: task.id,
            role_id: resolved_role_id,
            prompt: prompt,
            options: options,
            context_summary: context_summary || "Asked during: #{task.title}",
            status: :pending
          }

          {:ok, new_question} =
            %Question{}
            |> Question.changeset(attrs)
            |> Repo.insert()

          {new_question, new_question.id}
      end

    {:ok, updated_task} =
      task
      |> Task.changeset(%{
        stage_state: :blocked,
        question_id: question_id
      })
      |> Repo.update()

    if role_run do
      role_run
      |> RoleRun.changeset(%{status: :blocked_on_input})
      |> Repo.update!()
    end

    Pipeline.broadcast_pipeline_changed(%{
      task_id: updated_task.id,
      event: :question_registered,
      question_id: question_id
    })

    {:ok, question}
  end

  defp find_existing_pending_question(task_id, prompt) do
    normalized_target = String.downcase(String.trim(prompt))

    pending_questions =
      Repo.all(
        from q in Question,
          where: q.task_id == ^task_id and q.status == :pending,
          order_by: [desc: q.inserted_at]
      )

    Enum.find(pending_questions, fn q ->
      String.downcase(String.trim(q.prompt || "")) == normalized_target
    end)
  end

  defp extract_question_attrs(%QuestionDetector{} = q, task, role_run) do
    trimmed_prompt = String.trim(q.prompt || "")

    if trimmed_prompt == "" do
      {:error, :invalid_prompt}
    else
      role_id = q.role_id || (role_run && role_run.role_id)
      context_summary = q.context_summary || "Asked during: #{task.title}"
      {:ok, trimmed_prompt, q.options || [], context_summary, role_id}
    end
  end

  defp extract_question_attrs(text, task, role_run) when is_binary(text) do
    case QuestionDetector.detect_question(text,
           task_id: task.id,
           role_id: role_run && role_run.role_id,
           task_title: task.title
         ) do
      %QuestionDetector{} = detected ->
        extract_question_attrs(detected, task, role_run)

      nil ->
        {:error, :no_question_detected}
    end
  end

  defp extract_question_attrs(attrs, task, role_run) when is_map(attrs) do
    raw_prompt = attrs[:prompt] || attrs["prompt"] || ""
    trimmed_prompt = String.trim(to_string(raw_prompt))

    if trimmed_prompt == "" do
      {:error, :invalid_prompt}
    else
      options = attrs[:options] || attrs["options"] || []
      context_summary = attrs[:context_summary] || attrs["context_summary"] || "Asked during: #{task.title}"
      role_id = attrs[:role_id] || attrs["role_id"] || (role_run && role_run.role_id)
      {:ok, trimmed_prompt, options, context_summary, role_id}
    end
  end

  defp extract_question_attrs(_other, _task, _role_run), do: {:error, :invalid_question_attrs}

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil

  defp resolve_role_run(%RoleRun{} = role_run, _task), do: role_run
  defp resolve_role_run(role_run_id, _task) when is_binary(role_run_id), do: Repo.get(RoleRun, role_run_id)
  defp resolve_role_run(_other, task), do: find_role_run_for_task(task)

  defp find_role_run_for_task(%Task{id: task_id}) do
    Repo.one(
      from r in RoleRun,
        where: r.task_id == ^task_id,
        order_by: [desc: r.inserted_at],
        limit: 1
    )
  end

  defp resolve_default_role_id(%Task{project_id: project_id, stage: stage}) do
    case Roles.role_for_stage(project_id, stage) do
      {:ok, %Role{id: role_id}} -> role_id
      _other -> nil
    end
  end

  defp append_run_event(role_run_id, line) do
    max_seq =
      Repo.one(
        from e in RunEvent,
          where: e.role_run_id == ^role_run_id,
          select: max(e.seq)
      ) || 0

    now = DateTime.utc_now()

    event_attrs = %{
      role_run_id: role_run_id,
      seq: max_seq + 1,
      line: line,
      inserted_at: now,
      updated_at: now
    }

    {:ok, event} = %RunEvent{} |> RunEvent.changeset(event_attrs) |> Repo.insert()
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{role_run_id}", {:run_events, role_run_id, [event]})
    event
  end
end
