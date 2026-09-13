defmodule RailWeb.Settings.UsersLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Users

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    users =
      case Users.list_users(scope) do
        {:ok, list} -> list
        {:error, _reason} -> []
      end

    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:current_section, :users)
      |> assign(:users, users)
      |> assign(:error_message, nil)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:current_section, :users)

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
      <div class="max-w-4xl mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="users-settings">
        <div>
          <h1
            class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
            id="users-title"
          >
            Users
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400" id="users-subtitle">
            Manage system users and administrative privileges.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:users} />

        <div
          :if={@error_message}
          id="users-error-banner"
          class="rounded-md bg-red-50 p-4 border border-red-200 text-sm text-red-700 flex items-center justify-between"
        >
          <span id="users-error-text">{@error_message}</span>
          <button
            type="button"
            phx-click="clear_error"
            id="clear-users-error-button"
            class="text-red-500 hover:text-red-700 font-bold"
          >
            ✕
          </button>
        </div>

        <!-- Users List Card -->
        <section
          class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden"
          id="users-list-section"
        >
          <div class="p-6 border-b border-slate-200 dark:border-slate-700 flex items-center justify-between">
            <div>
              <h2
                class="text-base font-semibold text-slate-900 dark:text-slate-100"
                id="users-card-header"
              >
                User Directory
              </h2>
              <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
                {length(@users)} registered {if length(@users) == 1, do: "account", else: "accounts"}
              </p>
            </div>
          </div>

          <ul role="list" class="divide-y divide-slate-200 dark:divide-slate-700" id="users-list">
            <li
              :for={user <- @users}
              id={"user-row-#{user.id}"}
              class="p-6 flex items-center justify-between hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors"
            >
              <div class="flex items-center space-x-4">
                <img
                  :if={user.avatar_url}
                  src={user.avatar_url}
                  alt={user.name || user.login}
                  class="h-10 w-10 rounded-full ring-2 ring-slate-200 dark:ring-slate-700"
                  id={"user-avatar-#{user.id}"}
                />
                <div
                  :if={!user.avatar_url}
                  class="h-10 w-10 rounded-full bg-slate-100 dark:bg-slate-700 flex items-center justify-center text-slate-500 dark:text-slate-400 font-bold text-sm"
                  id={"user-placeholder-#{user.id}"}
                >
                  {initials_for(user)}
                </div>

                <div>
                  <div class="flex items-center space-x-2">
                    <span
                      class="font-medium text-slate-900 dark:text-slate-100 text-sm"
                      id={"user-name-#{user.id}"}
                    >
                      {user.name || user.login}
                    </span>
                    <span
                      class="text-xs text-slate-500 dark:text-slate-400"
                      id={"user-login-#{user.id}"}
                    >
                      @{user.login}
                    </span>
                  </div>
                  <p
                    class="text-xs text-slate-500 dark:text-slate-400 mt-0.5"
                    id={"user-email-#{user.id}"}
                  >
                    {user.email}
                  </p>
                </div>
              </div>

              <div class="flex items-center space-x-3">
                <!-- Linear linked badge -->
                <span
                  :if={linear_connected?(user)}
                  id={"user-linear-badge-#{user.id}"}
                  class="inline-flex items-center rounded-md bg-blue-50 px-2 py-1 text-xs font-medium text-blue-700 ring-1 ring-inset ring-blue-700/10"
                >
                  Linear: {user.linear_name || "Linked"}
                </span>
                <span
                  :if={!linear_connected?(user)}
                  id={"user-linear-badge-#{user.id}"}
                  class="inline-flex items-center rounded-md bg-slate-100 dark:bg-slate-700 px-2 py-1 text-xs font-medium text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-zinc-500/10"
                >
                  Linear: Not Linked
                </span>

                <!-- Admin Status Badge -->
                <span
                  :if={user.admin}
                  id={"user-role-badge-#{user.id}"}
                  class="inline-flex items-center rounded-md bg-indigo-50 px-2.5 py-1 text-xs font-semibold text-indigo-700 ring-1 ring-inset ring-indigo-600/20"
                >
                  Admin
                </span>
                <span
                  :if={!user.admin}
                  id={"user-role-badge-#{user.id}"}
                  class="inline-flex items-center rounded-md bg-slate-100 dark:bg-slate-700 px-2.5 py-1 text-xs font-medium text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-zinc-500/20"
                >
                  User
                </span>

                <!-- Toggle Admin Button -->
                <.button
                  :if={user.id != @current_scope.user.id}
                  size="sm"
                  variant={if user.admin, do: "danger", else: "accent"}
                  id={"toggle-admin-button-#{user.id}"}
                  data-qa={"toggle_admin_button_#{user.id}"}
                  phx-click="toggle_admin"
                  phx-value-user_id={user.id}
                >
                  <.icon
                    name={if user.admin, do: "pi-shield-slash", else: "pi-shield-check"}
                    class="h-3.5 w-3.5"
                  />
                  {if user.admin, do: "Revoke Admin", else: "Make Admin"}
                </.button>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("toggle_admin", %{"user_id" => user_id}, socket) do
    scope = socket.assigns.current_scope
    user = Enum.find(socket.assigns.users, &(&1.id == user_id))

    cond do
      is_nil(user) ->
        {:noreply, socket}

      # Changing your own admin flag is how an admin locks themselves out.
      user.id == scope.user.id ->
        socket = assign(socket, :error_message, "You cannot change your own admin permissions.")

        {:noreply, socket}

      true ->
        toggle_admin(socket, scope, user)
    end
  end

  def handle_event("clear_error", _params, socket) do
    socket = assign(socket, :error_message, nil)
    {:noreply, socket}
  end

  defp toggle_admin(socket, scope, user) do
    case Users.update_user(scope, user, %{admin: not user.admin}) do
      {:ok, _updated_user} ->
        {:ok, refreshed_users} = Users.list_users(scope)

        socket =
          socket
          |> assign(:users, refreshed_users)
          |> assign(:error_message, nil)

        {:noreply, socket}

      {:error, :not_authorized} ->
        socket = assign(socket, :error_message, "You are not authorized to modify user permissions.")

        {:noreply, socket}

      {:error, _other} ->
        socket = assign(socket, :error_message, "Failed to update user permissions.")

        {:noreply, socket}
    end
  end

  defp linear_connected?(user) do
    is_binary(user.linear_user_id) or (is_binary(user.linear_access_token) and user.linear_access_token != "")
  end

  defp initials_for(user) do
    case user.name || user.login do
      str when is_binary(str) and str != "" -> String.upcase(String.slice(str, 0, 2))
      _other -> "U"
    end
  end
end
