defmodule RailWeb.SandboxesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  # Usage is read from Docker, which takes a moment per container, so it is
  # re-read on its own clock rather than with everything else.
  @usage_interval_ms 5_000
  @preload [:stopped_by, run: [:role, :os_processes, task: :issue]]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")

    socket =
      socket
      |> assign(:page_title, "Sandboxes")
      |> assign(:current_section, :sandboxes)
      |> assign(:usage, %{})
      |> load_sandboxes()
      |> read_usage()

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div id="sandboxes-view" data-qa="sandboxes-view" class="space-y-6">
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Sandboxes
          </h1>
          <p id="sandboxes-intro" class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Every agent turn, worktree setup and CI command runs in its own sandbox on this machine, holding what its role reserves.
          </p>
        </div>

        <.sandbox_stats :if={@stats} stats={@stats} />
        <p
          :if={!@stats}
          id="sandbox-capacity-unknown"
          class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-4 text-sm text-slate-500 dark:text-slate-400"
        >
          Rail could not read what this machine has, so nothing new starts until it can.
        </p>

        <section>
          <h2
            id="waiting-sandboxes-title"
            class="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400"
          >
            Waiting for resources · oldest first
          </h2>
          <div class="rounded-xl border border-slate-200 dark:border-slate-700/70 overflow-x-auto">
            <table id="waiting-sandboxes" class="w-full">
              <thead class="bg-slate-50 dark:bg-slate-800/40">
                <tr>
                  <.th>Line</.th>
                  <.th>Task</.th>
                  <.th>Role</.th>
                  <.th>For</.th>
                  <.th>Needs</.th>
                  <.th>Short of</.th>
                  <.th>Waiting</.th>
                  <.th />
                </tr>
              </thead>
              <tbody>
                <tr :if={@waiting == []}>
                  <td colspan="8" class="px-4 py-4 text-sm text-slate-500 dark:text-slate-400">
                    Nothing is waiting for resources.
                  </td>
                </tr>
                <tr
                  :for={{sandbox, position} <- Enum.with_index(@waiting, 1)}
                  id={"waiting-#{sandbox.id}"}
                  class="border-t border-slate-200 dark:border-slate-700/70"
                >
                  <td class="whitespace-nowrap px-4 py-2.5">
                    <span
                      data-qa="line"
                      class="inline-flex items-center gap-1.5 font-mono text-xs font-semibold text-violet-600 dark:text-violet-400"
                    >
                      <.icon name="pi-hourglass-medium" class="size-3.5" />{format_ordinal(position)}
                    </span>
                  </td>
                  <td class="px-4 py-2.5"><.task_cell sandbox={sandbox} /></td>
                  <td class="whitespace-nowrap px-4 py-2.5 text-sm text-slate-800 dark:text-slate-200">
                    {sandbox.run.role.name}
                  </td>
                  <td
                    data-qa="for"
                    class="whitespace-nowrap px-4 py-2.5 text-xs text-slate-500 dark:text-slate-400"
                  >
                    {sandbox_for(sandbox)}
                  </td>
                  <td
                    data-qa="needs"
                    class="whitespace-nowrap px-4 py-2.5 font-mono text-xs text-slate-700 dark:text-slate-300"
                  >
                    {format_reservation(sandbox)}
                  </td>
                  <td
                    data-qa="short-of"
                    class="whitespace-nowrap px-4 py-2.5 font-mono text-xs text-slate-700 dark:text-slate-300"
                  >
                    {short_of(sandbox, @free)}
                  </td>
                  <td class="whitespace-nowrap px-4 py-2.5 font-mono text-xs text-slate-500 dark:text-slate-400">
                    <span
                      id={"waiting-for-#{sandbox.id}"}
                      phx-hook="Elapsed"
                      data-started-at={DateTime.to_iso8601(sandbox.queued_at)}
                      data-elapsed-seconds="0"
                    >
                      {format_duration(DateTime.diff(@now, sandbox.queued_at))}
                    </span>
                  </td>
                  <td class="whitespace-nowrap px-4 py-2.5 text-right">
                    <.stop_button run_id={sandbox.run_id} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section>
          <h2
            id="running-sandboxes-title"
            class="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400"
          >
            Running · {length(@running)}
          </h2>
          <div class="rounded-xl border border-slate-200 dark:border-slate-700/70 overflow-x-auto">
            <table id="running-sandboxes" class="w-full">
              <thead class="bg-slate-50 dark:bg-slate-800/40">
                <tr>
                  <.th>Task</.th>
                  <.th>Role</.th>
                  <.th>For</.th>
                  <.th>Reserved</.th>
                  <.th>CPU in use</.th>
                  <.th>Memory in use</.th>
                  <.th>Running</.th>
                  <.th />
                </tr>
              </thead>
              <tbody>
                <tr :if={@running == []}>
                  <td colspan="8" class="px-4 py-4 text-sm text-slate-500 dark:text-slate-400">
                    No sandbox is running.
                  </td>
                </tr>
                <tr
                  :for={sandbox <- @running}
                  id={"running-#{sandbox.id}"}
                  class="border-t border-slate-200 dark:border-slate-700/70"
                >
                  <td class="px-4 py-2.5"><.task_cell sandbox={sandbox} /></td>
                  <td class="whitespace-nowrap px-4 py-2.5 text-sm text-slate-800 dark:text-slate-200">
                    {sandbox.run.role.name}
                  </td>
                  <td
                    data-qa="for"
                    class="whitespace-nowrap px-4 py-2.5 text-xs text-slate-500 dark:text-slate-400"
                  >
                    {sandbox_for(sandbox)}
                  </td>
                  <td
                    data-qa="reserved"
                    class="whitespace-nowrap px-4 py-2.5 font-mono text-xs text-slate-700 dark:text-slate-300"
                  >
                    {format_reservation(sandbox)}
                  </td>
                  <td class="whitespace-nowrap px-4 py-2.5">
                    <.sandbox_usage_meter
                      id={"cpu-in-use-#{sandbox.id}"}
                      data-qa="cpu-in-use"
                      used={@usage[sandbox.id] && @usage[sandbox.id].cpus}
                      reserved={sandbox.reserved_cpus}
                      unit="CPU"
                    />
                  </td>
                  <td class="whitespace-nowrap px-4 py-2.5">
                    <.sandbox_usage_meter
                      id={"memory-in-use-#{sandbox.id}"}
                      data-qa="memory-in-use"
                      used={@usage[sandbox.id] && @usage[sandbox.id].memory_gb}
                      reserved={sandbox.reserved_memory_gb}
                      unit="GB"
                    />
                  </td>
                  <td
                    data-qa="running-for"
                    class="whitespace-nowrap px-4 py-2.5 font-mono text-xs text-slate-500 dark:text-slate-400"
                  >
                    {format_age(DateTime.diff(@now, sandbox.started_at))}
                  </td>
                  <td class="whitespace-nowrap px-4 py-2.5 text-right">
                    <.stop_button run_id={sandbox.run_id} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section>
          <h2 class="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
            Ended · last hour
          </h2>
          <div class="rounded-xl border border-slate-200 dark:border-slate-700/70 overflow-x-auto">
            <table id="ended-sandboxes" class="w-full">
              <thead class="bg-slate-50 dark:bg-slate-800/40">
                <tr>
                  <.th>Task</.th>
                  <.th>Role</.th>
                  <.th>For</.th>
                  <.th>How it ended</.th>
                  <.th>Freed</.th>
                  <.th>Ended</.th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@ended == []}>
                  <td colspan="6" class="px-4 py-4 text-sm text-slate-500 dark:text-slate-400">
                    No sandbox ended in the last hour.
                  </td>
                </tr>
                <tr
                  :for={sandbox <- @ended}
                  id={"ended-#{sandbox.id}"}
                  class="border-t border-slate-200 dark:border-slate-700/70"
                >
                  <% ending = ending(sandbox) %>
                  <td class="px-4 py-2.5"><.task_cell sandbox={sandbox} /></td>
                  <td class="whitespace-nowrap px-4 py-2.5 text-sm text-slate-800 dark:text-slate-200">
                    {sandbox.run.role.name}
                  </td>
                  <td
                    data-qa="for"
                    class="whitespace-nowrap px-4 py-2.5 text-xs text-slate-500 dark:text-slate-400"
                  >
                    {sandbox_for(sandbox)}
                  </td>
                  <td class="whitespace-nowrap px-4 py-2.5">
                    <span
                      data-qa="ended-how"
                      class={["inline-flex items-center gap-1.5 text-xs font-semibold", ending.class]}
                    >
                      <.icon name={ending.icon} class="size-3.5" />{ending.label}
                    </span>
                  </td>
                  <td
                    data-qa="freed"
                    class="whitespace-nowrap px-4 py-2.5 font-mono text-xs text-slate-700 dark:text-slate-300"
                  >
                    {format_reservation(sandbox)}
                  </td>
                  <td class="whitespace-nowrap px-4 py-2.5 font-mono text-xs text-slate-500 dark:text-slate-400">
                    <.clock id={"ended-at-#{sandbox.id}"} at={sandbox.ended_at} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="mt-2 text-xs text-slate-500 dark:text-slate-400">
            Whatever a sandbox ends with, its run settles with everything it wrote, and what it held goes to the front of the line at once.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("stop", %{"run_id" => run_id}, socket) do
    {:ok, run} = Pipeline.get_run(run_id)
    {:ok, _stopped, _queued} = Pipeline.stop_run(socket.assigns.current_scope, run)
    {:noreply, load_sandboxes(socket)}
  end

  def handle_info(:sandboxes_changed, socket), do: {:noreply, load_sandboxes(socket)}
  def handle_info(:read_usage, socket), do: {:noreply, read_usage(socket)}

  def handle_async(:usage, {:ok, usage}, socket) do
    Process.send_after(self(), :read_usage, @usage_interval_ms)
    {:noreply, assign(socket, :usage, usage)}
  end

  attr :sandbox, OsProcess, required: true

  defp task_cell(assigns) do
    ~H"""
    <.link
      navigate={~p"/tasks/#{@sandbox.task_id}"}
      class="flex items-center gap-2 min-w-0 hover:underline"
    >
      <span class="font-mono text-xs text-slate-500 dark:text-slate-400 w-20 shrink-0 truncate">
        {@sandbox.run.task.issue.identifier}
      </span>
      <span class="truncate text-sm text-slate-800 dark:text-slate-200 max-w-[24rem]">
        {@sandbox.run.task.issue.title}
      </span>
    </.link>
    """
  end

  attr :run_id, :string, required: true

  defp stop_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="stop"
      phx-value-run_id={@run_id}
      class="inline-flex items-center gap-1 px-2 py-1 rounded-md text-xs font-semibold text-slate-500 dark:text-slate-400 hover:bg-red-500/10 hover:text-red-600 dark:hover:text-red-400 cursor-pointer"
    >
      <.icon name="pi-stop-fill" class="size-3" />Stop
    </button>
    """
  end

  slot :inner_block

  defp th(assigns) do
    ~H"""
    <th class="whitespace-nowrap px-4 py-2.5 text-left text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
      {render_slot(@inner_block)}
    </th>
    """
  end

  attr :id, :string, required: true
  attr :at, DateTime, required: true

  defp clock(assigns) do
    ~H"""
    <span id={@id} phx-hook="LocalTime" data-at={DateTime.to_iso8601(@at)}>{Calendar.strftime(
      @at,
      "%H:%M"
    )}</span>
    """
  end

  # The whole machine, whichever project is picked: capacity is shared.
  defp load_sandboxes(socket) do
    now = DateTime.utc_now()

    capacity =
      case Tools.get_sandbox_capacity() do
        {:ok, capacity} -> capacity
        _unknown -> nil
      end

    waiting = Tools.list_os_processes(status: [:waiting_for_resources], order: :queue, preload: @preload)

    running =
      [status: [:starting, :running], sandboxed: true, preload: @preload]
      |> Tools.list_os_processes()
      |> Enum.sort_by(& &1.started_at, DateTime)

    ended = Tools.list_os_processes(ended_after: DateTime.shift(now, hour: -1), sandboxed: true, preload: @preload)

    free =
      capacity &&
        %{cpus: capacity.cpus - capacity.reserved_cpus, memory_gb: capacity.memory_gb - capacity.reserved_memory_gb}

    socket
    |> assign(:now, now)
    |> assign(:free, free)
    |> assign(:waiting, waiting)
    |> assign(:running, running)
    |> assign(:ended, ended)
    |> assign(:stats, capacity && stats(capacity, free, running, waiting, now))
  end

  defp read_usage(socket) do
    if connected?(socket), do: start_async(socket, :usage, &Tools.list_sandbox_usage/0), else: socket
  end

  defp stats(capacity, free, running, waiting, now) do
    kinds = Enum.frequencies_by(running, & &1.kind)
    shorts = Enum.map(waiting, &OsProcess.short_of(&1, free))
    short_on = %{cpus: Enum.any?(shorts, &(&1.cpus > 0)), memory: Enum.any?(shorts, &(&1.memory_gb > 0))}

    capacity
    |> Map.take([:cpus, :memory_gb, :reserved_cpus, :reserved_memory_gb])
    |> Map.merge(%{
      running: length(running),
      agent_turns: Map.get(kinds, :agent, 0),
      setups: Map.get(kinds, :setup, 0),
      cis: Map.get(kinds, :ci, 0),
      waiting: length(waiting),
      oldest_waiting: oldest_waiting(waiting, now),
      short_on: short_on
    })
  end

  defp oldest_waiting([], _now), do: nil
  defp oldest_waiting([oldest | _rest], now), do: format_duration(DateTime.diff(now, oldest.queued_at))

  # A turn is numbered among its run's turns, as its conversation numbers it.
  defp sandbox_for(%OsProcess{kind: :setup}), do: "Setup"
  defp sandbox_for(%OsProcess{kind: :ci}), do: "CI"

  defp sandbox_for(%OsProcess{kind: :agent, run: %Run{os_processes: os_processes}} = sandbox) do
    turn =
      os_processes
      |> Enum.filter(&(&1.kind == :agent))
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.find_index(&(&1.id == sandbox.id))

    "Turn #{turn + 1}"
  end

  defp short_of(%OsProcess{} = sandbox, free) when is_map(free) do
    case OsProcess.short_of(sandbox, free) do
      %{cpus: 0, memory_gb: 0} -> "—"
      %{cpus: 0, memory_gb: memory_gb} -> "#{memory_gb} GB"
      %{cpus: cpus, memory_gb: 0} -> "#{cpus} #{if cpus == 1, do: "CPU", else: "CPUs"}"
      short -> format_reservation(%{reserved_cpus: short.cpus, reserved_memory_gb: short.memory_gb})
    end
  end

  defp short_of(%OsProcess{}, nil), do: "—"

  @finished "text-emerald-600 dark:text-emerald-400"
  @failed "text-red-600 dark:text-red-400"
  @stopped "text-slate-600 dark:text-slate-300"

  defp ending(%OsProcess{ended_reason: :finished}), do: %{label: "Finished", icon: "pi-check-circle", class: @finished}

  defp ending(%OsProcess{ended_reason: :out_of_memory} = sandbox),
    do: %{label: "Killed · used more than its #{sandbox.reserved_memory_gb} GB", icon: "pi-x-circle", class: @failed}

  defp ending(%OsProcess{ended_reason: :killed}), do: %{label: "Killed", icon: "pi-x-circle", class: @failed}
  defp ending(%OsProcess{ended_reason: :timed_out}), do: %{label: "Timed out", icon: "pi-clock", class: @failed}

  defp ending(%OsProcess{ended_reason: :failed_to_start}),
    do: %{label: "Could not start", icon: "pi-warning-circle", class: @failed}

  defp ending(%OsProcess{ended_reason: :stopped, stopped_by: %{name: name}}) when is_binary(name),
    do: %{label: "Stopped by #{name}", icon: "pi-pause-circle", class: @stopped}

  defp ending(%OsProcess{}), do: %{label: "Stopped", icon: "pi-pause-circle", class: @stopped}
end
