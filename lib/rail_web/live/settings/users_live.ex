defmodule RailWeb.Settings.UsersLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Users

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:current_section, :users)
      |> assign(:invite_email, "")
      |> assign(:invite_admin, false)
      |> assign(:error_message, nil)
      |> load_directory(scope)

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
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="users-settings">
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

        <!-- Invites Card -->
        <section
          class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden"
          id="invites-section"
        >
          <div class="p-6 border-b border-slate-200 dark:border-slate-700">
            <h2
              class="text-base font-semibold text-slate-900 dark:text-slate-100"
              id="invites-card-header"
            >
              Invites
            </h2>
            <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
              Rail is invite only. Sign-in matches the GitHub account's email against an open invite.
            </p>

            <form
              id="invite-form"
              phx-submit="invite"
              phx-change="invite_form_change"
              class="mt-4 flex flex-wrap items-end gap-3"
            >
              <.input
                id="invite-email-input"
                name="email"
                type="email"
                label="Email address"
                value={@invite_email}
                placeholder="teammate@example.com"
                phx-debounce="300"
                container_class="flex-1 min-w-[16rem]"
                data-qa="invite_email_input"
              />

              <label class="flex items-center gap-2 text-sm text-slate-900 dark:text-slate-100 pb-2">
                <input
                  type="checkbox"
                  name="admin"
                  id="invite-admin-checkbox"
                  checked={@invite_admin}
                  class="rounded border-slate-300 dark:border-slate-600"
                /> Admin
              </label>

              <.button
                type="submit"
                variant="primary"
                id="send-invite-button"
                data-qa="send_invite_button"
                class="mb-2"
              >
                <.icon name="pi-envelope-simple" class="h-4 w-4" /> Invite
              </.button>
            </form>
          </div>

          <p
            :if={@invites == []}
            class="p-6 text-sm text-slate-500 dark:text-slate-400"
            id="invites-empty"
          >
            No invites yet.
          </p>

          <ul role="list" class="divide-y divide-slate-200 dark:divide-slate-700" id="invites-list">
            <li
              :for={invite <- @invites}
              id={"invite-row-#{invite.id}"}
              class="px-6 py-4 flex items-center justify-between"
            >
              <div>
                <p
                  class="text-sm font-medium text-slate-900 dark:text-slate-100"
                  id={"invite-email-#{invite.id}"}
                >
                  {invite.email}
                </p>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
                  Invited by {(invite.invited_by &&
                                 (invite.invited_by.name || invite.invited_by.login)) ||
                    "the system"}
                </p>
              </div>

              <div class="flex items-center space-x-3">
                <span
                  :if={invite.admin}
                  id={"invite-admin-badge-#{invite.id}"}
                  class="inline-flex items-center rounded-md bg-indigo-50 px-2.5 py-1 text-xs font-semibold text-indigo-700 ring-1 ring-inset ring-indigo-600/20"
                >
                  Admin
                </span>

                <span
                  id={"invite-status-#{invite.id}"}
                  class="inline-flex items-center rounded-md bg-slate-100 dark:bg-slate-700 px-2.5 py-1 text-xs font-medium text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-zinc-500/20"
                >
                  {if invite.accepted_at, do: "Accepted", else: "Pending"}
                </span>

                <.button
                  :if={is_nil(invite.accepted_at)}
                  size="sm"
                  variant="danger"
                  id={"revoke-invite-button-#{invite.id}"}
                  data-qa={"revoke_invite_button_#{invite.id}"}
                  phx-click="revoke_invite"
                  phx-value-invite_id={invite.id}
                >
                  <.icon name="pi-trash" class="h-3.5 w-3.5" /> Revoke
                </.button>
              </div>
            </li>
          </ul>
        </section>

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

  def handle_event("invite_form_change", params, socket) do
    socket =
      socket
      |> assign(:invite_email, Map.get(params, "email") || "")
      |> assign(:invite_admin, Map.get(params, "admin") == "on")

    {:noreply, socket}
  end

  def handle_event("invite", params, socket) do
    scope = socket.assigns.current_scope
    attrs = %{email: Map.get(params, "email") || "", admin: Map.get(params, "admin") == "on"}

    case Users.invite_user(scope, attrs) do
      {:ok, _invite} ->
        socket =
          socket
          |> assign(:invite_email, "")
          |> assign(:invite_admin, false)
          |> assign(:error_message, nil)
          |> load_directory(scope)

        {:noreply, socket}

      {:error, :already_accepted} ->
        {:noreply, assign(socket, :error_message, "That email has already signed up.")}

      {:error, :not_authorized} ->
        {:noreply, assign(socket, :error_message, "You are not authorized to invite users.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :error_message, invite_error(changeset))}

      {:error, _other} ->
        {:noreply, assign(socket, :error_message, "Failed to send the invite.")}
    end
  end

  def handle_event("revoke_invite", %{"invite_id" => invite_id}, socket) do
    scope = socket.assigns.current_scope

    case Users.revoke_invite(scope, invite_id) do
      {:ok, _invite} ->
        socket =
          socket
          |> assign(:error_message, nil)
          |> load_directory(scope)

        {:noreply, socket}

      {:error, :already_accepted} ->
        {:noreply, assign(socket, :error_message, "That invite has already been accepted.")}

      {:error, :not_authorized} ->
        {:noreply, assign(socket, :error_message, "You are not authorized to revoke invites.")}

      {:error, _other} ->
        {:noreply, assign(socket, :error_message, "Failed to revoke the invite.")}
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

  defp load_directory(socket, scope) do
    users =
      case Users.list_users(scope) do
        {:ok, list} -> list
        {:error, _reason} -> []
      end

    invites =
      case Users.list_invites(scope) do
        {:ok, list} -> list
        {:error, _reason} -> []
      end

    socket
    |> assign(:users, users)
    |> assign(:invites, invites)
  end

  defp invite_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:email] do
      {message, _opts} -> "Email #{message}."
      nil -> "Failed to send the invite."
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
