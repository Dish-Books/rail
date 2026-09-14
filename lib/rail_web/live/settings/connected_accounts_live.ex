defmodule RailWeb.Settings.ConnectedAccountsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Mcp
  alias Rail.Scope
  alias Rail.Users

  def mount(_params, _session, socket) do
    current_scope = socket.assigns.current_scope
    user = current_scope && current_scope.user

    socket =
      socket
      |> assign(:page_title, "Connected Accounts")
      |> assign(:current_section, :connected_accounts)
      |> assign(:current_user, user)
      |> assign(:linear_connected, linear_connected?(user))
      |> assign(:linear_name, user && user.linear_name)
      |> assign(:mcp_servers, Enum.filter(Mcp.list_servers(), &(&1.enabled and &1.auth == :oauth)))
      |> assign(:mcp_connected_ids, mcp_connected_ids(current_scope))

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket = assign(socket, :page_title, "Connected Accounts")
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
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div
        class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10"
        id="connected-accounts-settings"
      >
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Connected Accounts
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Manage third-party services connected to your account.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:connected_accounts} />

        <!-- GitHub Identity Section -->
        <section
          class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg p-6 border border-slate-200 dark:border-slate-700"
          id="github-account-section"
        >
          <div class="flex items-center justify-between pb-4 border-b border-slate-200 dark:border-slate-700">
            <div class="flex items-center space-x-4">
              <img
                :if={@current_user && @current_user.avatar_url}
                src={@current_user.avatar_url}
                alt={@current_user.name || @current_user.login}
                class="h-12 w-12 rounded-full ring-2 ring-slate-200 dark:ring-slate-700"
                id="github-avatar"
              />
              <div
                :if={!@current_user || is_nil(@current_user.avatar_url)}
                class="h-12 w-12 rounded-full bg-slate-100 dark:bg-slate-700 flex items-center justify-center text-slate-500 dark:text-slate-400 font-bold"
                id="github-avatar-placeholder"
              >
                GH
              </div>
              <div>
                <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">GitHub</h2>
                <p :if={@current_user} class="text-sm text-slate-500 dark:text-slate-400">
                  Connected as
                  <span class="font-semibold text-slate-900 dark:text-slate-100" id="github-login">{@current_user.login}</span>
                  <span :if={@current_user.name} class="text-slate-500 dark:text-slate-400"> ({@current_user.name})</span>
                </p>
                <p
                  :if={@current_user && @current_user.email}
                  class="text-xs text-slate-500 dark:text-slate-400"
                  id="github-email"
                >
                  {@current_user.email}
                </p>
              </div>
            </div>
            <div>
              <span
                class="inline-flex items-center rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-inset ring-green-600/20"
                id="github-status-badge"
              >
                Connected
              </span>
            </div>
          </div>
        </section>

        <!-- Linear Connection Section -->
        <section
          class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg p-6 border border-slate-200 dark:border-slate-700"
          id="linear-account-section"
        >
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">Linear</h2>
              <div :if={@linear_connected} id="linear-connected-details">
                <p class="text-sm text-slate-500 dark:text-slate-400 mt-1">
                  Connected as
                  <span class="font-semibold text-slate-900 dark:text-slate-100" id="linear-user-name">{@linear_name ||
                    "Linear User"}</span>
                </p>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
                  Issues and comments created by you will be attributed to your Linear user.
                </p>
              </div>
              <div :if={!@linear_connected} id="linear-disconnected-details">
                <p
                  class="text-sm text-slate-500 dark:text-slate-400 mt-1"
                  id="linear-disconnected-message"
                >
                  Linear is not connected.
                </p>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
                  Connect Linear to author issues and comments with your identity.
                </p>
              </div>
            </div>

            <div>
              <.button
                :if={@linear_connected}
                variant="danger"
                phx-click="disconnect"
                id="disconnect-linear-button"
              >
                Disconnect
              </.button>

              <.button
                :if={!@linear_connected}
                variant="primary"
                href={~p"/auth/linear"}
                id="connect-linear-button"
              >
                Connect Linear
              </.button>
            </div>
          </div>
        </section>

        <section
          :for={server <- @mcp_servers}
          class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg p-6 border border-slate-200 dark:border-slate-700"
          id={"mcp-server-section-#{server.name}"}
        >
          <% connected = MapSet.member?(@mcp_connected_ids, server.id) %>
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100">{server.name}</h2>
              <p class="text-sm text-slate-500 dark:text-slate-400 mt-1">
                {if connected, do: "Connected.", else: "Not connected."}
              </p>
              <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
                MCP server. Agents working your assigned issues use this connection.
              </p>
            </div>

            <div>
              <.button
                :if={connected}
                variant="danger"
                phx-click="disconnect_mcp"
                phx-value-id={server.id}
                id={"disconnect-mcp-#{server.name}"}
              >
                Disconnect
              </.button>

              <.button
                :if={!connected}
                variant="primary"
                href={~p"/auth/mcp/#{server.id}"}
                id={"connect-mcp-#{server.name}"}
              >
                Connect
              </.button>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("disconnect", _params, socket) do
    case Users.unlink_linear(socket.assigns.current_scope) do
      {:ok, updated_user} ->
        updated_scope = Scope.for_user(updated_user)

        socket =
          socket
          |> assign(:current_scope, updated_scope)
          |> assign(:current_user, updated_user)
          |> assign(:linear_connected, false)
          |> assign(:linear_name, nil)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("disconnect_mcp", %{"id" => server_id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, server} <- Mcp.get_server(id: server_id) do
      :ok = Mcp.disconnect_server(scope, server)
    end

    {:noreply, assign(socket, :mcp_connected_ids, mcp_connected_ids(scope))}
  end

  defp mcp_connected_ids(scope) do
    scope |> Mcp.list_connections() |> MapSet.new(& &1.mcp_server_id)
  end

  defp linear_connected?(user) do
    token = user && user.linear_access_token
    is_binary(token) and token != ""
  end
end
