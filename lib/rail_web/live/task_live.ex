defmodule RailWeb.TaskLive do
  @moduledoc """
  One task: the ticket its product run wrote, and the conversation with it in a
  sidebar.

  Only the product stage is driven today, so the page is the product stage and
  the chat, and nothing else. The run each of them works on is the run for the
  stage the task sits at.

  The page owns one thing the components cannot: the `run:<id>` subscription. A
  LiveComponent may not subscribe, so log lines arrive here and are forwarded to
  the conversation with `send_update/2`.
  """
  use RailWeb, :live_view

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
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
      <div id="task-page" data-qa="task-page" class="contents">
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

        <.live_component
          :if={@task != nil and @task.stage == :product and @selected_run != nil}
          module={ProductStage}
          id="product-stage-component"
          task={@task}
          run={@selected_run}
        >
          <:actions>
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              blocked?={@blocked?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
            />
          </:sidebar>
        </.live_component>

        <.task_layout
          :if={@task != nil and not (@task.stage == :product and @selected_run != nil)}
          task={@task}
          run={@selected_run}
          title={@task.issue.title}
        >
          <:actions>
            <.cleanup_button task={@task} cleaning_up={@cleaning_up} />
          </:actions>
          <:sidebar>
            <.conversation_sidebar
              task={@task}
              roles_map={@roles_map}
              blocked?={@blocked?}
              pending_question={@pending_question}
              pending_questions={@pending_questions}
              answer_text={@answer_text}
            />
          </:sidebar>
        </.task_layout>
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
    _sent = Pipeline.send_answers(socket.assigns.selected_run)
    {:noreply, refresh_task(socket)}
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

  # A queued message went out, or came back, on its own time.
  def handle_info({:run_changed, _run_id}, socket) do
    {:noreply, refresh_task(socket)}
  end

  # A finished turn may have rewritten the ticket on disk without changing a row,
  # so the product stage is told to read it again rather than left to notice.
  def handle_info({:os_process_finished, _run, _outcome}, socket) do
    socket = refresh_task(socket)

    if match?(%{task: %Task{stage: :product}, selected_run: %Run{}}, socket.assigns) do
      send_update(ProductStage, id: "product-stage-component", task: socket.assigns.task)
    end

    {:noreply, socket}
  end

  # The product stage sends this once the human approves its ticket.
  def handle_info(:task_changed, socket) do
    {:noreply, refresh_task(socket)}
  end

  # A cleaned-up task is gone, so the issue is where it can be started again.
  def handle_async(:cleanup, {:ok, {:ok, %Task{issue_id: issue_id}}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues/#{issue_id}")}
  end

  def handle_async(:cleanup, {:ok, {:error, :task_busy}}, socket) do
    socket =
      socket
      |> assign(:cleaning_up, false)
      |> put_flash(:error, "Stop the task's run before cleaning it up")
      |> refresh_task()

    {:noreply, socket}
  end

  def handle_async(:cleanup, _result, socket) do
    socket =
      socket
      |> assign(:cleaning_up, false)
      |> put_flash(:error, "Could not clean up the task")
      |> refresh_task()

    {:noreply, socket}
  end

  attr :task, :any, required: true
  attr :cleaning_up, :boolean, required: true

  # A cleaned-up task is history: there is nothing left on disk to clean.
  defp cleanup_button(assigns) do
    ~H"""
    <button
      :if={@task.cleaned_up_at == nil}
      type="button"
      id="cleanup-task"
      data-qa="cleanup_task"
      phx-click="cleanup"
      data-confirm="Clean up this task? Its worktree and scratch files will be deleted."
      disabled={@cleaning_up}
      class="px-4 py-2 rounded-lg border border-red-300 dark:border-red-800 text-sm font-semibold text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950 cursor-pointer disabled:opacity-50"
    >
      {if @cleaning_up, do: "Cleaning up…", else: "Clean up"}
    </button>
    """
  end

  attr :task, :any, required: true
  attr :roles_map, :map, required: true
  attr :blocked?, :boolean, required: true
  attr :pending_question, :any, required: true
  attr :pending_questions, :list, required: true
  attr :answer_text, :string, required: true

  # Questions sit above the conversation they came out of.
  defp conversation_sidebar(assigns) do
    ~H"""
    <div :if={@pending_question != nil} class="p-4 border-b border-slate-200 dark:border-slate-700">
      <.answer_field
        question={@pending_question}
        questions={@pending_questions}
        answer_text={@answer_text}
      />
    </div>

    <!-- Answering only records. The round reaches the agent when the human says it is done. -->
    <div
      :if={@blocked? and @pending_question == nil}
      id="send-answers-panel"
      data-qa="send_answers_panel"
      class="flex items-center justify-between gap-2 p-4 border-b border-slate-200 dark:border-slate-700"
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
    """
  end

  defp refresh_task(socket) do
    case Pipeline.get_task(socket.assigns.task_id) do
      {:ok, task} -> apply_task(socket, task)
      {:error, _reason} -> assign(socket, :task, nil)
    end
  end

  defp apply_task(socket, %Task{} = task) do
    roles = if task.project_id, do: Rail.Roles.list_roles(task.project_id), else: []
    selected_run = stage_run(task)
    pending_questions = pending_questions(task, selected_run)
    pending_question = select_question(pending_questions, socket.assigns.selected_question_id)

    sync_run_subscription(socket, selected_run)

    socket
    |> assign(:task, task)
    |> assign(:page_title, task.issue.title)
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
  defp stage_run(%Task{stage: stage, runs: runs}) do
    Enum.find(runs, &(&1.role != nil and &1.role.stage == stage))
  end

  # A run can ask several things at once, so a blocked run shows the whole queue
  # as tabs, in the order they were asked.
  defp pending_questions(%Task{} = task, %Run{status: :blocked_on_input}) do
    Pipeline.list_questions(task, status: :pending, order_by: [asc: :inserted_at, asc: :id])
  end

  defp pending_questions(%Task{}, _not_blocked), do: []

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

  defp answer_one(question_id, answer) do
    with {:ok, question} <- Pipeline.get_question(question_id) do
      Pipeline.answer_question(question, answer)
    end
  end

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
