defmodule RailWeb.Settings.ConnectedAccountsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Mcp
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  def mount(_params, _session, socket) do
    %Scope{user: %User{} = user} = current_scope = socket.assigns.current_scope
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "users")

    socket =
      socket
      |> assign(:page_title, "Connected accounts")
      |> assign(:current_section, :connected_accounts)
      |> assign(:access?, Rail.cloudflare_access() != nil)
      |> assign(:github_error, Phoenix.Flash.get(socket.assigns.flash, :github_error))
      |> apply_user(user)
      |> assign(:linear_connected, linear_connected?(user))
      |> assign(:linear_name, user.linear_name)
      |> assign(:slack_connected, Scope.slack_linked?(current_scope))
      |> assign(:slack_name, user.slack_name)
      |> assign(:slack_notifications_error, nil)
      |> assign(:signing_error, nil)
      |> assign(:repository_access, repository_access(socket.assigns.projects))
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
    <%!-- The GitHub error shows under the GitHub row, so the layout's toast does not say it twice. --%>
    <Layouts.app
      flash={Map.delete(@flash, "github_error")}
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
          id="account-section"
          class="flex items-center gap-4 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/50 p-5"
        >
          <.account_avatar
            label={initials(@current_user)}
            src={@current_user.avatar_url}
            id="account-avatar"
          />

          <div class="min-w-0 flex-1">
            <h2
              id="account-name"
              class="text-lg font-semibold text-slate-900 dark:text-slate-100 truncate"
            >
              {@current_user.name || @current_user.email}
            </h2>
            <p class="mt-0.5 text-sm text-slate-500 dark:text-slate-400 truncate">
              <span id="account-email" class="text-slate-700 dark:text-slate-300">
                {@current_user.email}
              </span>
              <span :if={@access?} id="account-access">· signed in through Cloudflare Access</span>
            </p>
          </div>

          <.button
            variant="secondary"
            href={~p"/auth/logout"}
            id="account-sign-out-button"
            data-qa="account_sign_out"
          >
            <.icon name="pi-sign-out" class="size-4" /> Sign out
          </.button>
        </section>

        <div>
          <p class="text-[11px] font-bold uppercase tracking-wider text-slate-400 dark:text-slate-500">
            Services
          </p>

          <div class="mt-3 space-y-3">
            <div
              id="github-account-section"
              class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/50 overflow-hidden"
            >
              <div class="flex items-center gap-4 p-4">
                <div class="size-11 shrink-0 rounded-full bg-slate-100 dark:bg-slate-700 flex items-center justify-center text-slate-600 dark:text-slate-200">
                  <.icon name="pi-github-logo" class="size-5" />
                </div>

                <div class="min-w-0 flex-1">
                  <h3 class="text-sm font-semibold text-slate-900 dark:text-slate-100">GitHub</h3>

                  <p
                    :if={@github_connected}
                    id="github-connected-details"
                    class="mt-0.5 text-sm text-slate-500 dark:text-slate-400 truncate"
                  >
                    <span id="github-login" class="text-slate-700 dark:text-slate-300">
                      {@current_user.login}
                    </span>
                    · approvals, merges and pull requests go out as you
                  </p>

                  <p
                    :if={!@github_connected}
                    id="github-disconnected-message"
                    class="mt-0.5 text-sm text-slate-500 dark:text-slate-400"
                  >
                    Not connected - you cannot approve or merge tasks, and commits Rail makes on your issues land unsigned.
                  </p>
                </div>

                <span :if={@github_connected} class="text-sm text-emerald-600 dark:text-emerald-400">
                  Connected
                </span>

                <.button
                  :if={@github_connected}
                  variant="secondary"
                  href={~p"/auth/github"}
                  id="reconnect-github-button"
                >
                  <.icon name="pi-arrows-clockwise" class="size-4" /> Reconnect
                </.button>

                <.button
                  :if={@github_connected}
                  variant="secondary"
                  phx-click="disconnect_github"
                  id="disconnect-github-button"
                >
                  Disconnect
                </.button>

                <.button
                  :if={!@github_connected}
                  variant="primary"
                  href={~p"/auth/github"}
                  id="connect-github-button"
                >
                  <.icon name="pi-github-logo" class="size-4" /> Connect GitHub
                </.button>
              </div>

              <div
                :if={@github_error}
                id="github-error"
                role="alert"
                class="flex items-start gap-2 border-t border-red-200 dark:border-red-400/30 bg-red-50 dark:bg-red-400/10 px-4 py-2.5 text-sm text-red-700 dark:text-red-300"
              >
                <.icon name="pi-warning-circle" class="size-4 mt-0.5 shrink-0" />
                <span class="min-w-0 break-words">{@github_error}</span>
              </div>

              <div
                :if={@github_connected}
                class="flex items-start gap-3 border-t border-slate-200 dark:border-slate-700 px-4 py-3"
                id="capability-repositories"
              >
                <div class="size-11 shrink-0 flex justify-center">
                  <.icon name="pi-check" class="size-4 mt-0.5 text-emerald-500" />
                </div>

                <div class="min-w-0 flex-1">
                  <h4 class="text-sm font-semibold text-slate-900 dark:text-slate-100">
                    Repository access
                  </h4>
                  <p
                    id="repository-access"
                    title={@repository_access}
                    class="text-sm text-slate-500 dark:text-slate-400 truncate"
                  >
                    {@repository_access}
                  </p>
                </div>
              </div>

              <div
                :if={@github_connected}
                class="flex items-start gap-3 border-t border-slate-200 dark:border-slate-700 px-4 py-3"
                id="capability-commit-signing"
              >
                <div class="size-11 shrink-0 flex justify-center">
                  <.icon
                    name={if @signing_key?, do: "pi-check", else: "pi-circle"}
                    class={[
                      "size-4 mt-0.5",
                      @signing_key? && "text-emerald-500",
                      not @signing_key? && "text-amber-500"
                    ]}
                  />
                </div>

                <div class="min-w-0 flex-1 space-y-3">
                  <div>
                    <h4 class="text-sm font-semibold text-slate-900 dark:text-slate-100">
                      Commit signing
                    </h4>

                    <p
                      :if={@signing_key?}
                      id="commit-signing-details"
                      class="text-sm text-slate-500 dark:text-slate-400"
                    >
                      Commits Rail makes on your issues are signed with this key and show as verified.
                    </p>

                    <p
                      :if={not @signing_key?}
                      id="commit-signing-message"
                      class="text-sm text-slate-500 dark:text-slate-400"
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
                      variant={if @signing_key?, do: "secondary", else: "primary"}
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
            </div>

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
              id="slack-account-section"
              class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/50 overflow-hidden"
            >
              <div class="flex items-center gap-4 p-4">
                <.account_avatar label="S" src={nil} id="slack-avatar" />

                <div class="min-w-0 flex-1">
                  <h3 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Slack</h3>

                  <p
                    :if={@slack_connected}
                    id="slack-connected-details"
                    class="mt-0.5 text-sm text-slate-500 dark:text-slate-400 truncate"
                  >
                    <span id="slack-user-name">{@slack_name || "Slack User"}</span>
                    · replies you accept in triage post as you
                  </p>

                  <p
                    :if={!@slack_connected}
                    id="slack-disconnected-message"
                    class="mt-0.5 text-sm text-slate-500 dark:text-slate-400"
                  >
                    Not connected - you cannot post from triage until you connect.
                  </p>
                </div>

                <span :if={@slack_connected} class="text-sm text-emerald-600 dark:text-emerald-400">
                  Connected
                </span>

                <.button
                  :if={@slack_connected}
                  variant="secondary"
                  phx-click="disconnect_slack"
                  id="disconnect-slack-button"
                >
                  Disconnect
                </.button>

                <.button
                  :if={!@slack_connected}
                  variant="primary"
                  href={~p"/auth/slack"}
                  id="connect-slack-button"
                >
                  Connect Slack
                </.button>
              </div>

              <div
                id="slack-notifications"
                class="flex items-center gap-4 border-t border-slate-200 dark:border-slate-700 px-4 py-3"
              >
                <div class="size-11 shrink-0 flex items-center justify-center">
                  <.icon
                    name={if @slack_connected, do: "pi-bell-ringing", else: "pi-bell-slash"}
                    class={[
                      "size-[18px]",
                      @slack_connected && "text-slate-400",
                      not @slack_connected && "text-slate-500"
                    ]}
                  />
                </div>

                <div class="min-w-0 flex-1">
                  <h4 class={[
                    "text-sm font-semibold",
                    @slack_connected && "text-slate-900 dark:text-slate-100",
                    not @slack_connected && "text-slate-500 dark:text-slate-400"
                  ]}>
                    Notify me about my tasks
                  </h4>
                  <p
                    :if={@slack_notifications_error}
                    id="slack-notifications-error"
                    role="alert"
                    class="mt-0.5 flex items-start gap-1.5 text-sm text-red-600 dark:text-red-400"
                  >
                    <.icon name="pi-warning-circle" class="size-4 mt-0.5 shrink-0" />
                    <span>{@slack_notifications_error}</span>
                  </p>
                  <p
                    :if={!@slack_notifications_error}
                    id="slack-notifications-message"
                    class="mt-0.5 text-sm text-slate-500 dark:text-slate-400"
                  >
                    {slack_notifications_message(@slack_connected, @slack_notifications)}
                  </p>
                </div>

                <span
                  id="slack-notifications-state"
                  class={[
                    "text-xs w-7 text-right",
                    @slack_notifications && "font-semibold text-slate-700 dark:text-slate-200",
                    not @slack_notifications && "text-slate-500 dark:text-slate-400"
                  ]}
                >
                  {if @slack_notifications, do: "On", else: "Off"}
                </span>

                <%!-- A button shows only what the server rendered, where a checkbox the browser flipped can stay on. --%>
                <button
                  type="button"
                  role="switch"
                  id="slack-notifications-switch"
                  aria-checked={to_string(@slack_notifications)}
                  disabled={not @slack_connected}
                  phx-click="set_slack_notifications"
                  phx-value-on={to_string(not @slack_notifications)}
                  aria-label="Notify me about my tasks in Slack"
                  class="group shrink-0 rounded-full cursor-pointer disabled:cursor-not-allowed disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-500"
                >
                  <span class="relative block h-5 w-9 rounded-full bg-slate-300 dark:bg-slate-600 transition-colors group-aria-checked:bg-indigo-600 after:absolute after:top-0.5 after:left-0.5 after:size-4 after:rounded-full after:bg-white after:transition-transform group-aria-checked:after:translate-x-4"></span>
                </button>
              </div>
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
    case Users.delete_signing_key(socket.assigns.current_scope) do
      :ok ->
        {:ok, user} = Users.get_user(id: socket.assigns.current_user.id)
        socket = socket |> apply_user(user) |> assign(:signing_error, nil)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :signing_error, signing_message(reason))}
    end
  end

  def handle_event("disconnect_github", _params, socket) do
    {:ok, user} = Users.unlink_github(socket.assigns.current_scope)
    socket = socket |> apply_user(user) |> assign(:github_error, nil) |> assign(:signing_error, nil)
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

  def handle_event("disconnect_slack", _params, socket) do
    case Users.unlink_slack(socket.assigns.current_scope) do
      {:ok, updated_user} ->
        socket =
          socket
          |> assign(:current_scope, Scope.for_user(updated_user))
          |> assign(:current_user, updated_user)
          |> assign(:slack_connected, false)
          |> assign(:slack_name, nil)
          |> assign(:slack_notifications, updated_user.slack_notifications)
          |> assign(:slack_notifications_error, nil)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("set_slack_notifications", %{"on" => on}, socket) do
    socket =
      case Users.set_slack_notifications(socket.assigns.current_scope, on == "true") do
        {:ok, user} ->
          socket |> apply_user(user) |> assign(:slack_notifications_error, nil)

        # Slack was disconnected in another tab, so the page catches up with it.
        {:error, %Ecto.Changeset{data: %User{} = user}} ->
          socket
          |> apply_user(user)
          |> assign(:slack_connected, Scope.slack_linked?(Scope.for_user(user)))
          |> assign(:slack_name, user.slack_name)
          |> assign(:slack_notifications_error, nil)

        {:error, reason} ->
          assign(socket, :slack_notifications_error, slack_notifications_error_message(reason))
      end

    {:noreply, socket}
  end

  def handle_event("disconnect_mcp", %{"id" => server_id}, socket) do
    scope = socket.assigns.current_scope

    with {:ok, server} <- Mcp.get_server(id: server_id) do
      :ok = Mcp.disconnect_server(scope, server)
    end

    {:noreply, assign(socket, :mcp_connected_ids, mcp_connected_ids(scope))}
  end

  def handle_info({:users_changed, id}, %{assigns: %{current_user: %User{id: id}}} = socket) do
    {:ok, user} = Users.get_user(id: id)
    socket = apply_user(socket, user)
    socket = if user.slack_notifications, do: assign(socket, :slack_notifications_error, nil), else: socket
    {:noreply, socket}
  end

  def handle_info({:users_changed, _someone_else}, socket), do: {:noreply, socket}

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
    |> assign(:github_connected, is_binary(user.github_id))
    |> assign(:signing_key?, User.signing?(user))
    |> assign(:signing_fingerprint, User.signing_fingerprint(user))
    |> assign(:slack_notifications, user.slack_notifications)
  end

  defp slack_notifications_message(false, _on?), do: "Connect Slack to get notifications."

  defp slack_notifications_message(true, true),
    do: "Rail messages you when a task you own waits on you, and when someone else merges it."

  defp slack_notifications_message(true, false), do: "Off. Rail sends you nothing in Slack."

  defp slack_notifications_error_message({:slack_error, "messages_tab_disabled"}),
    do:
      "The Rail app's Messages tab is off, so Slack refused the message. " <>
        "An admin turns it on under App Home in the Slack app's settings."

  defp slack_notifications_error_message({:slack_error, reason})
       when reason in ["invalid_auth", "token_revoked", "account_inactive", "not_authed"],
       do:
         "Slack refused the message because the workspace's bot token is no longer valid. " <>
           "An admin replaces it under Settings, Slack."

  defp slack_notifications_error_message({:slack_error, reason}) when is_binary(reason),
    do: "Slack refused the message: #{reason}. An admin checks the Rail app's settings at api.slack.com/apps."

  defp slack_notifications_error_message(:not_found),
    do: "Rail has no Slack workspace for your Slack account. An admin adds it under Settings, Slack."

  defp slack_notifications_error_message(_status_or_transport), do: "Rail could not reach Slack. Try again."

  defp signing_message(:missing_scope) do
    "Rail's GitHub App is missing the SSH signing keys permission. An admin grants it on the app, then you authorize it again."
  end

  defp signing_message(:no_github_token), do: "Reconnect GitHub so Rail can reach your account."
  defp signing_message(reason), do: "Could not set up commit signing: #{inspect(reason)}"

  defp repository_access([]), do: "No repositories yet. An admin grants you projects in Users."
  defp repository_access(projects), do: Enum.map_join(projects, ", ", & &1.github_repo)

  defp initials(%User{name: name}) when is_binary(name) do
    name |> String.split(~r/\s+/, trim: true) |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end

  defp initials(%User{login: login}) when is_binary(login), do: login |> String.first() |> String.upcase()
  defp initials(%User{email: email}), do: email |> String.first() |> String.upcase()

  defp mcp_connected_ids(scope) do
    scope |> Mcp.list_connections() |> MapSet.new(& &1.mcp_server_id)
  end

  defp linear_connected?(%User{linear_access_token: token}), do: is_binary(token) and token != ""
end
