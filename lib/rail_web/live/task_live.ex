defmodule RailWeb.TaskLive do
  @moduledoc """
  One task: the ticket its product run wrote, and the conversation with it.

  Only the product stage is driven today, so the page is the product stage and
  the chat, and nothing else. The run each of them works on is the run for the
  stage the task sits at.

  The page owns one thing the components cannot: the `run:<id>` subscription. A
  LiveComponent may not subscribe, so log lines arrive here and are forwarded to
  the conversation with `send_update/2`.
  """
  use RailWeb, :live_view

  import RailWeb.CoreComponents, only: [answer_field: 1, icon: 1, project_badge: 1]

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.RunState
  alias RailWeb.Components.StageLabel
  alias RailWeb.Live.ProductStage
  alias RailWeb.Live.RunConversation

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:task, nil)
      |> assign(:task_id, nil)
      |> assign(:page_title, "Task")
      |> assign(:current_section, :tasks)
      |> assign(:current_project_id, nil)
      |> assign(:selected_run, nil)
      |> assign(:subscribed_run_id, nil)
      |> assign(:roles_map, %{})
      |> assign(:pending_question, nil)
      |> assign(:pending_questions, [])
      |> assign(:selected_question_id, nil)
      |> assign(:answer_text, "")
      |> assign(:blocked?, false)
      |> assign(:cleaning_up, false)

    {:ok, socket}
  end

  def handle_params(%{"id" => task_id}, _uri, socket) do
    socket = socket |> assign(:task_id, task_id) |> refresh_task()

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} {assigns}>
      <div class="max-w-5xl mx-auto px-6 py-6 space-y-6" id="task-page" data-qa="task-page">
        <div
          :if={@task == nil}
          id="task-cleaned-up"
          data-qa="task-cleaned-up"
          class="flex flex-col items-center justify-center min-h-[300px] text-center p-8 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 shadow-xs"
        >
          <p class="text-base font-medium text-slate-500 dark:text-slate-400">
            This task has been cleaned up.
          </p>
        </div>

        <div :if={@task != nil} class="space-y-6">
          <div id="task-header" data-qa="task-header" class="space-y-3">
            <div class="flex items-center gap-3">
              <.project_badge project={@task.project} />
              <h1
                class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100 truncate"
                id="task-detail-title"
                data-qa="task_detail_title"
              >
                {@task.issue && @task.issue.title}
              </h1>
            </div>

            <div class="flex items-center flex-wrap gap-x-4 gap-y-1 text-xs text-slate-500 dark:text-slate-400">
              <span
                :if={@selected_run != nil}
                id="task-status-chip"
                data-qa="task_status_chip"
                class={[
                  "inline-flex items-center gap-1.5 font-semibold",
                  RunState.color_class(@selected_run)
                ]}
              >
                <.icon name={RunState.icon(@selected_run)} />
                {StageLabel.stage_label(@task, @selected_run)}
              </span>

              <span :if={@task.issue} data-qa="task_issue_identifier">{@task.issue.identifier}</span>
              <span data-qa="task_branch_name" class="font-mono">{@task.worktree_name}</span>

              <button
                type="button"
                id="cleanup-task"
                data-qa="cleanup_task"
                phx-click="cleanup"
                disabled={@cleaning_up}
                class="ml-auto px-3 py-1 rounded-full border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-50"
              >
                {if @cleaning_up, do: "Cleaning up…", else: "Clean up"}
              </button>
            </div>

            <p
              :if={@selected_run != nil and is_binary(@selected_run.error)}
              id="task-error-card"
              data-qa="task_error_card"
              class="rounded-xl border border-red-200 bg-red-50 dark:border-red-900 dark:bg-red-950 p-3 text-xs text-red-700 dark:text-red-300"
            >
              {@selected_run.error}
            </p>
          </div>

          <.live_component
            :if={@task.stage == :product and @selected_run != nil}
            module={ProductStage}
            id="product-stage-component"
            task={@task}
            run={@selected_run}
          />

          <.answer_field
            :if={@pending_question != nil}
            question={@pending_question}
            questions={@pending_questions}
            answer_text={@answer_text}
          />

          <!-- Answering only records. The round reaches the agent when the human says it is done. -->
          <div
            :if={@blocked? and @pending_question == nil}
            id="send-answers-panel"
            data-qa="send_answers_panel"
            class="flex items-center justify-between gap-2 rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 p-4"
          >
            <span class="text-xs text-slate-500 dark:text-slate-400">
              Every question is answered.
            </span>

            <button
              type="button"
              id="send-answers-button"
              data-qa="send-answers-button"
              phx-click="send_answers"
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
            >
              Send answers
            </button>
          </div>

          <.live_component
            module={RunConversation}
            id="run-conversation"
            task={@task}
            runs={@task.runs || []}
            roles_map={@roles_map}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("select_option", %{"option" => option}, socket) do
    {:noreply, assign(socket, :answer_text, option)}
  end

  def handle_event("select_question", %{"question_id" => question_id}, socket) do
    socket =
      socket
      |> assign(:selected_question_id, question_id)
      |> assign(:answer_text, "")
      |> refresh_task()

    {:noreply, socket}
  end

  def handle_event("answer_form_change", params, socket) do
    {:noreply, assign(socket, :answer_text, Map.get(params, "answer") || "")}
  end

  def handle_event("answer_question", params, socket) do
    answer = params |> Map.get("answer", socket.assigns.answer_text) |> to_string() |> String.trim()

    if answer == "" do
      {:noreply, socket}
    else
      _answered = socket |> question_id(params) |> answer_one(answer)
      {:noreply, reset_answer(socket)}
    end
  end

  def handle_event("dismiss_question", params, socket) do
    _dismissed = socket |> question_id(params) |> dismiss_one()
    {:noreply, reset_answer(socket)}
  end

  def handle_event("send_answers", _params, socket) do
    case socket.assigns.selected_run do
      %Run{} = run ->
        _sent = Pipeline.send_answers(run)
        {:noreply, refresh_task(socket)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cleanup", _params, socket) do
    task = socket.assigns.task

    socket =
      socket
      |> assign(:cleaning_up, true)
      |> start_async(:cleanup, fn -> Pipeline.cleanup_task(task) end)

    {:noreply, socket}
  end

  def handle_info({:run_events, run_id, events}, socket) do
    if socket.assigns.subscribed_run_id == run_id do
      send_update(RunConversation, id: "run-conversation", appended_events: events)
    end

    {:noreply, socket}
  end

  def handle_info({:os_process_finished, _run, _outcome}, socket) do
    {:noreply, refresh_task(socket)}
  end

  # The product stage sends this once the human approves its ticket.
  def handle_info(:task_changed, socket) do
    {:noreply, refresh_task(socket)}
  end

  def handle_async(:cleanup, _result, socket) do
    socket = socket |> assign(:cleaning_up, false) |> refresh_task()

    {:noreply, socket}
  end

  defp refresh_task(socket) do
    case Pipeline.get_task(socket.assigns.task_id) do
      {:ok, task} -> apply_task(socket, task)
      {:error, _reason} -> assign(socket, :task, nil)
    end
  end

  defp apply_task(socket, %Task{} = task) do
    roles = if task.project_id, do: Rail.Roles.list_roles(socket.assigns.current_scope, task.project_id), else: []
    selected_run = stage_run(task)
    pending_questions = pending_questions(selected_run)
    pending_question = select_question(pending_questions, socket.assigns.selected_question_id)

    sync_run_subscription(socket, selected_run)

    socket
    |> assign(:task, task)
    |> assign(:page_title, task.issue && task.issue.title)
    |> assign(:current_project_id, task.project_id)
    |> assign(:roles_map, Map.new(roles, &{&1.id, &1}))
    |> assign(:selected_run, selected_run)
    |> assign(:blocked?, match?(%Run{status: :blocked_on_input}, selected_run))
    |> assign(:subscribed_run_id, selected_run && selected_run.id)
    |> assign(:pending_questions, pending_questions)
    |> assign(:pending_question, pending_question)
    |> assign(:selected_question_id, pending_question && pending_question.id)
  end

  # The run for the stage this task sits at, picked out of the runs already loaded.
  defp stage_run(%Task{stage: stage, runs: runs}) when is_list(runs) do
    Enum.find(runs, &(&1.role != nil and &1.role.stage == stage))
  end

  defp stage_run(%Task{}), do: nil

  # A run can ask several things at once, so a blocked run shows the whole queue
  # as tabs, in the order they were asked.
  defp pending_questions(%Run{status: :blocked_on_input, task_id: task_id}) do
    Pipeline.list_questions(task_id, status: :pending, order_by: [asc: :inserted_at, asc: :id])
  end

  defp pending_questions(_not_blocked), do: []

  # The tab the human picked stays put across refreshes; once it is answered the
  # front of the queue takes over.
  defp select_question(questions, selected_id) do
    Enum.find(questions, &(&1.id == selected_id)) || List.first(questions)
  end

  # `run:<id>` carries the run's log lines and the finish of its OS process. A
  # LiveComponent cannot subscribe, so the page holds this and forwards.
  defp sync_run_subscription(socket, run) do
    previous = socket.assigns.subscribed_run_id
    current = run && run.id

    if connected?(socket) and current != previous do
      if previous, do: Phoenix.PubSub.unsubscribe(Rail.PubSub, "run:#{previous}")
      if current, do: Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{current}")
    end
  end

  defp question_id(socket, params) do
    Map.get(params, "question_id") || (socket.assigns.pending_question && socket.assigns.pending_question.id)
  end

  defp answer_one(nil, _answer), do: :ok

  defp answer_one(question_id, answer) do
    with {:ok, question} <- Pipeline.get_question(question_id) do
      Pipeline.answer_question(question, answer)
    end
  end

  defp dismiss_one(nil), do: :ok

  defp dismiss_one(question_id) do
    with {:ok, question} <- Pipeline.get_question(question_id) do
      Pipeline.dismiss_question(question)
    end
  end

  defp reset_answer(socket) do
    socket
    |> assign(:answer_text, "")
    |> assign(:selected_question_id, nil)
    |> refresh_task()
  end
end
