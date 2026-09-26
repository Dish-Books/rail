defmodule RailWeb.Settings.LinearWorkspacesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace

  def mount(_params, _session, socket) do
    linear_workspaces = Projects.list_linear_workspaces()

    socket =
      socket
      |> assign(:page_title, "Linear Workspaces")
      |> assign(:current_section, :linear_workspaces)
      |> assign(:linear_workspaces, linear_workspaces)
      |> assign(:selected_workspace, nil)
      |> assign(:changeset, nil)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :page_title, "Linear Workspaces")}
  end

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
      <div
        class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10"
        id="linear-workspaces-settings"
      >
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Linear Workspaces
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Credentials for system-level sync, webhook verification, and asset uploads. Projects link to one.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:linear_workspaces} />

        <div class="flex items-center justify-between">
          <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">Workspaces</h2>
          <button
            type="button"
            phx-click="new_workspace"
            id="new-workspace-button"
            class="rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600"
          >
            New Workspace
          </button>
        </div>

        <section class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden">
          <div
            :if={Enum.empty?(@linear_workspaces)}
            class="p-8 text-center text-slate-500 dark:text-slate-400 text-sm"
            id="empty-workspaces-message"
          >
            No Linear workspaces yet. Click "New Workspace" to add one.
          </div>

          <ul
            :if={not Enum.empty?(@linear_workspaces)}
            role="list"
            class="divide-y divide-slate-200 dark:divide-slate-700"
            id="workspaces-list"
          >
            <li
              :for={workspace <- @linear_workspaces}
              class="p-6 flex items-center justify-between hover:bg-slate-100 dark:hover:bg-slate-700"
              id={"workspace-item-#{workspace.id}"}
            >
              <div class="space-y-1">
                <span class="text-base font-semibold text-slate-900 dark:text-slate-100">
                  {workspace.name}
                </span>
                <div class="flex items-center space-x-4 text-xs text-slate-500 dark:text-slate-400">
                  <span>
                    ID:
                    <span class="font-mono text-slate-900 dark:text-slate-100">{workspace.external_id}</span>
                  </span>
                  <span>•</span>
                  <span id={"workspace-projects-#{workspace.id}"}>
                    Projects:
                    <span class="text-slate-900 dark:text-slate-100">
                      {workspace.projects
                      |> Enum.map(& &1.name)
                      |> Enum.join(", ")
                      |> then(&if(&1 == "", do: "none", else: &1))}
                    </span>
                  </span>
                </div>
              </div>

              <.button
                size="sm"
                phx-click="edit_workspace"
                phx-value-id={workspace.id}
                id={"edit-workspace-#{workspace.id}"}
              >
                <.icon name="pi-pencil-simple" class="h-3.5 w-3.5" /> Edit
              </.button>
            </li>
          </ul>
        </section>

        <div
          :if={@changeset}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="workspace-modal"
        >
          <div class="w-full max-w-xl rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-6">
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-4">
              <h2 class="text-lg font-semibold text-slate-900 dark:text-slate-100" id="modal-title">
                {if @selected_workspace, do: "Edit Linear Workspace", else: "New Linear Workspace"}
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
              id="workspace-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <.input
                label="Workspace Name"
                name="linear_workspace[name]"
                id="workspace-name-input"
                value={Ecto.Changeset.get_field(@changeset, :name)}
                placeholder="e.g. Acme Corp"
                errors={errors(@changeset, :name)}
              />
              <.input
                label="External Workspace ID"
                name="linear_workspace[external_id]"
                id="workspace-external-id-input"
                value={Ecto.Changeset.get_field(@changeset, :external_id)}
                placeholder="e.g. lin_ws_12345"
                class="font-mono"
                errors={errors(@changeset, :external_id)}
              />
              <.input
                type="password"
                label="Linear API Token"
                name="linear_workspace[token]"
                id="workspace-token-input"
                value={Ecto.Changeset.get_change(@changeset, :token)}
                placeholder={
                  if @selected_workspace,
                    do: "Leave blank to keep the saved token",
                    else: "lin_api_..."
                }
                class="font-mono"
                errors={errors(@changeset, :token)}
              />
              <.input
                type="password"
                label="Webhook Signing Secret"
                name="linear_workspace[webhook_secret]"
                id="workspace-webhook-secret-input"
                value={Ecto.Changeset.get_change(@changeset, :webhook_secret)}
                placeholder={
                  if @selected_workspace,
                    do: "Leave blank to keep the saved secret",
                    else: "whsec_..."
                }
                class="font-mono"
                errors={errors(@changeset, :webhook_secret)}
              />

              <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
                <.button type="button" phx-click="close_modal" id="cancel-workspace-button">Cancel</.button>
                <.button variant="primary" type="submit" id="save-workspace-button">Save</.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("new_workspace", _params, socket) do
    changeset = LinearWorkspace.changeset(%LinearWorkspace{}, %{})
    socket = socket |> assign(:selected_workspace, nil) |> assign(:changeset, changeset)
    {:noreply, socket}
  end

  def handle_event("edit_workspace", %{"id" => id}, socket) do
    case Projects.get_linear_workspace(id: id) do
      {:ok, workspace} ->
        changeset = LinearWorkspace.changeset(workspace, %{})
        socket = socket |> assign(:selected_workspace, workspace) |> assign(:changeset, changeset)
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_modal", _params, socket) do
    socket = socket |> assign(:selected_workspace, nil) |> assign(:changeset, nil)
    {:noreply, socket}
  end

  def handle_event("validate", %{"linear_workspace" => params}, socket) do
    changeset =
      (socket.assigns.selected_workspace || %LinearWorkspace{})
      |> LinearWorkspace.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"linear_workspace" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.selected_workspace do
        %LinearWorkspace{} = workspace -> Projects.update_linear_workspace(scope, workspace, params)
        nil -> Projects.create_linear_workspace(scope, params)
      end

    case result do
      {:ok, _workspace} ->
        linear_workspaces = Projects.list_linear_workspaces()

        socket =
          socket
          |> assign(:linear_workspaces, linear_workspaces)
          |> assign(:selected_workspace, nil)
          |> assign(:changeset, nil)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  # The navigation hook subscribes this view to pipeline events it does not use.
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  # Only once the form has been touched, so a fresh one is not all red.
  defp errors(%Ecto.Changeset{action: nil}, _field), do: []
  defp errors(changeset, field), do: changeset.errors |> Keyword.get_values(field) |> Enum.map(&elem(&1, 0))
end
