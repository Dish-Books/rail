defmodule RailWeb.Settings.IntercomWorkspacesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Support
  alias Rail.Support.Schemas.IntercomWorkspace

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "intercom_workspaces")
    projects = Projects.list_projects(socket.assigns.current_scope)

    socket =
      socket
      |> assign(:page_title, "Intercom")
      |> assign(:current_section, :intercom_workspaces)
      |> assign(:workspaces, Support.list_intercom_workspaces())
      |> assign(:projects_by_id, Map.new(projects, &{&1.id, &1}))
      |> assign(:project_options, Enum.map(projects, &{&1.name, &1.id}))
      |> assign(:selected_workspace, nil)
      |> assign(:project_id, nil)
      |> assign(:changeset, nil)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :page_title, "Intercom")}

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
        class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10"
        id="intercom-workspaces-settings"
      >
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Intercom
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            The Intercom apps Support reads conversations from, each feeding one project.
          </p>
          <p
            id="intercom-setup-note"
            class="mt-2 text-xs text-slate-500 dark:text-slate-400 break-words"
          >
            Permissions: <span class="font-mono">Read conversations, Write conversations, Read admins</span>. Webhook URL: <span class="font-mono">{url(~p"/webhooks/intercom")}</span>. Topics: <span class="font-mono">conversation.user.created, conversation.user.replied, conversation.admin.replied, conversation.admin.noted, conversation.operator.replied, conversation.admin.closed</span>. OAuth redirect URL: <span class="font-mono">{url(~p"/auth/intercom/callback")}</span>.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:intercom_workspaces} />

        <div class="flex items-center justify-between">
          <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">Workspaces</h2>
          <.button variant="primary" phx-click="new_workspace" id="new-intercom-workspace-button">
            New Workspace
          </.button>
        </div>

        <section class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden">
          <div
            :if={@workspaces == []}
            class="p-8 text-center text-slate-500 dark:text-slate-400 text-sm"
            id="empty-intercom-workspaces-message"
          >
            No Intercom workspaces yet. Click "New Workspace" to add one.
          </div>

          <ul
            :if={@workspaces != []}
            role="list"
            class="divide-y divide-slate-200 dark:divide-slate-700"
            id="intercom-workspaces-list"
          >
            <li
              :for={workspace <- @workspaces}
              class="p-6 flex items-center justify-between gap-4 hover:bg-slate-100 dark:hover:bg-slate-700"
              id={"intercom-workspace-item-#{workspace.id}"}
            >
              <div class="min-w-0 space-y-1">
                <span class="block truncate text-base font-semibold text-slate-900 dark:text-slate-100">
                  {workspace.name}
                </span>
                <div class="flex items-center gap-x-4 text-xs text-slate-500 dark:text-slate-400 min-w-0">
                  <span class="truncate">
                    App:
                    <span class="font-mono text-slate-900 dark:text-slate-100">{workspace.external_id}</span>
                  </span>
                  <span>•</span>
                  <span class="truncate">Project: {workspace.project.name}</span>
                </div>
              </div>

              <.button
                size="sm"
                phx-click="edit_workspace"
                phx-value-id={workspace.id}
                id={"edit-intercom-workspace-#{workspace.id}"}
              >
                <.icon name="pi-pencil-simple" class="h-3.5 w-3.5" /> Edit
              </.button>
            </li>
          </ul>
        </section>

        <div
          :if={@changeset}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="intercom-workspace-modal"
          phx-window-keydown="close_modal"
          phx-key="Escape"
        >
          <div class="w-full max-w-xl rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-6">
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-4">
              <h2 class="text-lg font-semibold text-slate-900 dark:text-slate-100" id="modal-title">
                {if @selected_workspace, do: "Edit Intercom Workspace", else: "New Intercom Workspace"}
              </h2>
              <button
                type="button"
                phx-click="close_modal"
                id="close-modal-button"
                aria-label="Close"
                class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 font-bold"
              >
                ✕
              </button>
            </div>

            <.form
              for={@changeset}
              id="intercom-workspace-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <.input
                label="Workspace Name"
                name="intercom_workspace[name]"
                id="intercom-workspace-name-input"
                value={Ecto.Changeset.get_field(@changeset, :name)}
                placeholder="e.g. Acme Support"
                errors={errors(@changeset, :name)}
              />
              <.input
                :if={!@selected_workspace}
                type="select"
                label="Project"
                name="intercom_workspace[project_id]"
                id="intercom-workspace-project-input"
                options={@project_options}
                value={@project_id}
                prompt="Pick a project"
                errors={errors(@changeset, :project_id)}
              />
              <.input
                type="password"
                label="Access Token"
                name="intercom_workspace[access_token]"
                id="intercom-workspace-access-token-input"
                value={Ecto.Changeset.get_change(@changeset, :access_token)}
                placeholder={if @selected_workspace, do: "Leave blank to keep the saved token"}
                class="font-mono"
                errors={errors(@changeset, :access_token)}
              />
              <.input
                label="Client ID"
                name="intercom_workspace[client_id]"
                id="intercom-workspace-client-id-input"
                value={Ecto.Changeset.get_field(@changeset, :client_id)}
                class="font-mono"
                errors={errors(@changeset, :client_id)}
              />
              <.input
                type="password"
                label="Client Secret"
                name="intercom_workspace[client_secret]"
                id="intercom-workspace-client-secret-input"
                value={Ecto.Changeset.get_change(@changeset, :client_secret)}
                placeholder={if @selected_workspace, do: "Leave blank to keep the saved secret"}
                class="font-mono"
                errors={errors(@changeset, :client_secret)}
              />

              <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
                <.button type="button" phx-click="close_modal" id="cancel-intercom-workspace-button">
                  Cancel
                </.button>
                <.button variant="primary" type="submit" id="save-intercom-workspace-button">Save</.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("new_workspace", _params, socket) do
    socket =
      socket
      |> assign(:selected_workspace, nil)
      |> assign(:project_id, nil)
      |> assign(:changeset, IntercomWorkspace.changeset(%IntercomWorkspace{}, %{}))

    {:noreply, socket}
  end

  def handle_event("edit_workspace", %{"id" => id}, socket) do
    case Support.get_intercom_workspace(id: id) do
      {:ok, workspace} ->
        socket =
          socket
          |> assign(:selected_workspace, workspace)
          |> assign(:changeset, IntercomWorkspace.changeset(workspace, %{}))

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_modal", _params, socket) do
    socket = socket |> assign(:selected_workspace, nil) |> assign(:changeset, nil)
    {:noreply, socket}
  end

  def handle_event("validate", %{"intercom_workspace" => params}, socket) do
    changeset =
      (socket.assigns.selected_workspace || new_workspace(socket, params))
      |> IntercomWorkspace.changeset(params)
      |> Map.put(:action, :validate)

    socket = socket |> assign(:project_id, params["project_id"]) |> assign(:changeset, changeset)
    {:noreply, socket}
  end

  def handle_event("save", %{"intercom_workspace" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.selected_workspace do
        %IntercomWorkspace{} = workspace ->
          Support.update_intercom_workspace(scope, workspace, params)

        # The project comes from the ones this page loaded for the admin, never from the form's own value.
        nil ->
          create(scope, Map.get(socket.assigns.projects_by_id, params["project_id"]), params)
      end

    case result do
      {:ok, _workspace} ->
        socket =
          socket
          |> assign(:workspaces, Support.list_intercom_workspaces())
          |> assign(:selected_workspace, nil)
          |> assign(:changeset, nil)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, Map.put(changeset, :action, :validate))}

      {:error, :not_found} ->
        changeset =
          socket.assigns.changeset
          |> Ecto.Changeset.add_error(:project_id, "Pick a project")
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_info({:intercom_workspace_changed, _id}, socket),
    do: {:noreply, assign(socket, :workspaces, Support.list_intercom_workspaces())}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp new_workspace(socket, params) do
    case Map.get(socket.assigns.projects_by_id, params["project_id"]) do
      %Project{id: project_id} -> %IntercomWorkspace{project_id: project_id}
      nil -> %IntercomWorkspace{}
    end
  end

  defp create(scope, %Project{} = project, params), do: Support.create_intercom_workspace(scope, project, params)
  defp create(_scope, nil, _params), do: {:error, :not_found}

  # Only once the form has been touched, so a fresh one is not all red.
  defp errors(%Ecto.Changeset{action: nil}, _field), do: []
  defp errors(changeset, field), do: changeset.errors |> Keyword.get_values(field) |> Enum.map(&elem(&1, 0))
end
