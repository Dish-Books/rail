defmodule RailWeb.Settings.UsersLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Users

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "users")

    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:current_section, :users)
      |> assign(:sheet, nil)
      |> assign(:sheet_user_id, nil)
      |> assign(:invite_email, "")
      |> assign(:invite_admin, false)
      |> assign(:invite_project_ids, [])
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
      lost_backends={@lost_backends}
    >
      <div class={[@sheet && "2xl:pr-[440px]"]}>
        <div class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="users-settings">
          <div>
            <h1
              class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
              id="users-title"
            >
              Users
            </h1>
            <p class="mt-1 text-sm text-slate-500 dark:text-slate-400" id="users-subtitle">
              Manage system users, administrative privileges and the projects each user works on.
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

          <section id="users-list-section">
            <div class="mb-3 flex items-end justify-between gap-4">
              <h2
                id="users-count"
                class="text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400"
              >
                Users · {length(@users)}
              </h2>
              <.button
                size="sm"
                variant="primary"
                id="invite-button"
                data-qa="invite_button"
                phx-click="open_invite"
              >
                <.icon name="pi-envelope-simple" class="h-3.5 w-3.5" /> Invite
              </.button>
            </div>
            <div class="rounded-xl border border-slate-200 dark:border-slate-700/70 overflow-hidden bg-slate-50 dark:bg-slate-800/40">
              <table class="w-full table-fixed" id="users-list">
                <colgroup>
                  <col class="w-[34%]" />
                  <col class="w-[30%]" />
                  <col />
                  <col class="w-24" />
                  <col class="w-12" />
                </colgroup>
                <thead class="bg-slate-50 dark:bg-slate-800/60">
                  <tr>
                    <.th>Person</.th>
                    <.th>Projects</.th>
                    <.th>Linear</.th>
                    <.th>Role</.th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={user <- @users}
                    id={"user-row-#{user.id}"}
                    data-qa="user_row"
                    tabindex="0"
                    phx-click="open_user"
                    phx-keydown="open_user"
                    phx-key="Enter"
                    phx-value-user_id={user.id}
                    aria-selected={to_string(@sheet == :user and @sheet_user_id == user.id)}
                    class={[
                      "border-t border-slate-200 dark:border-slate-700/70 cursor-pointer focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-500",
                      (@sheet == :user and @sheet_user_id == user.id) &&
                        "bg-blue-50 dark:bg-blue-950/50 shadow-[inset_3px_0_0_0_var(--color-blue-500)]",
                      !(@sheet == :user and @sheet_user_id == user.id) &&
                        "hover:bg-slate-100 dark:hover:bg-slate-700/40"
                    ]}
                  >
                    <td class="px-4 py-3 max-w-0">
                      <div class="flex items-center gap-3 min-w-0">
                        <.avatar user={user} size="h-8 w-8 text-xs" />
                        <div class="min-w-0">
                          <div class="flex items-center gap-2 min-w-0">
                            <span
                              id={"user-name-#{user.id}"}
                              class="text-sm font-medium text-slate-900 dark:text-slate-100 truncate"
                            >
                              {user.name || user.login}
                            </span>
                            <span
                              :if={user.id == @current_scope.user.id}
                              id={"user-you-#{user.id}"}
                              class="text-xs text-slate-500 dark:text-slate-400 shrink-0"
                            >
                              You
                            </span>
                          </div>
                          <p
                            id={"user-login-#{user.id}"}
                            class="text-xs text-slate-500 dark:text-slate-400 truncate"
                          >
                            @{user.login} · {user.email}
                          </p>
                        </div>
                      </div>
                    </td>
                    <td class="px-4 py-3 text-sm max-w-0">
                      <.access_summary
                        id={"user-projects-#{user.id}"}
                        admin={user.admin}
                        names={project_names(@projects, user.project_ids)}
                      />
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap">
                      <.linear_badge user={user} />
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap">
                      <span
                        :if={user.admin}
                        id={"user-role-badge-#{user.id}"}
                        class="inline-flex items-center rounded-md bg-indigo-50 dark:bg-indigo-400/10 px-2.5 py-1 text-xs font-semibold text-indigo-700 dark:text-indigo-300 ring-1 ring-inset ring-indigo-600/20 dark:ring-indigo-400/30"
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
                    </td>
                    <td class="px-4 py-3 text-right">
                      <.icon name="pi-caret-right" class="h-4 w-4 text-slate-400" />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section id="invites-section">
            <h2 class="mb-3 text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
              Invites
            </h2>
            <p
              :if={@invites == []}
              class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-4 text-sm text-slate-500 dark:text-slate-400"
              id="invites-empty"
            >
              No invites yet.
            </p>
            <div
              :if={@invites != []}
              class="rounded-xl border border-slate-200 dark:border-slate-700/70 overflow-hidden bg-slate-50 dark:bg-slate-800/40"
            >
              <table class="w-full table-fixed" id="invites-list">
                <colgroup>
                  <col class="w-[34%]" />
                  <col class="w-[30%]" />
                  <col />
                  <col class="w-24" />
                  <col class="w-12" />
                </colgroup>
                <tbody>
                  <tr
                    :for={invite <- @invites}
                    id={"invite-row-#{invite.id}"}
                    class="border-t first:border-t-0 border-slate-200 dark:border-slate-700/70"
                  >
                    <td class="px-4 py-3 max-w-0">
                      <p
                        class="text-sm font-medium text-slate-900 dark:text-slate-100 truncate"
                        id={"invite-email-#{invite.id}"}
                      >
                        {invite.email}
                      </p>
                      <p class="text-xs text-slate-500 dark:text-slate-400 truncate">
                        Invited by {(invite.invited_by &&
                                       (invite.invited_by.name || invite.invited_by.login)) ||
                          "the system"}
                      </p>
                    </td>
                    <td class="px-4 py-3 text-sm max-w-0">
                      <.access_summary
                        id={"invite-projects-#{invite.id}"}
                        admin={invite.admin}
                        names={project_names(@projects, invite.project_ids)}
                      />
                    </td>
                    <td class="px-4 py-3 whitespace-nowrap">
                      <span
                        id={"invite-status-#{invite.id}"}
                        class="inline-flex items-center rounded-md bg-slate-100 dark:bg-slate-700 px-2.5 py-1 text-xs font-medium text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-zinc-500/20"
                      >
                        {if invite.accepted_at, do: "Accepted", else: "Pending"}
                      </span>
                    </td>
                    <td class="px-4 py-3 text-right whitespace-nowrap" colspan="2">
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
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </div>

      <.side_sheet
        :if={@sheet == :user and @sheet_user != nil}
        id="user-sheet"
        label={@sheet_user.name || @sheet_user.login}
        on_close="close_sheet"
      >
        <:header>
          <div class="flex items-start gap-3">
            <.avatar user={@sheet_user} size="h-11 w-11 text-sm" id_prefix="sheet" />
            <div class="flex-1 min-w-0">
              <p class="text-base font-semibold text-slate-900 dark:text-slate-100 truncate">
                {@sheet_user.name || @sheet_user.login}
              </p>
              <p class="text-xs text-slate-500 dark:text-slate-400 truncate">
                @{@sheet_user.login} · {@sheet_user.email}
              </p>
              <div class="mt-2"><.linear_badge user={@sheet_user} id_prefix="sheet" /></div>
            </div>
          </div>
        </:header>

        <form id="user-access-form" phx-change="update_access" class="space-y-6">
          <input type="hidden" name="user_id" value={@sheet_user.id} />
          <label class="flex items-start gap-3 cursor-pointer">
            <input
              :if={@sheet_user.id != @current_scope.user.id}
              type="hidden"
              name="user[admin]"
              value="false"
            />
            <input
              type="checkbox"
              id="user-sheet-admin"
              name="user[admin]"
              value="true"
              checked={@sheet_user.admin}
              disabled={@sheet_user.id == @current_scope.user.id}
              class="h-4 w-4 shrink-0 rounded border-slate-300 dark:border-slate-600 accent-indigo-500 cursor-pointer disabled:cursor-not-allowed mt-0.5"
            />
            <span>
              <span class="block text-sm font-medium text-slate-900 dark:text-slate-100">Admin</span>
              <span class="block text-xs text-slate-500 dark:text-slate-400">
                Every project, and the settings screens.
              </span>
            </span>
          </label>

          <%!-- An admin's boxes are disabled and so not sent, which keeps their grants for if Admin is taken away. --%>
          <input :if={!@sheet_user.admin} type="hidden" name="user[project_ids][]" value="" />
          <.project_checklist
            id="user-sheet"
            name="user[project_ids][]"
            projects={@projects}
            checked_ids={@sheet_user.project_ids}
            all={@sheet_user.admin}
          />
        </form>
      </.side_sheet>

      <.side_sheet :if={@sheet == :invite} id="invite-sheet" label="Invite" on_close="close_sheet">
        <:header>
          <p class="py-1 text-base font-semibold text-slate-900 dark:text-slate-100">Invite</p>
        </:header>

        <form
          id="invite-form"
          phx-submit="invite"
          phx-change="invite_form_change"
          class="space-y-5"
        >
          <.input
            id="invite-email-input"
            name="email"
            type="email"
            label="Email address"
            value={@invite_email}
            placeholder="teammate@example.com"
            phx-debounce="300"
            data-qa="invite_email_input"
          />

          <label class="flex items-center gap-3 cursor-pointer">
            <input
              type="checkbox"
              name="admin"
              id="invite-admin-checkbox"
              checked={@invite_admin}
              class="h-4 w-4 shrink-0 rounded border-slate-300 dark:border-slate-600 accent-indigo-500 cursor-pointer"
            />
            <span class="text-sm font-medium text-slate-900 dark:text-slate-100">Admin</span>
          </label>

          <input type="hidden" name="project_ids[]" value="" />
          <.project_checklist
            id="invite-sheet"
            name="project_ids[]"
            projects={@projects}
            checked_ids={@invite_project_ids}
            all={@invite_admin}
          />

          <.button
            type="submit"
            variant="primary"
            id="send-invite-button"
            data-qa="send_invite_button"
            phx-disable-with="Inviting..."
            class="w-full"
          >
            <.icon name="pi-envelope-simple" class="h-3.5 w-3.5" /> Invite
          </.button>
        </form>
      </.side_sheet>
    </Layouts.app>
    """
  end

  def handle_event("open_user", %{"user_id" => user_id}, socket) do
    socket =
      if Enum.any?(socket.assigns.users, &(&1.id == user_id)),
        do: socket |> assign(:sheet, :user) |> assign(:sheet_user_id, user_id) |> assign_sheet_user(),
        else: socket

    {:noreply, socket}
  end

  def handle_event("open_invite", _params, socket) do
    socket =
      socket
      |> assign(:sheet, :invite)
      |> assign(:sheet_user_id, nil)
      |> assign_sheet_user()

    {:noreply, socket}
  end

  def handle_event("close_sheet", _params, socket) do
    socket =
      socket
      |> assign(:sheet, nil)
      |> assign(:sheet_user_id, nil)
      |> assign_sheet_user()

    {:noreply, socket}
  end

  def handle_event("update_access", %{"user_id" => user_id} = params, socket) do
    scope = socket.assigns.current_scope
    user = Enum.find(socket.assigns.users, &(&1.id == user_id))
    # Changing your own admin flag is how an admin locks themselves out.
    attrs = params |> Map.get("user", %{}) |> then(&if(user_id == scope.user.id, do: Map.delete(&1, "admin"), else: &1))

    if user, do: update_access(socket, scope, user, attrs), else: {:noreply, socket}
  end

  # Admin ticks and disables every project, so while it is or just was ticked the boxes say nothing of the grants.
  def handle_event("invite_form_change", params, socket) do
    admin = Map.get(params, "admin") == "on"
    keep_ticks? = admin or socket.assigns.invite_admin

    socket =
      socket
      |> assign(:invite_email, Map.get(params, "email") || "")
      |> assign(:invite_admin, admin)
      |> assign(
        :invite_project_ids,
        if(keep_ticks?, do: socket.assigns.invite_project_ids, else: params["project_ids"] || [])
      )

    {:noreply, socket}
  end

  def handle_event("invite", params, socket) do
    scope = socket.assigns.current_scope

    attrs = %{
      email: Map.get(params, "email") || "",
      admin: Map.get(params, "admin") == "on",
      project_ids: params["project_ids"] || []
    }

    case Users.invite_user(scope, attrs) do
      {:ok, _invite} ->
        socket =
          socket
          |> assign(:sheet, nil)
          |> assign(:invite_email, "")
          |> assign(:invite_admin, false)
          |> assign(:invite_project_ids, [])
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

  # Another admin's save, an invite or a sign-in, so the list and the open sheet show it without a reload.
  def handle_info({:users_changed, _id}, socket) do
    {:noreply, load_directory(socket, socket.assigns.current_scope)}
  end

  attr :id, :string, required: true
  attr :admin, :boolean, required: true
  attr :names, :list, required: true

  defp access_summary(%{admin: true} = assigns) do
    ~H"""
    <span id={@id} class="inline-flex items-center gap-1.5 text-slate-500 dark:text-slate-400">
      <.icon name="pi-shield-check" class="h-3.5 w-3.5" />All projects
    </span>
    """
  end

  defp access_summary(%{names: []} = assigns) do
    ~H"""
    <span id={@id} class="text-slate-500 dark:text-slate-400">No projects</span>
    """
  end

  defp access_summary(assigns) do
    assigns = assign(assigns, :summary, Enum.join(assigns.names, ", "))

    ~H"""
    <span id={@id} class="block truncate text-slate-800 dark:text-slate-200" title={@summary}>
      {@summary}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :projects, :list, required: true
  attr :checked_ids, :list, required: true
  attr :all, :boolean, required: true

  defp project_checklist(assigns) do
    ~H"""
    <div>
      <p class="mb-2 text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400">
        Projects
      </p>
      <div class="rounded-lg border border-slate-200 dark:border-slate-700 divide-y divide-slate-200 dark:divide-slate-700 overflow-hidden bg-white dark:bg-slate-900/40">
        <label
          :for={project <- @projects}
          id={"#{@id}-row-#{project.id}"}
          class={[
            "flex items-center gap-3 px-3.5 py-2.5 hover:bg-slate-100 dark:hover:bg-slate-700/50 cursor-pointer",
            !project.active && "opacity-60"
          ]}
        >
          <input
            type="checkbox"
            id={"#{@id}-project-#{project.id}"}
            name={@name}
            value={project.id}
            checked={@all or project.id in @checked_ids}
            disabled={@all}
            class="h-4 w-4 shrink-0 rounded border-slate-300 dark:border-slate-600 accent-indigo-500 cursor-pointer disabled:cursor-not-allowed"
          />
          <span class="flex-1 min-w-0">
            <span class="block text-sm text-slate-900 dark:text-slate-100 truncate">{project.name}</span>
            <span class="block font-mono text-[11px] text-slate-500 dark:text-slate-400 truncate">
              {project.github_repo}
            </span>
          </span>
          <.project_badge :if={project.active} project={project} />
          <span :if={!project.active} class="text-[11px] text-slate-500 dark:text-slate-400">
            Inactive
          </span>
        </label>
      </div>
    </div>
    """
  end

  attr :user, :any, required: true
  attr :size, :string, required: true
  attr :id_prefix, :string, default: "user"

  defp avatar(assigns) do
    ~H"""
    <img
      :if={@user.avatar_url}
      src={@user.avatar_url}
      alt={@user.name || @user.login}
      class={["rounded-full shrink-0", @size]}
      id={"#{@id_prefix}-avatar-#{@user.id}"}
    />
    <div
      :if={!@user.avatar_url}
      class={[
        "rounded-full bg-slate-100 dark:bg-slate-700 flex items-center justify-center text-slate-500 dark:text-slate-300 font-bold shrink-0",
        @size
      ]}
      id={"#{@id_prefix}-placeholder-#{@user.id}"}
    >
      {initials_for(@user)}
    </div>
    """
  end

  attr :user, :any, required: true
  attr :id_prefix, :string, default: "user"

  defp linear_badge(assigns) do
    ~H"""
    <span
      :if={linear_connected?(@user)}
      id={"#{@id_prefix}-linear-badge-#{@user.id}"}
      class="inline-flex items-center rounded-md bg-blue-50 dark:bg-blue-400/10 px-2 py-1 text-xs font-medium text-blue-700 dark:text-blue-300 ring-1 ring-inset ring-blue-700/10 dark:ring-blue-400/30 whitespace-nowrap"
    >
      Linear: {@user.linear_name || "Linked"}
    </span>
    <span
      :if={!linear_connected?(@user)}
      id={"#{@id_prefix}-linear-badge-#{@user.id}"}
      class="inline-flex items-center rounded-md bg-slate-100 dark:bg-slate-700 px-2 py-1 text-xs font-medium text-slate-500 dark:text-slate-400 ring-1 ring-inset ring-zinc-500/10 whitespace-nowrap"
    >
      Linear: Not Linked
    </span>
    """
  end

  slot :inner_block, required: true

  defp th(assigns) do
    ~H"""
    <th class="px-4 py-2.5 text-left text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400 whitespace-nowrap">
      {render_slot(@inner_block)}
    </th>
    """
  end

  defp update_access(socket, scope, user, attrs) do
    case Users.update_user(scope, user, attrs) do
      {:ok, _updated_user} ->
        socket =
          socket
          |> assign(:error_message, nil)
          |> load_directory(scope)

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
    |> assign_sheet_user()
  end

  # The sheet reads the person from the list, so a reload of the list refreshes the sheet too.
  defp assign_sheet_user(socket) do
    assign(socket, :sheet_user, Enum.find(socket.assigns.users, &(&1.id == socket.assigns.sheet_user_id)))
  end

  # In the switcher's order, leaving out an id that names no project.
  defp project_names(projects, project_ids) do
    for project <- projects, project.id in project_ids, do: project.name
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
    case String.split(user.name || user.login || "", ~r/\s+/, trim: true) do
      [] -> "U"
      words -> words |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
    end
  end
end
