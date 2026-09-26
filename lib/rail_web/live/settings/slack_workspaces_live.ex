defmodule RailWeb.Settings.SlackWorkspacesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Projects.Schemas.SlackWorkspace

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Slack Workspaces")
      |> assign(:current_section, :slack_workspaces)
      |> assign(:slack_workspaces, Projects.list_slack_workspaces())
      |> assign(:selected_workspace, nil)
      |> assign(:changeset, nil)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :page_title, "Slack Workspaces")}
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
      <div
        class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10"
        id="slack-workspaces-settings"
      >
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Slack Workspaces
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            The Slack app triage reads threads with. Projects pick their channels in Projects.
          </p>
          <p id="slack-setup-note" class="mt-2 text-xs text-slate-500 dark:text-slate-400">
            Turn on Socket Mode. App-level token: <span class="font-mono">connections:write</span>. Bot scopes: <span class="font-mono">channels:history, groups:history, channels:read, groups:read, users:read</span>. User scope: <span class="font-mono">chat:write</span>. Events: <span class="font-mono">message.channels, message.groups</span>.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:slack_workspaces} />

        <div class="flex items-center justify-between">
          <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">Workspaces</h2>
          <.button variant="primary" phx-click="new_workspace" id="new-slack-workspace-button">
            New Workspace
          </.button>
        </div>

        <section class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden">
          <div
            :if={Enum.empty?(@slack_workspaces)}
            class="p-8 text-center text-slate-500 dark:text-slate-400 text-sm"
            id="empty-slack-workspaces-message"
          >
            No Slack workspaces yet. Click "New Workspace" to add one.
          </div>

          <ul
            :if={not Enum.empty?(@slack_workspaces)}
            role="list"
            class="divide-y divide-slate-200 dark:divide-slate-700"
            id="slack-workspaces-list"
          >
            <li
              :for={workspace <- @slack_workspaces}
              class="p-6 flex items-center justify-between hover:bg-slate-100 dark:hover:bg-slate-700"
              id={"slack-workspace-item-#{workspace.id}"}
            >
              <div class="space-y-1">
                <span class="text-base font-semibold text-slate-900 dark:text-slate-100">
                  {workspace.name}
                </span>
                <div class="flex items-center space-x-4 text-xs text-slate-500 dark:text-slate-400">
                  <span>
                    Team:
                    <span class="font-mono text-slate-900 dark:text-slate-100">{workspace.external_id}</span>
                  </span>
                  <span>•</span>
                  <span>
                    Socket Mode: {if workspace.app_token, do: "on", else: "no app-level token"}
                  </span>
                </div>
              </div>

              <.button
                size="sm"
                phx-click="edit_workspace"
                phx-value-id={workspace.id}
                id={"edit-slack-workspace-#{workspace.id}"}
              >
                <.icon name="pi-pencil-simple" class="h-3.5 w-3.5" /> Edit
              </.button>
            </li>
          </ul>
        </section>

        <div
          :if={@changeset}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="slack-workspace-modal"
        >
          <div class="w-full max-w-xl rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-6">
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-4">
              <h2 class="text-lg font-semibold text-slate-900 dark:text-slate-100" id="modal-title">
                {if @selected_workspace, do: "Edit Slack Workspace", else: "New Slack Workspace"}
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
              id="slack-workspace-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <.input
                label="Workspace Name"
                name="slack_workspace[name]"
                id="slack-workspace-name-input"
                value={Ecto.Changeset.get_field(@changeset, :name)}
                placeholder="e.g. Acme Corp"
                errors={errors(@changeset, :name)}
              />
              <.input
                type="password"
                label="Bot Token"
                name="slack_workspace[token]"
                id="slack-workspace-token-input"
                value=""
                placeholder={
                  if @selected_workspace, do: "Leave blank to keep the saved token", else: "xoxb-..."
                }
                class="font-mono"
                errors={errors(@changeset, :token)}
              />
              <.input
                type="password"
                label="App-Level Token"
                name="slack_workspace[app_token]"
                id="slack-workspace-app-token-input"
                value=""
                placeholder={
                  if @selected_workspace, do: "Leave blank to keep the saved token", else: "xapp-..."
                }
                class="font-mono"
                errors={errors(@changeset, :app_token)}
              />

              <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
                <.button type="button" phx-click="close_modal" id="cancel-slack-workspace-button">
                  Cancel
                </.button>
                <.button variant="primary" type="submit" id="save-slack-workspace-button">Save</.button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("new_workspace", _params, socket) do
    changeset = SlackWorkspace.changeset(%SlackWorkspace{}, %{})
    socket = socket |> assign(:selected_workspace, nil) |> assign(:changeset, changeset)
    {:noreply, socket}
  end

  def handle_event("edit_workspace", %{"id" => id}, socket) do
    case Projects.get_slack_workspace(id: id) do
      {:ok, workspace} ->
        socket =
          socket |> assign(:selected_workspace, workspace) |> assign(:changeset, SlackWorkspace.changeset(workspace, %{}))

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_modal", _params, socket) do
    socket = socket |> assign(:selected_workspace, nil) |> assign(:changeset, nil)
    {:noreply, socket}
  end

  def handle_event("validate", %{"slack_workspace" => params}, socket) do
    changeset =
      (socket.assigns.selected_workspace || %SlackWorkspace{})
      |> SlackWorkspace.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"slack_workspace" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.selected_workspace do
        %SlackWorkspace{} = workspace -> Projects.update_slack_workspace(scope, workspace, params)
        nil -> Projects.create_slack_workspace(scope, params)
      end

    case result do
      {:ok, _workspace} ->
        socket =
          socket
          |> assign(:slack_workspaces, Projects.list_slack_workspaces())
          |> assign(:selected_workspace, nil)
          |> assign(:changeset, nil)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, Map.put(changeset, :action, :validate))}
    end
  end

  # Only once the form has been touched, so a fresh one is not all red.
  defp errors(%Ecto.Changeset{action: nil}, _field), do: []
  defp errors(changeset, field), do: changeset.errors |> Keyword.get_values(field) |> Enum.map(&elem(&1, 0))
end
