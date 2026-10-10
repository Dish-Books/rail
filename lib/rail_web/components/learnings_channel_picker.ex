defmodule RailWeb.Components.LearningsChannelPicker do
  @moduledoc """
  Picks the Slack channel a project's learnings digest posts in, saving the moment one is picked.
  `variant` is `:settings` for the Edit Project section or `:footer` for the Learnings page footer.
  """
  use RailWeb, :live_component

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Slack

  @doc """
  The learnings channel's current name, from Slack, or its id when Slack cannot name it. Nil when it posts nowhere.
  """
  def channel_name(%Project{learnings_channel_external_id: nil}), do: nil

  def channel_name(%Project{learnings_slack_workspace: workspace, learnings_channel_external_id: channel}) do
    case Slack.channel_info(workspace, channel) do
      {:ok, %{"name" => name}} when is_binary(name) -> name
      _unnamed -> channel
    end
  end

  @doc """
  Names the channel again only when `project` moved it from where `previous` had it as `name`.
  """
  def channel_name(%Project{} = project, %Project{} = previous, name) do
    if {project.learnings_slack_workspace_id, project.learnings_channel_external_id} ==
         {previous.learnings_slack_workspace_id, previous.learnings_channel_external_id},
       do: name,
       else: channel_name(project)
  end

  def mount(socket) do
    socket =
      socket
      |> assign(:open, false)
      |> assign(:query, "")
      |> assign(:groups, nil)
      |> assign(:shown, [])
      |> assign(:saved, false)

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:variant, assigns.variant)
      |> assign(:current_scope, assigns.current_scope)
      |> assign(:channel_name, assigns.channel_name)
      |> assign(:permalink, assigns[:permalink])
      |> assign_project(assigns.project)

    {:ok, socket}
  end

  def render(%{variant: :settings} = assigns) do
    ~H"""
    <div id={@id} class="pt-4 border-t border-slate-200 dark:border-slate-700 space-y-1">
      <div class="flex items-center justify-between">
        <p class="text-sm font-medium text-slate-900 dark:text-slate-100">Learnings digest</p>
        <span :if={@saved} id={"#{@id}-saved"} class="text-xs text-emerald-600 dark:text-emerald-400">
          Saved
        </span>
      </div>
      <div class="relative" phx-click-away={@open && "close"} phx-target={@myself}>
        <button
          type="button"
          id={"#{@id}-trigger"}
          phx-click="toggle"
          phx-target={@myself}
          aria-expanded={to_string(@open)}
          class={[
            "mt-1 w-full flex items-center gap-2 rounded-md border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 px-2.5 py-1.5 text-sm text-slate-900 dark:text-slate-100 min-w-0 cursor-pointer",
            @open && "ring-2 ring-indigo-500"
          ]}
        >
          <.icon name="pi-slack-logo" class="size-4 text-slate-400" />
          <span :if={@show_channel} class="font-mono truncate">#{@channel_name}</span>
          <span
            :if={@show_channel}
            class="shrink-0 max-w-[40%] truncate text-xs text-slate-500 dark:text-slate-400"
          >
            {@project.learnings_slack_workspace.name}
          </span>
          <span :if={!@show_channel} class="truncate">Don't post</span>
          <.icon name="pi-caret-up-down" class="ml-auto size-4 text-slate-400" />
        </button>
        <div :if={@open} class="mt-1">
          <.options
            id={@id}
            myself={@myself}
            query={@query}
            shown={@shown}
            project={@project}
            show_channel={@show_channel}
            class="w-full"
          />
        </div>
      </div>
      <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
        The curator's 06:00 UTC digest. Saves when picked, and never triages the channel.
      </p>
    </div>
    """
  end

  def render(%{variant: :footer} = assigns) do
    ~H"""
    <div
      id={@id}
      class="relative ml-auto min-w-0 flex"
      phx-click-away={@open && "close"}
      phx-target={@myself}
    >
      <button
        :if={@show_channel}
        type="button"
        id={"#{@id}-trigger"}
        phx-click="toggle"
        phx-target={@myself}
        aria-expanded={to_string(@open)}
        title="Change where the digest posts"
        class={[
          "min-w-0 inline-flex items-center gap-1 whitespace-nowrap text-[11px] text-slate-500 dark:text-slate-400 rounded px-1 -mx-1 cursor-pointer hover:text-slate-900 dark:hover:text-slate-100",
          @open && "outline-2 outline-indigo-500"
        ]}
      >
        06:00 digest in
        <span class="truncate font-mono font-semibold text-blue-600 dark:text-blue-400">#{@channel_name}</span>
        <.icon name="pi-caret-up-down" class="size-3 text-slate-400" />
      </button>
      <button
        :if={!@show_channel}
        type="button"
        id={"#{@id}-trigger"}
        phx-click="toggle"
        phx-target={@myself}
        aria-expanded={to_string(@open)}
        class={[
          "inline-flex items-center gap-1 whitespace-nowrap text-[11px] text-slate-500 dark:text-slate-400 rounded px-1 -mx-1 cursor-pointer hover:text-slate-900 dark:hover:text-slate-100",
          @open && "outline-2 outline-indigo-500"
        ]}
      >
        <.icon name="pi-slack-logo" class="size-3" />Post digest to Slack
      </button>
      <div :if={@open} class="absolute bottom-full right-0 mb-2 z-30">
        <.options
          id={@id}
          myself={@myself}
          query={@query}
          shown={@shown}
          project={@project}
          show_channel={@show_channel}
          permalink={@permalink}
          class="w-72 max-w-[calc(100vw-2rem)]"
        />
      </div>
    </div>
    """
  end

  def handle_event("toggle", _params, %{assigns: %{open: true}} = socket), do: {:noreply, close(socket)}

  def handle_event("toggle", _params, socket) do
    socket = socket |> assign(:open, true) |> load_groups() |> assign_shown()
    {:noreply, socket}
  end

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("search", %{"q" => query}, socket) do
    socket = socket |> assign(:query, query) |> assign_shown()
    {:noreply, socket}
  end

  # Only a channel this picker listed can be saved, whatever the click sent.
  def handle_event("pick", params, socket) do
    picked =
      for %{workspace: workspace, channels: channels} <- socket.assigns.groups || [],
          workspace.id == params["workspace_id"],
          channel <- channels,
          channel.id == params["channel_id"],
          do: {workspace, channel}

    case {params, picked} do
      {%{"channel_id" => _id}, [{workspace, channel} | _rest]} ->
        attrs = %{"learnings_slack_workspace_id" => workspace.id, "learnings_channel_external_id" => channel.id}
        {:noreply, save(socket, attrs, channel.name)}

      {%{"channel_id" => _id}, []} ->
        {:noreply, socket}

      {_dont_post, []} ->
        attrs = %{"learnings_slack_workspace_id" => nil, "learnings_channel_external_id" => nil}
        {:noreply, save(socket, attrs, nil)}
    end
  end

  attr :id, :string, required: true
  attr :myself, :any, required: true
  attr :query, :string, required: true
  attr :shown, :list, required: true
  attr :project, :map, required: true
  attr :show_channel, :boolean, required: true
  attr :permalink, :string, default: nil
  attr :class, :string, required: true

  defp options(assigns) do
    ~H"""
    <div
      id={"#{@id}-options"}
      phx-window-keydown="close"
      phx-key="Escape"
      phx-target={@myself}
      class={[
        @class,
        "rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800 p-1 shadow-xl"
      ]}
    >
      <form
        id={"#{@id}-search-form"}
        class="relative m-1 mb-1.5"
        phx-change="search"
        phx-submit="search"
        phx-target={@myself}
      >
        <.icon
          name="pi-magnifying-glass"
          class="absolute left-2.5 top-1/2 -translate-y-1/2 size-4 text-slate-400"
        />
        <input
          type="search"
          id={"#{@id}-search"}
          name="q"
          value={@query}
          phx-debounce="150"
          phx-mounted={JS.focus()}
          autocomplete="off"
          placeholder="Find a channel"
          class="w-full pl-8 pr-3 py-1.5 text-[13px] rounded-lg border border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-500"
        />
      </form>
      <div class="max-h-64 overflow-y-auto">
        <button
          type="button"
          id={"#{@id}-none"}
          phx-click="pick"
          phx-target={@myself}
          class={[row_class(), "text-slate-700 dark:text-slate-200"]}
        >
          <.icon name="pi-prohibit" class="size-3.5 text-slate-400" />Don't post
          <span class="ml-auto shrink-0">
            <.icon
              :if={!@show_channel}
              name="pi-check-bold"
              class="size-3.5 text-indigo-500 dark:text-indigo-400"
            />
          </span>
        </button>
        <div :for={group <- @shown}>
          <div class="px-2.5 pt-2 pb-1 truncate text-[11px] font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            {group.workspace.name}
          </div>
          <button
            :for={channel <- group.channels}
            type="button"
            id={"#{@id}-channel-#{channel.id}"}
            phx-click="pick"
            phx-value-workspace_id={group.workspace.id}
            phx-value-channel_id={channel.id}
            phx-target={@myself}
            class={[row_class(), "font-mono text-slate-800 dark:text-slate-200 min-w-0"]}
          >
            <span class="truncate">#{channel.name}</span>
            <span class="ml-auto shrink-0">
              <.icon
                :if={
                  @project.learnings_slack_workspace_id == group.workspace.id and
                    @project.learnings_channel_external_id == channel.id
                }
                name="pi-check-bold"
                class="size-3.5 text-indigo-500 dark:text-indigo-400"
              />
            </span>
          </button>
        </div>
      </div>
      <.link
        :if={@permalink}
        href={@permalink}
        target="_blank"
        rel="noopener"
        id={"#{@id}-permalink"}
        class="mt-1 flex items-center gap-2 px-2.5 py-1.5 border-t border-slate-200 dark:border-slate-700 text-xs text-blue-600 dark:text-blue-400 hover:underline"
      >
        <.icon name="pi-arrow-square-out" class="size-3.5" />Open today's digest in Slack
      </.link>
    </div>
    """
  end

  defp save(socket, attrs, channel_name) do
    {:ok, project} = Projects.update_project(socket.assigns.current_scope, socket.assigns.project, attrs)

    socket
    |> assign_project(project)
    |> assign(:channel_name, channel_name)
    |> assign(:saved, true)
    |> close()
  end

  defp assign_project(socket, project) do
    socket
    |> assign(:project, project)
    |> assign(:show_channel, is_binary(project.learnings_channel_external_id))
  end

  defp close(socket), do: socket |> assign(:open, false) |> assign(:query, "")

  # Slack is asked once, on first open; a workspace it cannot list for adds no group. The digest names
  # tracker issues, so a channel triage marked as shared outside the team is never offered.
  defp load_groups(%{assigns: %{groups: nil}} = socket) do
    external = MapSet.new(Projects.list_slack_channels(external: true), &{&1.slack_workspace_id, &1.external_id})

    groups =
      Enum.flat_map(Projects.list_slack_workspaces(), fn workspace ->
        case Slack.list_channels(workspace) do
          {:ok, channels} ->
            channels =
              for channel <- channels, not MapSet.member?(external, {workspace.id, channel["id"]}) do
                %{id: channel["id"], name: channel["name"] || channel["id"]}
              end

            [%{workspace: workspace, channels: channels}]

          {:error, _unreachable} ->
            []
        end
      end)

    assign(socket, :groups, groups)
  end

  defp load_groups(socket), do: socket

  defp assign_shown(%{assigns: %{groups: groups, query: query}} = socket) do
    query = query |> String.trim() |> String.downcase()

    shown =
      for group <- groups || [],
          channels = Enum.filter(group.channels, &String.contains?(String.downcase(&1.name), query)),
          channels != [],
          do: %{group | channels: channels}

    assign(socket, :shown, shown)
  end

  defp row_class,
    do:
      "w-full flex items-center gap-2 px-2.5 py-1.5 rounded-md text-xs hover:bg-slate-100 dark:hover:bg-slate-700 focus-visible:bg-slate-100 dark:focus-visible:bg-slate-700/70 focus-visible:outline-2 focus-visible:outline-indigo-500 focus-visible:-outline-offset-2 cursor-pointer"
end
