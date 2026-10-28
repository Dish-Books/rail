defmodule RailWeb.Settings.WorkflowsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Issues.Schemas.Issue
  alias Rail.Workflows
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  @example """
  # .rail/workflows/dependency-updates.yml
  name: Dependency updates      # the issue title adds the date
  schedule: "0 9 * * 1"         # cron, in UTC: Mondays at 09:00
  skip: [product, design]       # any of product, design, architect, demo
  assignee: dana                # a GitHub login: who owns the issue
  instructions: |               # the issue's description
    Update Elixir and npm dependencies to their latest compatible versions.
  """

  def mount(_params, _session, socket) do
    # Projects too, since a row says when its project is inactive.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "workflows")
      Phoenix.PubSub.subscribe(Rail.PubSub, "projects")
    end

    socket =
      socket
      |> assign(:page_title, "Workflows")
      |> assign(:current_section, :workflows)
      |> assign(:example, @example)
      |> load_workflows()

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      lost_backends={@lost_backends}
    >
      <div
        class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-8"
        id="workflows-settings"
      >
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Workflows
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Read from <code class="font-mono text-[13px]">.rail/workflows/</code>
            on each project's default branch. Pause one or run it now here; edit it in the repository.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:workflows} />

        <section :if={@workflows != []} id="workflows-list-section">
          <h2 class="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
            Workflows · {length(@workflows)}
          </h2>
          <div class="rounded-xl border border-slate-200 dark:border-slate-700/70 overflow-hidden bg-slate-50 dark:bg-slate-800/40">
            <table class="w-full table-fixed" id="workflows-list">
              <colgroup>
                <col class="w-[30%]" />
                <col class="w-[20%]" />
                <col />
                <col class="w-[144px]" />
              </colgroup>
              <thead class="bg-slate-50 dark:bg-slate-800/60">
                <tr class="text-left text-xs font-medium text-slate-500 dark:text-slate-400">
                  <th class="px-4 py-2.5 font-medium">Workflow</th>
                  <th class="px-3 py-2.5 font-medium">Schedule, UTC</th>
                  <th id="workflows-stages-header" class="px-3 py-2.5 font-medium">Stages</th>
                  <th class="px-4 py-2.5 font-medium text-right">Runs</th>
                </tr>
              </thead>
              <tbody class="text-sm">
                <tr
                  :for={workflow <- @workflows}
                  id={"workflow-row-#{workflow.id}"}
                  class={[
                    "border-t border-slate-200 dark:border-slate-700/70",
                    workflow.paused && "text-slate-500 dark:text-slate-400"
                  ]}
                >
                  <td class="px-4 py-3 max-w-0">
                    <span
                      id={"workflow-name-#{workflow.id}"}
                      class="block font-medium truncate text-slate-900 dark:text-slate-100"
                      title={Workflow.name(workflow)}
                    >
                      {Workflow.name(workflow)}
                    </span>
                    <span class="mt-0.5 flex items-center gap-1.5 min-w-0">
                      <.project_badge project={workflow.project} />
                      <a
                        id={"workflow-file-#{workflow.id}"}
                        href={file_url(workflow)}
                        target="_blank"
                        rel="noopener noreferrer"
                        title={"Open #{workflow.path} on the default branch"}
                        class="font-mono text-xs text-slate-500 dark:text-slate-400 truncate hover:underline hover:text-slate-900 dark:hover:text-slate-200 focus-visible:outline-2 focus-visible:outline-indigo-500 rounded"
                      >
                        {workflow.path}
                      </a>
                    </span>
                  </td>

                  <td :if={workflow.definition == nil} colspan="2" class="px-3 py-3">
                    <span
                      id={"workflow-invalid-#{workflow.id}"}
                      class="flex items-start gap-1.5 font-semibold text-red-700 dark:text-red-300"
                    >
                      <.icon name="pi-warning-circle-fill" class="mt-0.5 size-4" /> Invalid
                    </span>
                  </td>
                  <td :if={workflow.definition != nil} class="px-3 py-3">
                    <span
                      id={"workflow-schedule-#{workflow.id}"}
                      class="block text-slate-700 dark:text-slate-300"
                      title={workflow.definition.schedule}
                    >
                      {WorkflowDefinition.schedule_label(workflow.definition)}
                    </span>
                    <span
                      id={"workflow-next-#{workflow.id}"}
                      class="block text-xs text-slate-500 dark:text-slate-400"
                    >
                      {next_label(workflow)}
                    </span>
                  </td>
                  <td :if={workflow.definition != nil} class="px-3 py-3">
                    <.stage_sequence
                      id={"workflow-stages-#{workflow.id}"}
                      skipped={workflow.definition.skip}
                    />
                  </td>

                  <td class="px-4 py-3">
                    <div :if={workflow.definition != nil} class="flex items-center justify-end gap-2">
                      <button
                        type="button"
                        id={"run-now-#{workflow.id}"}
                        phx-click="run_now"
                        phx-value-id={workflow.id}
                        aria-label={"Run #{Workflow.name(workflow)} now"}
                        title="Run now"
                        class="inline-flex items-center justify-center h-7 w-7 shrink-0 rounded-md bg-white dark:bg-slate-800 text-slate-700 dark:text-slate-200 shadow-xs ring-1 ring-inset ring-slate-300 dark:ring-slate-600 hover:bg-slate-50 dark:hover:bg-slate-700 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-slate-400"
                      >
                        <.icon name="pi-play-fill" class="size-[13px]" />
                      </button>
                      <label class={[
                        "inline-flex items-center gap-2 text-xs cursor-pointer",
                        if(workflow.paused,
                          do: "font-semibold text-slate-700 dark:text-slate-200",
                          else: "text-slate-600 dark:text-slate-300"
                        )
                      ]}>
                        <span id={"workflow-state-#{workflow.id}"} class="w-11 text-right">
                          {if workflow.paused, do: "Paused", else: "On"}
                        </span>
                        <input
                          type="checkbox"
                          role="switch"
                          id={"workflow-switch-#{workflow.id}"}
                          checked={not workflow.paused}
                          phx-click="set_paused"
                          phx-value-id={workflow.id}
                          phx-value-paused={to_string(not workflow.paused)}
                          aria-label={"#{Workflow.name(workflow)} runs on schedule"}
                          class="peer sr-only"
                        />
                        <span class="relative h-5 w-9 shrink-0 rounded-full bg-slate-300 dark:bg-slate-600 transition-colors peer-checked:bg-indigo-600 after:absolute after:top-0.5 after:left-0.5 after:size-4 after:rounded-full after:bg-white after:transition-transform peer-checked:after:translate-x-4 peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-indigo-500"></span>
                      </label>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section
          :if={@workflows == []}
          id="workflows-empty"
          class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 bg-white dark:bg-slate-900 px-5 py-4 text-sm text-slate-500 dark:text-slate-400"
        >
          <p class="font-medium text-slate-700 dark:text-slate-300">No workflows yet.</p>
          <p class="mt-1">
            Add a file like this under
            <code class="font-mono text-[13px] text-slate-700 dark:text-slate-300">.rail/workflows/</code>
            in a project's repository. Rail lists it here once it is on the default branch.
          </p>
          <div class="relative mt-3">
            <button
              type="button"
              id="copy-workflow-example"
              phx-hook="CopyText"
              data-copy-text={@example}
              aria-label="Copy the example"
              title="Copy"
              class="group absolute top-2 right-2 h-7 w-7 grid place-items-center rounded-md text-slate-400 hover:bg-slate-200 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-indigo-500"
            >
              <.icon name="pi-copy" class="h-4 w-4 group-data-[copied=true]:hidden" />
              <.icon
                name="pi-check"
                class="h-4 w-4 text-green-600 hidden group-data-[copied=true]:inline-block"
              />
            </button>
            <pre
              id="workflow-example"
              class="rounded-lg bg-slate-50 dark:bg-slate-950 ring-1 ring-slate-200 dark:ring-slate-800 px-4 py-3 pr-12 text-[12.5px] leading-relaxed font-mono text-slate-700 dark:text-slate-300 overflow-x-auto"
            >{@example}</pre>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("run_now", %{"id" => id}, socket) do
    %Workflow{} = workflow = Enum.find(socket.assigns.workflows, &(&1.id == id))
    result = Workflows.run_workflow_now(socket.assigns.current_scope, workflow)
    socket = socket |> put_flash(:info, "#{Workflow.name(workflow)} #{run_message(result, workflow)}") |> load_workflows()

    {:noreply, socket}
  end

  # The switch sends the state it is asking for, so a second click or a second tab sets it again rather than undoing it.
  def handle_event("set_paused", %{"id" => id, "paused" => paused}, socket) do
    %Workflow{} = workflow = Enum.find(socket.assigns.workflows, &(&1.id == id))
    {:ok, _workflow} = Workflows.set_workflow_paused(socket.assigns.current_scope, workflow, paused == "true")
    socket = load_workflows(socket)

    {:noreply, socket}
  end

  def handle_info({:workflows_changed, _project_id}, socket), do: {:noreply, load_workflows(socket)}
  def handle_info({:project_changed, _project_id}, socket), do: {:noreply, load_workflows(socket)}

  defp load_workflows(socket) do
    {:ok, workflows} = Workflows.list_workflows(socket.assigns.current_scope, [])
    assign(socket, :workflows, workflows)
  end

  defp next_label(%Workflow{paused: true}), do: "None while paused"
  defp next_label(%Workflow{project: %{active: false}}), do: "None while the project is inactive"
  defp next_label(%Workflow{next_run_at: next_run_at}), do: "Next #{Calendar.strftime(next_run_at, "%a %b %-d, %H:%M")}"

  defp file_url(%Workflow{project: project, path: path}) do
    encode = fn text ->
      text |> String.split("/") |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
    end

    "https://github.com/#{project.github_repo}/blob/#{encode.(project.default_branch)}/#{encode.(path)}"
  end

  defp run_message({:ok, %Issue{identifier: identifier}}, _workflow), do: "opened #{identifier}."

  defp run_message({:error, {:unfinished, %Issue{identifier: identifier, task: nil}}}, _workflow),
    do: "opened nothing: #{identifier} is still unfinished and has no task yet. You can start it from its page."

  defp run_message({:error, {:unfinished, %Issue{identifier: identifier}}}, _workflow),
    do: "opened nothing: #{identifier} is still unfinished."

  defp run_message({:error, :project_inactive}, workflow), do: "opened nothing: #{workflow.project.key} is inactive."
  defp run_message({:error, :invalid}, _workflow), do: "opened nothing: its file is invalid."
  defp run_message({:error, reason}, _workflow), do: "opened nothing: #{inspect(reason)}"
end
