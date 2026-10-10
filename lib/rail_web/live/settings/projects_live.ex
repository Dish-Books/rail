defmodule RailWeb.Settings.ProjectsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Slack
  alias Rail.Triage
  alias Rail.Users
  alias RailWeb.Components.LearningsChannelPicker

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "projects")

    projects = Projects.list_projects(socket.assigns.current_scope)
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
      |> assign(:channel_ids, %{})
      |> assign(:channels_confirm, nil)
      |> assign(:channels_saved, false)
      |> assign(:channels_error, nil)
      |> assign(:learnings_channel_name, nil)
      |> assign(:show_modal, nil)
      |> assign(:modal_title, nil)
      |> assign(:selected_project, nil)
      |> assign_changeset(nil)

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
      lost_backends={@lost_backends}
    >
      <div class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="projects-settings">
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Projects
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Manage repositories, issue trackers, and project configurations.
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
                    Key:
                    <span class="font-semibold text-slate-900 dark:text-slate-100">
                      {project.key}
                    </span>
                    <span class="text-slate-500 dark:text-slate-400">({tracker_label(project.tracker)})</span>
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
          <div
            id="project-modal-panel"
            class="w-full max-w-xl max-h-[calc(100vh-2rem)] overflow-y-auto rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-6"
          >
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

              <fieldset>
                <legend class="block text-sm font-medium text-slate-900 dark:text-slate-100">
                  Issue Tracker
                </legend>
                <div class="mt-1 flex items-center gap-6">
                  <label
                    :for={{value, label} <- [linear: "Linear", github: "GitHub Issues"]}
                    class="flex items-center gap-2 text-sm text-slate-900 dark:text-slate-100"
                  >
                    <input
                      type="radio"
                      name="project[tracker]"
                      id={"project-tracker-#{value}-input"}
                      value={value}
                      checked={Ecto.Changeset.get_field(@changeset, :tracker) == value}
                    />
                    {label}
                  </label>
                </div>
                <span
                  :if={@changeset.errors[:tracker]}
                  class="text-xs text-red-600"
                  id="project-tracker-error"
                >
                  {elem(@changeset.errors[:tracker], 0)}
                </span>
              </fieldset>

              <div>
                <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">
                  {if @show_linear_fields, do: "Linear Team Key", else: "Key"}
                </label>
                <input
                  type="text"
                  name="project[key]"
                  id="project-key-input"
                  value={Ecto.Changeset.get_field(@changeset, :key)}
                  placeholder={if @show_linear_fields, do: "e.g. DIS", else: "the repository's name"}
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <p :if={@show_github_fields} class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                  Names its issues, as in key#123. Fixed once the project has issues. The GitHub App needs Issues: read and write.
                </p>
                <span
                  :if={@changeset.errors[:key]}
                  class="text-xs text-red-600"
                  id="project-key-error"
                >
                  {elem(@changeset.errors[:key], 0)}
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

              <div>
                <label
                  for="project-toolchain-command-input"
                  class="block text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  Toolchain Command
                </label>
                <input
                  type="text"
                  name="project[toolchain_command]"
                  id="project-toolchain-command-input"
                  value={Ecto.Changeset.get_field(@changeset, :toolchain_command)}
                  placeholder="mise install"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm font-mono focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                  Runs beside Rail, outside any sandbox and its memory limit, in a checkout of the default branch each time it moves.
                  Sandboxes never install a missing tool themselves, so one fails there until this has run.
                </p>
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

              <div>
                <label
                  for="project-account-seed-command-input"
                  class="block text-sm font-medium text-slate-900 dark:text-slate-100"
                >
                  Account Seed
                </label>
                <input
                  type="text"
                  name="project[account_seed_command]"
                  id="project-account-seed-command-input"
                  value={Ecto.Changeset.get_field(@changeset, :account_seed_command)}
                  placeholder="mise exec -- mix run scripts/seed_account.exs"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm font-mono focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                  Runs from the worktree's root once for each agent that opens a browser, in that agent's sandbox.
                  It creates a user and an organization and prints the magic link to sign in with. Leave empty to
                  sign in as the QA and Demo prompts say.
                </p>
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

              <div
                :if={@show_linear_fields}
                class="pt-4 border-t border-slate-200 dark:border-slate-700"
              >
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
                <li
                  :for={channel <- @slack_channel_options}
                  class="flex items-center gap-3 text-sm min-w-0"
                >
                  <input type="hidden" name={"channels[#{channel.id}][included]"} value="false" />
                  <input type="hidden" name={"channels[#{channel.id}][name]"} value={channel.name} />
                  <input
                    :if={@channel_ids[channel.id]}
                    type="hidden"
                    name={"channels[#{channel.id}][id]"}
                    value={@channel_ids[channel.id]}
                  />
                  <input
                    type="hidden"
                    name={"channels[#{channel.id}][slack_workspace_id]"}
                    value={channel.workspace_id}
                  />
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
                    class="font-mono text-slate-900 dark:text-slate-100 truncate min-w-0"
                  >
                    #{channel.name}
                  </label>
                  <span
                    :if={channel.unlisted}
                    id={"slack-channel-unlisted-#{channel.id}"}
                    class="text-xs text-amber-600 dark:text-amber-400"
                  >
                    Not listed by Slack
                  </span>
                  <span
                    :if={Map.has_key?(@channel_selection, channel.id)}
                    class="ml-auto flex items-center gap-4 shrink-0"
                  >
                    <label class="inline-flex items-center gap-2 text-xs text-slate-600 dark:text-slate-300 cursor-pointer whitespace-nowrap">
                      <input
                        type="hidden"
                        name={"channels[#{channel.id}][bot_triage_enabled]"}
                        value="false"
                      />
                      <input
                        type="checkbox"
                        role="switch"
                        name={"channels[#{channel.id}][bot_triage_enabled]"}
                        id={"slack-channel-bots-#{channel.id}"}
                        value="true"
                        checked={@channel_selection[channel.id].bot_triage_enabled}
                        class="peer sr-only"
                      />
                      <span class="relative h-5 w-9 shrink-0 rounded-full bg-slate-300 dark:bg-slate-600 transition-colors peer-checked:bg-indigo-600 after:absolute after:top-0.5 after:left-0.5 after:size-4 after:rounded-full after:bg-white after:transition-transform peer-checked:after:translate-x-4"></span>
                      Triage bot messages
                    </label>
                    <label class="inline-flex items-center gap-2 text-xs text-slate-600 dark:text-slate-300 cursor-pointer whitespace-nowrap">
                      <input type="hidden" name={"channels[#{channel.id}][external]"} value="false" />
                      <input
                        type="checkbox"
                        role="switch"
                        name={"channels[#{channel.id}][external]"}
                        id={"slack-channel-external-#{channel.id}"}
                        value="true"
                        checked={@channel_selection[channel.id].external}
                        class="peer sr-only"
                      />
                      <span class="relative h-5 w-9 shrink-0 rounded-full bg-slate-300 dark:bg-slate-600 transition-colors peer-checked:bg-indigo-600 after:absolute after:top-0.5 after:left-0.5 after:size-4 after:rounded-full after:bg-white after:transition-transform peer-checked:after:translate-x-4"></span>
                      External
                    </label>
                  </span>
                </li>
              </ul>
              <p
                :if={map_size(@channel_selection) > 0}
                class="text-xs text-slate-500 dark:text-slate-400"
              >
                Triage bot messages is for channels where tools such as PostHog report issues. External is for channels shared with people outside the team: Rail never posts an issue link there.
              </p>
              <div
                :if={@channels_confirm}
                id="slack-channels-confirm"
                class="rounded-lg border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-950/30 p-3 space-y-2"
              >
                <p
                  :for={removal <- @channels_confirm.removals}
                  class="text-xs text-red-800 dark:text-red-200"
                >
                  Removing #{removal.name} deletes {removal.threads} triage {if removal.threads == 1,
                    do: "thread",
                    else: "threads"}, along with their items, notes and the record of what was posted.
                </p>
                <div class="flex justify-end gap-2">
                  <.button
                    size="sm"
                    phx-click="cancel_remove_channels"
                    id="cancel-remove-channels-button"
                  >
                    Keep them
                  </.button>
                  <.button
                    size="sm"
                    variant="danger"
                    phx-click="confirm_remove_channels"
                    id="confirm-remove-channels-button"
                  >
                    Remove and save
                  </.button>
                </div>
              </div>
              <p :if={@channels_error} id="slack-channels-error" class="text-xs text-red-600">
                {@channels_error}
              </p>
              <div :if={@slack_channel_options != []} class="flex justify-end">
                <.button type="submit" id="save-slack-channels-button">Save channels</.button>
              </div>
            </.form>

            <.live_component
              :if={@show_modal == :edit}
              module={LearningsChannelPicker}
              id="learnings-channel-picker"
              variant={:settings}
              current_scope={@current_scope}
              project={@selected_project}
              channel_name={@learnings_channel_name}
            />
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
      |> assign_changeset(changeset)

    {:noreply, socket}
  end

  def handle_event("edit_project", %{"project_id" => project_id}, socket) do
    case Projects.get_project(project_id) do
      {:ok, project} ->
        changeset = Project.changeset(project, %{})
        channels = Projects.list_slack_channels(project)

        socket =
          socket
          |> assign(:slack_channel_options, slack_channel_options(channels))
          |> assign(
            :channel_selection,
            Map.new(channels, &{&1.external_id, %{bot_triage_enabled: &1.bot_triage_enabled, external: &1.external}})
          )
          |> assign(:channel_ids, Map.new(channels, &{&1.external_id, &1.id}))
          |> assign(:channels_confirm, nil)
          |> assign(:channels_saved, false)
          |> assign(:channels_error, nil)
          |> assign(:learnings_channel_name, LearningsChannelPicker.channel_name(project))
          |> assign(:show_modal, :edit)
          |> assign(:modal_title, "Edit Project")
          |> assign(:selected_project, project)
          |> assign_changeset(changeset)

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

    entries =
      for {id, %{"included" => "true"} = channel} <- Map.get(params, "channels", %{}) do
        %{
          "id" => channel["id"],
          "external_id" => id,
          "name" => channel["name"],
          "slack_workspace_id" => channel["slack_workspace_id"],
          "bot_triage_enabled" => channel["bot_triage_enabled"] == "true",
          "external" => channel["external"] == "true"
        }
      end

    # Unchecking a channel deletes its triage threads with it, so that waits for a yes.
    case channel_removals(socket.assigns, entries) do
      [] ->
        {:noreply, save_channels(socket, entries, selection)}

      removals ->
        {:noreply, assign(socket, :channels_confirm, %{entries: entries, selection: selection, removals: removals})}
    end
  end

  def handle_event("confirm_remove_channels", _params, %{assigns: %{channels_confirm: pending}} = socket) do
    socket = socket |> assign(:channels_confirm, nil) |> save_channels(pending.entries, pending.selection)
    {:noreply, socket}
  end

  def handle_event("cancel_remove_channels", _params, socket) do
    {:noreply, assign(socket, :channels_confirm, nil)}
  end

  def handle_event("close_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_modal, nil)
      |> assign(:modal_title, nil)
      |> assign(:selected_project, nil)
      |> assign_changeset(nil)

    {:noreply, socket}
  end

  def handle_event("validate", %{"project" => params}, socket) do
    target = socket.assigns.selected_project || %Project{}

    changeset =
      target
      |> Project.changeset(params)
      |> Map.put(:action, :validate)

    socket = assign_changeset(socket, changeset)
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
              |> assign_changeset(nil)

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            socket = assign_changeset(socket, changeset)
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
              |> assign_changeset(nil)

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            socket = assign_changeset(socket, changeset)
            {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  # An edit from anywhere, such as a learnings channel picked on the Learnings page, shows here too.
  def handle_info({:project_changed, project_id}, socket) do
    if Enum.any?(socket.assigns.projects, &(&1.id == project_id)),
      do: {:noreply, refresh_project(socket, project_id)},
      else: {:noreply, socket}
  end

  # The navigation hook subscribes this view to pipeline events it does not use.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_changeset(socket, changeset) do
    tracker = changeset && Ecto.Changeset.get_field(changeset, :tracker)

    socket
    |> assign(:changeset, changeset)
    |> assign(:show_linear_fields, tracker == :linear)
    |> assign(:show_github_fields, tracker == :github)
  end

  defp tracker_label(:github), do: "GitHub"
  defp tracker_label(:linear), do: "Linear"

  defp refresh_project(socket, project_id) do
    {:ok, project} = Projects.get_project(project_id)
    socket = assign(socket, :projects, update_list_item(socket.assigns.projects, project))

    case socket.assigns.selected_project do
      %Project{id: ^project_id} = current ->
        channel_name = LearningsChannelPicker.channel_name(project, current, socket.assigns.learnings_channel_name)

        socket
        |> assign(:selected_project, project)
        |> assign(:learnings_channel_name, channel_name)

      _other_or_none ->
        socket
    end
  end

  # Each workspace is asked for its channels; one Slack cannot answer for adds nothing to pick.
  # A channel the project has that Slack did not list stays on the form, checked, so saving
  # never removes it, or its threads, without an admin unchecking it.
  defp slack_channel_options(stored) do
    listed =
      Enum.flat_map(Projects.list_slack_workspaces(), fn workspace ->
        case Slack.list_channels(workspace) do
          {:ok, channels} ->
            Enum.map(channels, &%{id: &1["id"], name: &1["name"], workspace_id: workspace.id, unlisted: false})

          {:error, _unreachable} ->
            []
        end
      end)

    listed_ids = MapSet.new(listed, & &1.id)

    unlisted =
      for channel <- stored, not MapSet.member?(listed_ids, channel.external_id) do
        %{id: channel.external_id, name: channel.name, workspace_id: channel.slack_workspace_id, unlisted: true}
      end

    listed ++ unlisted
  end

  defp save_channels(socket, entries, selection) do
    case Projects.update_project(socket.assigns.current_scope, socket.assigns.selected_project, %{
           "slack_channels" => entries
         }) do
      {:ok, project} ->
        socket
        |> assign(:selected_project, project)
        |> assign(:channel_ids, Map.new(project.slack_channels, &{&1.external_id, &1.id}))
        |> assign(:channel_selection, selection)
        |> assign(:channels_saved, true)
        |> assign(:channels_error, nil)

      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, :channels_error, channel_error(changeset))
    end
  end

  # Each channel the project has that the save leaves out, with how many triage threads go with it.
  defp channel_removals(assigns, entries) do
    kept = MapSet.new(entries, & &1["external_id"])
    names = Map.new(assigns.slack_channel_options, &{&1.id, &1.name})

    removed = Enum.reject(assigns.channel_ids, fn {external_id, _row_id} -> MapSet.member?(kept, external_id) end)
    counts = Triage.count_triage_threads(slack_channel_id: Enum.map(removed, &elem(&1, 1)), group_by: :slack_channel_id)

    for {external_id, row_id} <- removed, threads = Map.get(counts, row_id, 0), threads > 0 do
      %{name: names[external_id], threads: threads}
    end
  end

  defp channel_selection(params) do
    for {id, %{"included" => "true"} = channel} <- Map.get(params, "channels", %{}), into: %{} do
      {id, %{bot_triage_enabled: channel["bot_triage_enabled"] == "true", external: channel["external"] == "true"}}
    end
  end

  defp channel_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.get(:slack_channels, [])
    |> Enum.flat_map(&Map.get(&1, :external_id, []))
    |> Enum.uniq()
    |> Enum.map_join(" ", &"A channel #{&1}.")
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
