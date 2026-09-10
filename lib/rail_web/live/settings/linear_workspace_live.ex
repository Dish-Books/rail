defmodule RailWeb.Settings.LinearWorkspaceLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace

  def mount(_params, _session, socket) do
    current_scope = socket.assigns.current_scope

    workspace =
      case Projects.get_linear_workspace(current_scope) do
        {:ok, ws} -> ws
        {:error, :not_found} -> nil
      end

    changeset =
      if workspace do
        LinearWorkspace.changeset(workspace, %{})
      else
        LinearWorkspace.changeset(%LinearWorkspace{}, %{})
      end

    socket =
      socket
      |> assign(:page_title, "Linear Workspace")
      |> assign(:workspace, workspace)
      |> assign(:changeset, changeset)
      |> assign(:saved, false)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket = assign(socket, :page_title, "Linear Workspace")
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
      show_new_issue_modal={@show_new_issue_modal}
      capture_ask={@capture_ask}
      capture_project_id={@capture_project_id}
      capture_priority={@capture_priority}
      capture_error={@capture_error}
      capture_submitting={@capture_submitting}
    >
      <div
        class="max-w-4xl mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10"
        id="linear-workspace-settings"
      >
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Linear Workspace
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Configure the global Linear workspace API token and webhook secret for automated operations.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:linear_workspace} />

        <section class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg p-6 border border-slate-200 dark:border-slate-700">
          <div class="pb-4 border-b border-slate-200 dark:border-slate-700 flex items-center justify-between">
            <div>
              <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">
                Workspace Credentials
              </h2>
              <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
                Used for system-level sync, webhook verification, and asset uploads.
              </p>
            </div>
            <span
              :if={@saved}
              class="inline-flex items-center rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-inset ring-green-600/20"
              id="workspace-saved-badge"
            >
              Saved successfully
            </span>
          </div>

          <.form
            for={@changeset}
            id="linear-workspace-form"
            phx-change="validate"
            phx-submit="save"
            class="mt-6 space-y-6"
          >
            <div>
              <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Workspace Name</label>
              <input
                type="text"
                name="linear_workspace[name]"
                id="workspace-name-input"
                value={Ecto.Changeset.get_field(@changeset, :name)}
                placeholder="e.g. Acme Corp"
                class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
              <span
                :if={@changeset.errors[:name]}
                class="text-xs text-red-600"
                id="workspace-name-error"
              >
                {elem(@changeset.errors[:name], 0)}
              </span>
            </div>

            <div>
              <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">External Workspace ID</label>
              <input
                type="text"
                name="linear_workspace[external_id]"
                id="workspace-external-id-input"
                value={Ecto.Changeset.get_field(@changeset, :external_id)}
                placeholder="e.g. lin_ws_12345"
                class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
              <span
                :if={@changeset.errors[:external_id]}
                class="text-xs text-red-600"
                id="workspace-external-id-error"
              >
                {elem(@changeset.errors[:external_id], 0)}
              </span>
            </div>

            <div>
              <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Linear API Token</label>
              <input
                type="password"
                name="linear_workspace[token]"
                id="workspace-token-input"
                value={Ecto.Changeset.get_field(@changeset, :token)}
                placeholder="lin_api_..."
                class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm font-mono"
              />
              <span
                :if={@changeset.errors[:token]}
                class="text-xs text-red-600"
                id="workspace-token-error"
              >
                {elem(@changeset.errors[:token], 0)}
              </span>
            </div>

            <div>
              <label class="block text-sm font-medium text-slate-900 dark:text-slate-100">Webhook Signing Secret</label>
              <input
                type="password"
                name="linear_workspace[webhook_secret]"
                id="workspace-webhook-secret-input"
                value={Ecto.Changeset.get_field(@changeset, :webhook_secret)}
                placeholder="whsec_..."
                class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm font-mono"
              />
              <span
                :if={@changeset.errors[:webhook_secret]}
                class="text-xs text-red-600"
                id="workspace-webhook-secret-error"
              >
                {elem(@changeset.errors[:webhook_secret], 0)}
              </span>
            </div>

            <div class="flex items-center justify-end pt-4 border-t border-slate-200 dark:border-slate-700">
              <button
                type="submit"
                id="save-workspace-button"
                class="rounded-md bg-indigo-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-600"
              >
                Save Configuration
              </button>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("validate", %{"linear_workspace" => params}, socket) do
    target = socket.assigns.workspace || %LinearWorkspace{}

    changeset =
      target
      |> LinearWorkspace.changeset(params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:saved, false)

    {:noreply, socket}
  end

  def handle_event("save", %{"linear_workspace" => params}, socket) do
    scope = socket.assigns.current_scope

    case Projects.upsert_linear_workspace(scope, params) do
      {:ok, workspace} ->
        changeset = LinearWorkspace.changeset(workspace, %{})

        socket =
          socket
          |> assign(:workspace, workspace)
          |> assign(:changeset, changeset)
          |> assign(:saved, true)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> assign(:saved, false)

        {:noreply, socket}
    end
  end
end
