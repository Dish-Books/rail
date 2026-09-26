defmodule RailWeb.Settings.ProjectsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Slack
  alias Rail.Users

  def mount(_params, _session, socket) do
    projects = Projects.list_projects()
    linear_workspaces = Projects.list_linear_workspaces()
    {:ok, users} = Users.list_users(socket.assigns.current_scope)

    socket =
      socket
      |> assign(:page_title, "Projects")
      |> assign(:current_section, :projects)
      |> assign(:projects, projects)
      |> assign(:linear_workspaces, linear_workspaces)
      |> assign(:users, users)
      |> assign(:slack_channel_options, [])
      |> assign(:channel_selection, %{})
      |> assign(:channels_saved, false)
      |> assign(:channels_error, nil)
      |> assign(:show_modal, nil)
      |> assign(:modal_title, nil)
      |> assign(:selected_project, nil)
      |> assign(:changeset, nil)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket = assign(socket, :page_title, "Projects")
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="projects-settings">
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Projects
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Manage repositories, Linear team links, and project configurations.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:projects} />

        <div class="flex items-center justify-between">
          <div>
            <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">
              Registered Projects
            </h2>
            <p class="text-xs text-slate-500 dark:text-slate-400">
              All codebases configured for agent runs.
            </p>
          </div>
          <button
            type="button"
            phx-click="new_project"
            id="new-project-button"
            class="rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600"
          >
            New Project
          </button>
        </div>

        <!-- Projects List -->
        <section
          class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden"
          id="projects-list-section"
        >
          <div
            :if={Enum.empty?(@projects)}
            class="p-8 text-center text-slate-500 dark:text-slate-400 text-sm"
            id="empty-projects-message"
          >
            No projects registered yet. Click "New Project" to add one.
          </div>

          <ul
            :if={not Enum.empty?(@projects)}
            role="list"
            class="divide-y divide-slate-200 dark:divide-slate-700"
            id="projects-list"
          >
            <li
              :for={project <- @projects}
              class="p-6 flex items-center justify-between hover:bg-slate-100 dark:hover:bg-slate-700"
              id={"project-item-#{project.id}"}
            >
              <div class="space-y-1">
                <div class="flex items-center space-x-3">
                  <span
                    class="text-base font-semibold text-slate-900 dark:text-slate-100"
                    id={"project-name-#{project.id}"}
                  >
                    {project.name}
                  </span>
                  <span
                    :if={project.active}
                    class="inline-flex items-center rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-inset ring-green-600/20"
                    id={"project-status-#{project.id}"}
                  >
                    Active
                  </span>
                  <span
                    :if={!project.active}
                    class="inline-flex items-center rounded-md bg-slate-100 dark:bg-slate-700 px-2 py-1 text-xs font-medium text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-zinc-500/20"
                    id={"project-status-#{project.id}"}
                  >
                    Inactive
                  </span>
                </div>
                <div class="flex items-center space-x-4 text-xs text-slate-500 dark:text-slate-400">
                  <span id={"project-repo-#{project.id}"}>
                    Repo:
                    <span class="font-mono text-slate-900 dark:text-slate-100">{project.github_repo}</span>
                  </span>
                  <span>•</span>
                  <span id={"project-team-key-#{project.id}"}>
                    Team Key:
                    <span class="font-semibold text-slate-900 dark:text-slate-100">{project.linear_team_key}</span>
                  </span>
                  <span>•</span>
                  <span id={"project-branch-#{project.id}"}>
                    Branch:
                    <span class="font-mono text-slate-900 dark:text-slate-100">{project.default_branch}</span>
                  </span>
                </div>
              </div>

              <div>
                <.button
                  size="sm"
                  phx-click="edit_project"
                  phx-value-project_id={project.id}
                  id={"edit-project-#{project.id}"}
                >
                  <.icon name="pi-pencil-simple" class="h-3.5 w-3.5" /> Edit
                </.button>
              </div>
            </li>
          </ul>
        </section>

        <!-- Project Modal -->
        <div
          :if={@show_modal}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="project-modal"
        >
          <div class="w-full max-w-xl rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-6">
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-4">
              <h2 class="text-lg font-semibold text-slate-900 dark:text-slate-100" id="modal-title">
                {@modal_title}
              </h2>
              <button
                type="button"
                phx-click="close_modal"
                id="close-modal-button"
                class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 font-bold"
              >
                ✕
              </button>
            </div>

            <.form
              for={@changeset}
              id="project-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <div>
                <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Project Name</label>
                <input
                  type="text"
                  name="project[name]"
                  id="project-name-input"
                  value={Ecto.Changeset.get_field(@changeset, :name)}
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <span
                  :if={@changeset.errors[:name]}
                  class="text-xs text-red-600"
                  id="project-name-error"
                >
                  {elem(@changeset.errors[:name], 0)}
                </span>
              </div>

              <div>
                <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">GitHub Repository</label>
                <input
                  type="text"
                  name="project[github_repo]"
                  id="project-github-repo-input"
                  value={Ecto.Changeset.get_field(@changeset, :github_repo)}
                  placeholder="owner/repository"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <span
                  :if={@changeset.errors[:github_repo]}
                  class="text-xs text-red-600"
                  id="project-github-repo-error"
                >
                  {elem(@changeset.errors[:github_repo], 0)}
                </span>
              </div>

              <div class="grid grid-cols-2 gap-4">
                <div>
                  <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Installation ID</label>
                  <input
                    type="number"
                    name="project[github_installation_id]"
                    id="project-installation-id-input"
                    value={Ecto.Changeset.get_field(@changeset, :github_installation_id)}
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                  <span
                    :if={@changeset.errors[:github_installation_id]}
                    class="text-xs text-red-600"
                    id="project-installation-id-error"
                  >
                    {elem(@changeset.errors[:github_installation_id], 0)}
                  </span>
                </div>

                <div>
                  <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Default Branch</label>
                  <input
                    type="text"
                    name="project[default_branch]"
                    id="project-default-branch-input"
                    value={Ecto.Changeset.get_field(@changeset, :default_branch)}
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                  <span
                    :if={@changeset.errors[:default_branch]}
                    class="text-xs text-red-600"
                    id="project-default-branch-error"
                  >
                    {elem(@changeset.errors[:default_branch], 0)}
                  </span>
                </div>
              </div>

              <div>
                <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Linear Team Key</label>
                <input
                  type="text"
                  name="project[linear_team_key]"
                  id="project-linear-team-key-input"
                  value={Ecto.Changeset.get_field(@changeset, :linear_team_key)}
                  placeholder="e.g. DIS"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <span
                  :if={@changeset.errors[:linear_team_key]}
                  class="text-xs text-red-600"
                  id="project-linear-team-key-error"
                >
                  {elem(@changeset.errors[:linear_team_key], 0)}
                </span>
              </div>

              <div>
                <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Clone Path</label>
                <input
                  type="text"
                  name="project[clone_path]"
                  id="project-clone-path-input"
                  value={Ecto.Changeset.get_field(@changeset, :clone_path)}
                  placeholder="/path/to/local/clone"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <span
                  :if={@changeset.errors[:clone_path]}
                  class="text-xs text-red-600"
                  id="project-clone-path-error"
                >
                  {elem(@changeset.errors[:clone_path], 0)}
                </span>
              </div>

              <div>
                <label
                  for="project-worktree-setup-script-input"
                  class="block text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  Worktree Setup Script
                </label>
                <input
                  type="text"
                  name="project[worktree_setup_script]"
                  id="project-worktree-setup-script-input"
                  value={Ecto.Changeset.get_field(@changeset, :worktree_setup_script)}
                  placeholder="scripts/setup-worktree.sh"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                  Runs once in each new worktree, from its root, before any agent starts there.
                  RAIL_WORKTREE_SLOT and RAIL_PORT_BASE say which ports are its own.
                </p>
                <span
                  :if={@changeset.errors[:worktree_setup_script]}
                  class="text-xs text-red-600"
                  id="project-worktree-setup-script-error"
                >
                  {elem(@changeset.errors[:worktree_setup_script], 0)}
                </span>
              </div>

              <div class="grid grid-cols-3 gap-4">
                <div class="col-span-2">
                  <label
                    for="project-ci-command-input"
                    class="block text-sm font-medium text-slate-900 dark:text-slate-100"
                  >
                    CI Command
                  </label>
                  <input
                    type="text"
                    name="project[ci_command]"
                    id="project-ci-command-input"
                    value={Ecto.Changeset.get_field(@changeset, :ci_command)}
                    placeholder="mise run ci"
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm font-mono focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                </div>
                <div>
                  <label
                    for="project-ci-timeout-input"
                    class="block text-sm font-medium text-slate-900 dark:text-slate-100"
                  >
                    Timeout (minutes)
                  </label>
                  <input
                    type="number"
                    min="1"
                    name="project[ci_timeout_minutes]"
                    id="project-ci-timeout-input"
                    value={Ecto.Changeset.get_field(@changeset, :ci_timeout_minutes)}
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                </div>
                <p class="col-span-3 -mt-2 text-xs text-slate-500 dark:text-slate-400">
                  Runs in the worktree on every commit the engineer finishes. A failure goes back to the engineer,
                  and a change goes to review only once it passes. Leave empty to skip CI.
                </p>
                <span
                  :if={@changeset.errors[:ci_timeout_minutes]}
                  class="col-span-3 text-xs text-red-600"
                  id="project-ci-timeout-error"
                >
                  {elem(@changeset.errors[:ci_timeout_minutes], 0)}
                </span>
              </div>

              <div class="flex items-center space-x-2 pt-2">
                <input type="hidden" name="project[active]" value="false" />
                <input
                  type="checkbox"
                  name="project[active]"
                  id="project-active-input"
                  value="true"
                  checked={Ecto.Changeset.get_field(@changeset, :active) == true}
                  class="h-4 w-4 rounded border-slate-200 dark:border-slate-700 text-indigo-600 focus:ring-indigo-500"
                />
                <label
                  for="project-active-input"
                  class="text-sm text-slate-900 dark:text-slate-100 font-medium"
                >
                  Active project
                </label>
              </div>

              <div class="pt-4 border-t border-slate-200 dark:border-slate-700">
                <label
                  for="project-linear-workspace-input"
                  class="block text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  Linear Workspace
                </label>
                <select
                  name="project[linear_workspace_id]"
                  id="project-linear-workspace-input"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                >
                  <option value="">None</option>
                  <option
                    :for={workspace <- @linear_workspaces}
                    value={workspace.id}
                    selected={
                      Ecto.Changeset.get_field(@changeset, :linear_workspace_id) == workspace.id
                    }
                  >
                    {workspace.name}
                  </option>
                </select>
                <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                  Its credentials sync this project's team.
                  <.link
                    navigate={~p"/settings/linear-workspaces"}
                    class="text-indigo-600 hover:underline"
                  >
                    Manage Linear workspaces
                  </.link>
                </p>
                <span
                  :if={@changeset.errors[:linear_workspace_id]}
                  class="text-xs text-red-600"
                  id="project-linear-workspace-error"
                >
                  {elem(@changeset.errors[:linear_workspace_id], 0)}
                </span>
              </div>

              <div class="pt-4 border-t border-slate-200 dark:border-slate-700">
                <label
                  for="project-triage-user-input"
                  class="block text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  Triage uses the MCP connections of
                </label>
                <select
                  name="project[triage_user_id]"
                  id="project-triage-user-input"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                >
                  <option value="">Nobody, triage reads the code alone</option>
                  <option
                    :for={user <- @users}
                    value={user.id}
                    selected={Ecto.Changeset.get_field(@changeset, :triage_user_id) == user.id}
                  >
                    {user.name || user.login}
                  </option>
                </select>
                <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                  A triage pass calls the MCP tools its role allows on this person's connections.
                </p>
              </div>

              <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
                <.button phx-click="close_modal" id="cancel-project-button">
                  Cancel
                </.button>
                <.button variant="primary" type="submit" id="save-project-button">
                  Save
                </.button>
              </div>
            </.form>

            <.form
              :if={@show_modal == :edit}
              for={%{}}
              as={:channels}
              id="slack-channels-form"
              phx-change="change_channels"
              phx-submit="save_channels"
              class="space-y-3 pt-4 border-t border-slate-200 dark:border-slate-700"
            >
              <div class="flex items-center justify-between">
                <p class="text-sm font-medium text-slate-900 dark:text-slate-100">Slack channels</p>
                <span
                  :if={@channels_saved}
                  id="slack-channels-saved"
                  class="text-xs text-emerald-600 dark:text-emerald-400"
                >
                  Saved
                </span>
              </div>
              <p
                :if={@slack_channel_options == []}
                id="slack-channels-empty"
                class="text-xs text-slate-500 dark:text-slate-400"
              >
                No channels to pick from. Add a Slack workspace in
                <.link
                  navigate={~p"/settings/slack-workspaces"}
                  class="text-indigo-600 hover:underline"
                >
                  Slack settings
                </.link>
                and invite its app to the channels triage should read.
              </p>
              <ul :if={@slack_channel_options != []} class="max-h-56 overflow-y-auto space-y-1.5">
                <li :for={channel <- @slack_channel_options} class="flex items-center gap-3 text-sm">
                  <input type="hidden" name={"channels[#{channel.id}][included]"} value="false" />
                  <input
                    type="checkbox"
                    name={"channels[#{channel.id}][included]"}
                    id={"slack-channel-#{channel.id}"}
                    value="true"
                    checked={Map.has_key?(@channel_selection, channel.id)}
                    class="h-4 w-4 rounded border-slate-200 dark:border-slate-700 text-indigo-600 focus:ring-indigo-500"
                  />
                  <label
                    for={"slack-channel-#{channel.id}"}
                    class="font-mono text-slate-900 dark:text-slate-100"
                  >
                    #{channel.name}
                  </label>
                  <label
                    :if={Map.has_key?(@channel_selection, channel.id)}
                    class="ml-auto inline-flex items-center gap-2 text-xs text-slate-600 dark:text-slate-300 cursor-pointer"
                  >
                    <input
                      type="hidden"
                      name={"channels[#{channel.id}][triage_bot_messages]"}
                      value="false"
                    />
                    <input
                      type="checkbox"
                      role="switch"
                      name={"channels[#{channel.id}][triage_bot_messages]"}
                      id={"slack-channel-bots-#{channel.id}"}
                      value="true"
                      checked={Map.get(@channel_selection, channel.id) == true}
                      class="peer sr-only"
                    />
                    <span class="relative h-5 w-9 shrink-0 rounded-full bg-slate-300 dark:bg-slate-600 transition-colors peer-checked:bg-indigo-600 after:absolute after:top-0.5 after:left-0.5 after:size-4 after:rounded-full after:bg-white after:transition-transform peer-checked:after:translate-x-4"></span>
                    Triage bot messages
                  </label>
                </li>
              </ul>
              <p
                :if={map_size(@channel_selection) > 0}
                class="text-xs text-slate-500 dark:text-slate-400"
              >
                For channels where tools such as PostHog report issues.
              </p>
              <p :if={@channels_error} id="slack-channels-error" class="text-xs text-red-600">
                {@channels_error}
              </p>
              <div :if={@slack_channel_options != []} class="flex justify-end">
                <.button type="submit" id="save-slack-channels-button">Save channels</.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("new_project", _params, socket) do
    changeset = Project.changeset(%Project{}, %{"default_branch" => "main", "active" => true})

    socket =
      socket
      |> assign(:show_modal, :new)
      |> assign(:modal_title, "New Project")
      |> assign(:selected_project, nil)
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("edit_project", %{"project_id" => project_id}, socket) do
    case Projects.get_project(project_id) do
      {:ok, project} ->
        changeset = Project.changeset(project, %{})

        socket =
          socket
          |> assign(:slack_channel_options, slack_channel_options())
          |> assign(
            :channel_selection,
            Map.new(Projects.list_slack_channels(project), &{&1.external_id, &1.triage_bot_messages})
          )
          |> assign(:channels_saved, false)
          |> assign(:channels_error, nil)
          |> assign(:show_modal, :edit)
          |> assign(:modal_title, "Edit Project")
          |> assign(:selected_project, project)
          |> assign(:changeset, changeset)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("change_channels", params, socket) do
    socket =
      socket
      |> assign(:channel_selection, channel_selection(params))
      |> assign(:channels_saved, false)

    {:noreply, socket}
  end

  def handle_event("save_channels", params, socket) do
    selection = channel_selection(params)
    entries = Enum.map(selection, fn {id, bots?} -> %{"external_id" => id, "triage_bot_messages" => bots?} end)

    case Projects.set_slack_channels(socket.assigns.current_scope, socket.assigns.selected_project, entries) do
      {:ok, _channels} ->
        socket =
          socket
          |> assign(:channel_selection, selection)
          |> assign(:channels_saved, true)
          |> assign(:channels_error, nil)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :channels_error, channel_error(changeset))}

      {:error, :channel_not_found} ->
        {:noreply, assign(socket, :channels_error, "A channel picked is no longer in Slack.")}
    end
  end

  def handle_event("close_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, nil)
      |> assign(:modal_title, nil)
      |> assign(:selected_project, nil)
      |> assign(:changeset, nil)

    {:noreply, socket}
  end

  def handle_event("validate", %{"project" => params}, socket) do
    target = socket.assigns.selected_project || %Project{}

    changeset =
      target
      |> Project.changeset(params)
      |> Map.put(:action, :validate)

    socket = assign(socket, :changeset, changeset)
    {:noreply, socket}
  end

  def handle_event("save", %{"project" => params}, socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.show_modal do
      :new ->
        case Projects.create_project(scope, params) do
          {:ok, project} ->
            projects = update_list_item(socket.assigns.projects, project)

            socket =
              socket
              |> assign(:projects, projects)
              |> assign(:show_modal, nil)
              |> assign(:modal_title, nil)
              |> assign(:selected_project, nil)
              |> assign(:changeset, nil)

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            socket = assign(socket, :changeset, changeset)
            {:noreply, socket}
        end

      :edit ->
        project = socket.assigns.selected_project

        case Projects.update_project(scope, project, params) do
          {:ok, updated_project} ->
            projects = update_list_item(socket.assigns.projects, updated_project)

            socket =
              socket
              |> assign(:projects, projects)
              |> assign(:show_modal, nil)
              |> assign(:modal_title, nil)
              |> assign(:selected_project, nil)
              |> assign(:changeset, nil)

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            socket = assign(socket, :changeset, changeset)
            {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  # Each workspace is asked for its channels; one Slack cannot answer for adds nothing to pick.
  defp slack_channel_options do
    Enum.flat_map(Projects.list_slack_workspaces(), fn workspace ->
      case Slack.list_channels(workspace) do
        {:ok, channels} -> Enum.map(channels, &%{id: &1["id"], name: &1["name"]})
        {:error, _unreachable} -> []
      end
    end)
  end

  defp channel_selection(params) do
    for {id, %{"included" => "true"} = channel} <- Map.get(params, "channels", %{}), into: %{} do
      {id, channel["triage_bot_messages"] == "true"}
    end
  end

  defp channel_error(changeset) do
    changeset.errors
    |> Keyword.get_values(:external_id)
    |> Enum.map_join(", ", &elem(&1, 0))
    |> then(&"This channel #{&1}.")
  end

  defp update_list_item(items, %{id: id} = item) do
    if Enum.any?(items, fn current -> current.id == id end) do
      Enum.map(items, fn
        %{id: ^id} -> item
        other -> other
      end)
    else
      [item | items]
    end
  end
end
