defmodule RailWeb.Settings.ProjectsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project

  def mount(_params, _session, socket) do
    projects = Projects.list_projects()

    socket =
      socket
      |> assign(:page_title, "Projects")
      |> assign(:projects, projects)
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
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div class="max-w-4xl mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="projects-settings">
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

              <fieldset class="space-y-4 pt-4 border-t border-slate-200 dark:border-slate-700">
                <legend class="text-sm font-medium text-slate-900 dark:text-slate-100">
                  Linear Workspace
                </legend>
                <p class="text-xs text-slate-500 dark:text-slate-400">
                  Credentials used for system-level sync, webhook verification, and asset uploads.
                </p>

                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Workspace Name</label>
                    <input
                      type="text"
                      name="project[linear_workspace][name]"
                      id="workspace-name-input"
                      value={workspace_field(@changeset, :name)}
                      placeholder="e.g. Acme Corp"
                      class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                    />
                    <span
                      :if={workspace_error(@changeset, :name)}
                      class="text-xs text-red-600"
                      id="workspace-name-error"
                    >
                      {workspace_error(@changeset, :name)}
                    </span>
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">External Workspace ID</label>
                    <input
                      type="text"
                      name="project[linear_workspace][external_id]"
                      id="workspace-external-id-input"
                      value={workspace_field(@changeset, :external_id)}
                      placeholder="e.g. lin_ws_12345"
                      class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                    />
                    <span
                      :if={workspace_error(@changeset, :external_id)}
                      class="text-xs text-red-600"
                      id="workspace-external-id-error"
                    >
                      {workspace_error(@changeset, :external_id)}
                    </span>
                  </div>
                </div>

                <div>
                  <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Linear API Token</label>
                  <input
                    type="password"
                    name="project[linear_workspace][token]"
                    id="workspace-token-input"
                    value={workspace_field(@changeset, :token)}
                    placeholder="lin_api_..."
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm font-mono"
                  />
                  <span
                    :if={workspace_error(@changeset, :token)}
                    class="text-xs text-red-600"
                    id="workspace-token-error"
                  >
                    {workspace_error(@changeset, :token)}
                  </span>
                </div>

                <div>
                  <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Webhook Signing Secret</label>
                  <input
                    type="password"
                    name="project[linear_workspace][webhook_secret]"
                    id="workspace-webhook-secret-input"
                    value={workspace_field(@changeset, :webhook_secret)}
                    placeholder="whsec_..."
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm font-mono"
                  />
                  <span
                    :if={workspace_error(@changeset, :webhook_secret)}
                    class="text-xs text-red-600"
                    id="workspace-webhook-secret-error"
                  >
                    {workspace_error(@changeset, :webhook_secret)}
                  </span>
                </div>
              </fieldset>

              <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
                <.button phx-click="close_modal" id="cancel-project-button">
                  Cancel
                </.button>
                <.button variant="primary" type="submit" id="save-project-button">
                  Save
                </.button>
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
          |> assign(:show_modal, :edit)
          |> assign(:modal_title, "Edit Project")
          |> assign(:selected_project, project)
          |> assign(:changeset, changeset)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
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
      |> Project.changeset(drop_blank_workspace(params))
      |> Map.put(:action, :validate)

    socket = assign(socket, :changeset, changeset)
    {:noreply, socket}
  end

  def handle_event("save", %{"project" => params}, socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.show_modal do
      :new ->
        case Projects.create_project(scope, drop_blank_workspace(params)) do
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

        case Projects.update_project(scope, project, drop_blank_workspace(params)) do
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

  defp workspace_field(changeset, field) do
    case Ecto.Changeset.get_field(changeset, :linear_workspace) do
      %LinearWorkspace{} = workspace -> Map.fetch!(workspace, field)
      _other -> nil
    end
  end

  defp workspace_error(changeset, field) do
    with %Ecto.Changeset{} = workspace_changeset <- changeset.changes[:linear_workspace],
         {message, _opts} <- workspace_changeset.errors[field] do
      message
    else
      _other -> nil
    end
  end

  defp drop_blank_workspace(%{"linear_workspace" => workspace} = params) when is_map(workspace) do
    if Enum.all?(Map.values(workspace), &(&1 in ["", nil])) do
      Map.delete(params, "linear_workspace")
    else
      params
    end
  end

  defp drop_blank_workspace(params), do: params

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
