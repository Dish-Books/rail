defmodule RailWeb.Settings.ConnectedAccountsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Mcp
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  def mount(_params, _session, socket) do
    current_scope = socket.assigns.current_scope
    user = current_scope && current_scope.user

    socket =
      socket
      |> assign(:page_title, "Connected accounts")
      |> assign(:current_section, :connected_accounts)
      |> assign(:current_user, user)
      |> assign(:signing_key?, user != nil and User.signing?(user))
      |> assign(:signing_fingerprint, user && User.signing_fingerprint(user))
      |> assign(:linear_connected, linear_connected?(user))
      |> assign(:linear_name, user && user.linear_name)
      |> assign(:signing_error, nil)
      |> assign(:repository_access, repository_access(Projects.list_projects()))
      |> assign(:mcp_servers, Enum.filter(Mcp.list_servers(), &(&1.enabled and &1.auth == :oauth)))
      |> assign(:mcp_connected_ids, mcp_connected_ids(current_scope))

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket = assign(socket, :page_title, "Connected accounts")
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
        class="max-w-4xl mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-8"
        id="connected-accounts-settings"
      >
        <div>
          <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
            Connected accounts
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
            Manage third-party services connected to your account.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:connected_accounts} />

        <section
          id="github-account-section"
          class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/50 overflow-hidden"
        >
          <div class="flex items-center gap-4 p-5">
            <.account_avatar
              label={initials(@current_user)}
              src={@current_user && @current_user.avatar_url}
              id="github-avatar"
            />

            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2.5">
                <h2 class="text-lg font-semibold text-slate-900 dark:text-slate-100">GitHub</h2>
                <span
                  id="github-status-badge"
                  class="inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider text-emerald-700 dark:text-emerald-400 ring-1 ring-inset ring-emerald-600/30"
                >
                  Connected
                </span>
              </div>

              <p
                :if={@current_user}
                class="mt-0.5 text-sm text-slate-500 dark:text-slate-400 truncate"
              >
                <span id="github-login" class="text-slate-700 dark:text-slate-300">{@current_user.login}</span>
                <span :if={@current_user.name}>({@current_user.name})</span>
                <span :if={@current_user.email} id="github-email">· {@current_user.email}</span>
              </p>
            </div>

            <.button
              variant="secondary"
              href={~p"/auth/logout"}
              id="github-sign-out-button"
              data-qa="github_sign_out"
            >
              Sign out
            </.button>
          </div>

          <div class="border-t border-slate-200 dark:border-slate-700 px-5 pt-4 pb-1">
            <p class="text-[11px] font-bold uppercase tracking-wider text-slate-400 dark:text-slate-500">
              Capabilities
            </p>
          </div>

          <div class="flex items-start gap-3 px-5 py-4" id="capability-repositories">
            <.icon name="pi-check" class="size-4 mt-0.5 shrink-0 text-emerald-500" />

            <div class="min-w-0 flex-1">
              <h3 class="text-sm font-semibold text-slate-900 dark:text-slate-100">
                Repository access
              </h3>
              <p class="mt-0.5 text-sm text-slate-500 dark:text-slate-400">{@repository_access}</p>
            </div>

            <span class="text-sm text-slate-400 dark:text-slate-500">Enabled</span>
          </div>

          <div
            class="flex items-start gap-3 px-5 py-4 border-t border-slate-200 dark:border-slate-700"
            id="capability-commit-signing"
          >
            <.icon
              name={if @signing_key?, do: "pi-check", else: "pi-circle"}
              class={[
                "size-4 mt-0.5 shrink-0",
                @signing_key? && "text-emerald-500",
                not @signing_key? && "text-amber-500"
              ]}
            />

            <div class="min-w-0 flex-1 space-y-3">
              <div>
                <h3 class="text-sm font-semibold text-slate-900 dark:text-slate-100">
                  Commit signing
                </h3>

                <p
                  :if={@signing_key?}
                  id="commit-signing-details"
                  class="mt-0.5 text-sm text-slate-500 dark:text-slate-400"
                >
                  Commits Rail makes on your issues are signed with this key and show as verified.
                </p>

                <p
                  :if={not @signing_key?}
                  id="commit-signing-message"
                  class="mt-0.5 text-sm text-slate-500 dark:text-slate-400"
                >
                  Not set up - commits Rail makes on your issues land unsigned. Rail generates a signing
                  key and adds it to your account so they are verified and attributed to you.
                </p>

                <p
                  :if={@signing_fingerprint}
                  id="commit-signing-fingerprint"
                  data-qa="commit_signing_fingerprint"
                  class="mt-1 font-mono text-xs text-slate-400 dark:text-slate-500 truncate"
                >
                  {@signing_fingerprint}
                </p>
              </div>

              <div class="flex items-center gap-4 flex-wrap">
                <.button
                  variant="primary"
                  phx-click="set_up_signing"
                  id="set-up-signing-button"
                  data-qa="set_up_signing"
                >
                  {if @signing_key?, do: "Regenerate key", else: "Set up commit signing"}
                </.button>

                <.button
                  :if={@signing_key?}
                  variant="ghost_danger"
                  phx-click="remove_signing"
                  id="remove-signing-button"
                  data-qa="remove_signing"
                >
                  Remove
                </.button>

                <p
                  :if={@signing_error}
                  id="commit-signing-error"
                  data-qa="commit_signing_error"
                  class="text-sm text-red-500 dark:text-red-400"
                >
                  {@signing_error}
                </p>
              </div>
            </div>
          </div>
        </section>

        <div>
          <p class="text-[11px] font-bold uppercase tracking-wider text-slate-400 dark:text-slate-500">
            Other services
          </p>

          <div class="mt-3 space-y-3">
            <div
              id="linear-account-section"
              class="flex items-center gap-4 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/50 p-4"
            >
              <.account_avatar label="L" src={nil} id="linear-avatar" />

              <div class="min-w-0 flex-1">
                <h3 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Linear</h3>

                <p
                  :if={@linear_connected}
                  id="linear-connected-details"
                  class="mt-0.5 text-sm text-slate-500 dark:text-slate-400 truncate"
                >
                  <span id="linear-user-name">{@linear_name || "Linear User"}</span>
                  · issues and comments attributed to you
                </p>

                <p
                  :if={!@linear_connected}
                  id="linear-disconnected-message"
                  class="mt-0.5 text-sm text-slate-500 dark:text-slate-400"
                >
                  Not connected - issues and comments go out as the workspace.
                </p>
              </div>

              <span :if={@linear_connected} class="text-sm text-emerald-600 dark:text-emerald-400">
                Connected
              </span>

              <.button
                :if={@linear_connected}
                variant="secondary"
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
                Connect
              </.button>
            </div>

            <div
              :for={server <- @mcp_servers}
              id={"mcp-server-section-#{server.name}"}
              class="flex items-center gap-4 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/50 p-4"
            >
              <.account_avatar
                label={String.first(server.name)}
                src={nil}
                id={"mcp-avatar-#{server.name}"}
              />

              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <h3 class="text-sm font-semibold text-slate-900 dark:text-slate-100">
                    {server.name}
                  </h3>
                  <span class="rounded px-1.5 py-0.5 font-mono text-[10px] text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-slate-300 dark:ring-slate-600">
                    MCP
                  </span>
                </div>

                <p class="mt-0.5 text-sm text-slate-500 dark:text-slate-400">
                  Agents working your assigned issues use this connection.
                </p>
              </div>

              <span
                :if={MapSet.member?(@mcp_connected_ids, server.id)}
                class="text-sm text-emerald-600 dark:text-emerald-400"
              >
                Connected
              </span>

              <.button
                :if={MapSet.member?(@mcp_connected_ids, server.id)}
                variant="secondary"
                phx-click="disconnect_mcp"
                phx-value-id={server.id}
                id={"disconnect-mcp-#{server.name}"}
              >
                Disconnect
              </.button>

              <.button
                :if={!MapSet.member?(@mcp_connected_ids, server.id)}
                variant="primary"
                href={~p"/auth/mcp/#{server.id}"}
                id={"connect-mcp-#{server.name}"}
              >
                Connect
              </.button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("set_up_signing", _params, socket) do
    case Users.create_signing_key(socket.assigns.current_scope) do
      {:ok, user} ->
        socket = socket |> apply_user(user) |> assign(:signing_error, nil)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :signing_error, signing_message(reason))}
    end
  end

  def handle_event("remove_signing", _params, socket) do
    :ok = Users.delete_signing_key(socket.assigns.current_scope)
    {:ok, user} = Users.get_user(id: socket.assigns.current_user.id)
    socket = socket |> apply_user(user) |> assign(:signing_error, nil)

    {:noreply, socket}
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

  attr :label, :string, required: true
  attr :src, :any, default: nil
  attr :id, :string, required: true

  defp account_avatar(assigns) do
    ~H"""
    <img
      :if={@src}
      src={@src}
      alt=""
      id={@id}
      class="size-11 shrink-0 rounded-full ring-1 ring-slate-200 dark:ring-slate-700"
    />

    <div
      :if={!@src}
      id={"#{@id}-placeholder"}
      class="size-11 shrink-0 rounded-full bg-slate-100 dark:bg-slate-700 flex items-center justify-center text-sm font-semibold text-slate-500 dark:text-slate-300"
    >
      {@label}
    </div>
    """
  end

  defp apply_user(socket, %User{} = user) do
    socket
    |> assign(:current_scope, Scope.for_user(user))
    |> assign(:current_user, user)
    |> assign(:signing_key?, User.signing?(user))
    |> assign(:signing_fingerprint, User.signing_fingerprint(user))
  end

  defp signing_message(:missing_scope) do
    "Rail's GitHub App is missing the SSH signing keys permission. An admin grants it on the app, then you authorize it again."
  end

  defp signing_message(:no_github_token), do: "Sign in with GitHub again so Rail can reach your account."
  defp signing_message(reason), do: "Could not set up commit signing: #{inspect(reason)}"

  defp repository_access(projects) do
    case length(projects) do
      1 -> "Read and write on 1 repository."
      count -> "Read and write on #{count} repositories."
    end
  end

  defp initials(%User{name: name}) when is_binary(name) do
    name |> String.split(~r/\s+/, trim: true) |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end

  defp initials(%User{login: login}) when is_binary(login), do: login |> String.first() |> String.upcase()

  defp mcp_connected_ids(scope) do
    scope |> Mcp.list_connections() |> MapSet.new(& &1.mcp_server_id)
  end

  defp linear_connected?(user) do
    token = user && user.linear_access_token
    is_binary(token) and token != ""
  end
end
