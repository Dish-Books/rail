defmodule RailWeb.Settings.RolesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Mcp
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @default_models %{
    claude: "claude-opus-5-5",
    agy: "gemini-3.8-flash-high"
  }

  def mount(_params, _session, socket) do
    projects = Projects.list_projects()

    # The page always edits one project, so with none selected it takes the first.
    roles_project =
      Enum.find(projects, &(&1.id == socket.assigns.current_project_id)) ||
        Enum.find(projects, & &1.active) || List.first(projects)

    roles_project_id = roles_project && roles_project.id

    socket =
      socket
      |> assign(:page_title, "Agent Roles")
      |> assign(:current_section, :roles)
      |> assign(:projects, projects)
      |> assign(:roles_project_id, roles_project_id)
      |> assign(:roles_project, roles_project)
      |> assign(:roles, if(roles_project_id, do: Roles.list_roles(roles_project_id), else: []))
      |> assign(:backends, Tools.list_backends())
      |> assign(:mcp_servers, Mcp.list_servers())
      |> assign(:canonical_stages, Role.canonical_stages())
      |> assign(:active_modal, nil)
      |> assign(:modal_role, nil)
      |> assign(:modal_form, nil)
      |> assign(:modal_original, nil)
      |> assign(:modal_errors, %{})
      |> assign(:available_models, [])
      |> assign(:role_tab, :configuration)
      |> assign(:prompt_preview, false)
      |> assign(:expanded_mcp_servers, MapSet.new())

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

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
      <div class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="roles-settings">
        <div>
          <h1
            class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
            id="roles-title"
          >
            Agent Roles
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400" id="roles-subtitle">
            Configure stage bindings, models, reasoning effort, and system prompts.
          </p>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:roles} />

        <!-- Project Selector & Actions Bar -->
        <div
          class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4"
          id="roles-project-bar"
        >
          <div class="flex items-center space-x-3">
            <label
              class="text-sm font-medium text-slate-900 dark:text-slate-100"
              for="project-selector"
            >
              Project:
            </label>
            <form phx-change="select_project" id="project-selector-form">
              <select
                id="project-selector"
                name="project_id"
                class="rounded-md border-slate-200 dark:border-slate-700 py-1.5 pl-3 pr-8 text-sm focus:border-indigo-500 focus:outline-none focus:ring-indigo-500 font-medium"
              >
                <option
                  :for={project <- @projects}
                  value={project.id}
                  selected={project.id == @roles_project_id}
                >
                  {project.name}
                </option>
              </select>
            </form>
          </div>

          <div class="flex flex-wrap items-center gap-2" id="roles-top-actions">
            <.button
              size="sm"
              phx-click="open_copy_modal"
              id="copy-roles-button"
              disabled={is_nil(@roles_project_id) or length(@projects) < 2}
            >
              <.icon name="pi-copy" class="h-3.5 w-3.5" /> Copy From...
            </.button>

            <.button
              variant="primary"
              size="sm"
              phx-click="open_create_modal"
              id="add-custom-role-button"
              disabled={
                is_nil(@roles_project_id) or Enum.empty?(unbound_stages(@canonical_stages, @roles))
              }
              title={
                if @roles_project_id && Enum.empty?(unbound_stages(@canonical_stages, @roles)),
                  do: "Every stage already has a role",
                  else: nil
              }
            >
              <.icon name="pi-plus" class="h-3.5 w-3.5" /> Add Role
            </.button>
          </div>
        </div>

        <div
          :if={is_nil(@roles_project_id)}
          class="p-8 text-center text-slate-500 dark:text-slate-400 text-sm bg-slate-50 dark:bg-slate-800 rounded-lg border border-slate-200 dark:border-slate-700"
          id="no-projects-message"
        >
          No projects registered yet. Register a project in the Projects tab first.
        </div>

        <!-- Pipeline Stage List Section -->
        <section
          :if={@roles_project_id}
          class="bg-slate-50 dark:bg-slate-800 shadow rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden"
          id="pipeline-stages-section"
        >
          <ul
            role="list"
            class="divide-y divide-slate-200 dark:divide-slate-700"
            id="pipeline-stages-list"
          >
            <li
              :for={stage <- @canonical_stages}
              id={"stage-row-#{stage}"}
              data-qa={"role-card stage-row-#{stage}"}
              class="p-5 flex items-center justify-between hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors"
            >
              <% bound_role = role_for_stage(@roles, stage) %>
              <div class="flex items-center space-x-4 min-w-0">
                <div
                  class="flex items-center justify-center h-10 w-10 rounded-lg bg-slate-100 dark:bg-slate-700 text-slate-500 dark:text-slate-400 font-mono text-xs font-bold shrink-0 uppercase"
                  id={"stage-avatar-#{stage}"}
                  data-qa={"stage-avatar-#{stage}"}
                >
                  <.icon
                    :if={bound_role}
                    name={bound_role.icon_name}
                    class="h-5 w-5"
                  />
                  <span :if={is_nil(bound_role)}>{stage_initials(stage)}</span>
                </div>

                <div class="min-w-0">
                  <div class="flex items-center space-x-2">
                    <span
                      class="text-sm font-semibold text-slate-900 dark:text-slate-100 capitalize"
                      id={"stage-name-#{stage}"}
                    >
                      {stage_display_name(stage)}
                    </span>
                    <span class="text-[11px] font-mono text-slate-500 dark:text-slate-400">
                      ({stage})
                    </span>
                  </div>

                  <div
                    :if={bound_role}
                    class="flex items-center space-x-2 mt-1 text-xs text-slate-500 dark:text-slate-400"
                    id={"stage-role-details-#{stage}"}
                  >
                    <span
                      class="font-semibold text-slate-900 dark:text-slate-100"
                      id={"bound-role-name-#{stage}"}
                    >
                      {bound_role.name}
                    </span>
                    <span>•</span>
                    <span class="font-mono uppercase text-[10px] bg-slate-100 dark:bg-slate-700 px-1.5 py-0.5 rounded">
                      {bound_role.backend.name}
                    </span>
                    <span>•</span>
                    <span class="font-mono text-[11px]">
                      {bound_role.model}
                    </span>
                    <span :if={bound_role.reasoning_effort}>•</span>
                    <span
                      :if={bound_role.reasoning_effort}
                      class="text-slate-500 dark:text-slate-400 capitalize"
                    >
                      Effort: {bound_role.reasoning_effort}
                    </span>
                  </div>

                  <p
                    :if={bound_role && bound_role.description}
                    class="text-xs text-slate-500 dark:text-slate-400 mt-0.5 truncate max-w-md"
                  >
                    {bound_role.description}
                  </p>

                  <p
                    :if={is_nil(bound_role)}
                    class="text-xs text-slate-500 dark:text-slate-400 italic mt-0.5"
                    id={"unbound-stage-notice-#{stage}"}
                  >
                    No role bound
                  </p>
                </div>
              </div>

              <div class="flex items-center gap-1">
                <div :if={bound_role} class="flex items-center gap-1">
                  <.button
                    size="sm"
                    class="h-7"
                    id={"edit-role-button-#{bound_role.id}"}
                    data-qa={"edit_role_button_#{bound_role.id}"}
                    phx-click="open_edit_modal"
                    phx-value-role_id={bound_role.id}
                  >
                    Edit Role
                  </.button>

                  <.button
                    variant="ghost_danger"
                    size="icon"
                    id={"delete-role-button-#{bound_role.id}"}
                    data-qa={"delete_role_button_#{bound_role.id}"}
                    phx-click="open_delete_modal"
                    phx-value-role_id={bound_role.id}
                    title="Delete role"
                    aria-label="Delete role"
                  >
                    <.icon name="pi-trash" class="h-3.5 w-3.5" />
                  </.button>
                </div>

                <div :if={is_nil(bound_role)}>
                  <.button
                    size="sm"
                    class="h-7"
                    id={"assign-stage-button-#{stage}"}
                    data-qa={"assign_stage_button_#{stage}"}
                    phx-click="open_create_modal"
                    phx-value-stage={stage}
                  >
                    Assign or Create
                  </.button>
                </div>
              </div>
            </li>
          </ul>
        </section>

        <!-- ================= MODALS ================= -->

        <!-- Create / Edit Role Modal -->
        <div
          :if={@active_modal in [:create_role, :edit_role]}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/60 p-4"
          id="role-editor-modal"
          data-qa="role-editor"
        >
          <form
            phx-change="validate_role"
            phx-submit="save_role"
            id="role-form"
            class="flex h-[90vh] w-full max-w-5xl flex-col overflow-hidden rounded-2xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-900 shadow-2xl"
          >
            <div class="flex items-center justify-between gap-4 border-b border-slate-200 dark:border-slate-700/70 px-8 py-5">
              <div class="flex min-w-0 items-center gap-3">
                <h2
                  class="truncate text-xl font-semibold text-slate-900 dark:text-slate-100"
                  id="role-modal-title"
                >
                  {modal_title(@active_modal, @modal_form)}
                </h2>
                <span
                  :if={@modal_form["stage"] not in [nil, ""]}
                  id="role-stage-pill"
                  class="shrink-0 rounded-full border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800 px-2.5 py-0.5 font-mono text-xs text-slate-600 dark:text-slate-300"
                >
                  stage: {@modal_form["stage"]}
                </span>
              </div>
              <.button
                variant="ghost"
                size="icon"
                phx-click="close_modal"
                id="close-role-modal-button"
                aria-label="Close"
              >
                <.icon name="pi-x" class="h-4 w-4" />
              </.button>
            </div>

            <div class="flex min-h-0 flex-1">
              <aside class="flex w-64 shrink-0 flex-col justify-between gap-4 border-r border-slate-200 dark:border-slate-700/70 p-4">
                <nav class="space-y-1" id="role-editor-tabs">
                  <button
                    :for={tab <- [:configuration, :prompt, :mcp_tools]}
                    type="button"
                    phx-click="select_role_tab"
                    phx-value-tab={tab}
                    id={"role-tab-#{tab}"}
                    aria-current={if @role_tab == tab, do: "page"}
                    class={[
                      "block w-full rounded-lg px-4 py-3 text-left transition-colors",
                      @role_tab == tab && "bg-slate-100 dark:bg-slate-800",
                      @role_tab != tab && "hover:bg-slate-50 dark:hover:bg-slate-800/50"
                    ]}
                  >
                    <span class="block text-sm font-semibold text-slate-900 dark:text-slate-100">
                      {tab_title(tab)}
                    </span>
                    <span
                      class="mt-0.5 block truncate text-xs text-slate-500 dark:text-slate-400"
                      id={"role-tab-summary-#{tab}"}
                    >
                      {tab_summary(tab, @modal_form, @available_models, @mcp_servers)}
                    </span>
                  </button>
                </nav>

                <div
                  :if={@modal_role}
                  id="role-identifier-card"
                  class="rounded-lg border border-slate-200 dark:border-slate-700/70 bg-slate-50 dark:bg-slate-800/40 px-4 py-3"
                >
                  <p
                    class="truncate font-mono text-xs text-slate-600 dark:text-slate-300"
                    title={@modal_role.id}
                  >
                    {short_id(@modal_role.id)}
                  </p>
                  <button
                    type="button"
                    id="copy-role-identifier"
                    phx-hook="CopyText"
                    data-copy-text={@modal_role.id}
                    class="group mt-1 text-xs font-medium text-indigo-600 dark:text-indigo-300 hover:underline"
                  >
                    <span class="group-data-[copied]:hidden">Copy identifier</span>
                    <span class="hidden group-data-[copied]:inline">Copied</span>
                  </button>
                </div>
              </aside>

              <div class="min-h-0 flex-1 overflow-y-auto px-8 py-6">
                <!-- Configuration -->
                <div
                  id="role-panel-configuration"
                  class={["space-y-8", @role_tab != :configuration && "hidden"]}
                >
                  <section class="space-y-5">
                    <h3 class="font-mono text-xs uppercase tracking-[0.2em] text-slate-500 dark:text-slate-400">
                      Identity
                    </h3>

                    <.input
                      label="Display name"
                      name="role[name]"
                      id="role-name-input"
                      value={@modal_form["name"]}
                      errors={List.wrap(@modal_errors[:name])}
                      required
                    />

                    <div>
                      <.input
                        type="textarea"
                        label="Description"
                        name="role[description]"
                        id="role-description-input"
                        rows="2"
                        value={@modal_form["description"]}
                        class="resize-none"
                      />
                      <p class="mt-1.5 text-xs text-slate-500 dark:text-slate-400">
                        Shown on the issue card when this role is assigned.
                      </p>
                    </div>

                    <.input
                      type="select"
                      label="Stage binding"
                      name="role[stage]"
                      id="role-stage-select"
                      value={to_string(@modal_form["stage"])}
                      options={Enum.map(@canonical_stages, &{stage_display_name(&1), to_string(&1)})}
                    />
                  </section>

                  <div class="border-t border-slate-200 dark:border-slate-700/70"></div>

                  <section class="space-y-5">
                    <h3 class="font-mono text-xs uppercase tracking-[0.2em] text-slate-500 dark:text-slate-400">
                      Runtime
                    </h3>

                    <.input
                      type="select"
                      label="CLI backend"
                      name="role[backend_id]"
                      id="role-backend-select"
                      phx-change="change_backend"
                      value={@modal_form["backend_id"]}
                      prompt={if @backends == [], do: "No backend configured"}
                      options={Enum.map(@backends, &{backend_label(&1), &1.id})}
                    />

                    <div>
                      <div class="mb-1.5 flex items-center justify-between">
                        <label
                          for="role-model-select"
                          class="block text-sm font-medium text-slate-700 dark:text-slate-200"
                        >
                          Model
                        </label>
                        <.link
                          navigate={~p"/settings/backends"}
                          id="manage-models-link"
                          class="text-sm font-medium text-indigo-600 dark:text-indigo-300 hover:underline"
                        >
                          Manage models
                        </.link>
                      </div>
                      <.input
                        type="select"
                        name="role[model_choice]"
                        id="role-model-select"
                        value={@modal_form["model"]}
                        options={
                          Enum.map(
                            model_options(@available_models, @modal_form["model"]),
                            &{&1.display_name, &1.id}
                          )
                        }
                        errors={List.wrap(@modal_errors[:model])}
                      />
                    </div>

                    <div class="grid grid-cols-1 gap-5 sm:grid-cols-[1fr_11rem]">
                      <fieldset>
                        <legend class="mb-1.5 block text-sm font-medium text-slate-700 dark:text-slate-200">
                          Reasoning effort
                        </legend>
                        <div
                          class="flex gap-1 rounded-lg border border-slate-200 dark:border-slate-700/80 bg-white dark:bg-slate-950/60 p-1"
                          id="role-effort-options"
                        >
                          <label
                            :for={effort <- ["low", "medium", "high"]}
                            class="flex-1 cursor-pointer"
                          >
                            <input
                              type="radio"
                              name="role[reasoning_effort]"
                              value={effort}
                              id={"role-effort-#{effort}"}
                              checked={effort_value(@modal_form["reasoning_effort"]) == effort}
                              class="peer sr-only"
                            />
                            <span class="block rounded-md py-1 text-center text-[15px] leading-6 text-slate-600 dark:text-slate-300 peer-checked:bg-slate-100 peer-checked:font-medium peer-checked:text-slate-900 dark:peer-checked:bg-slate-700 dark:peer-checked:text-white peer-focus-visible:ring-2 peer-focus-visible:ring-indigo-500">
                              {String.capitalize(effort)}
                            </span>
                          </label>
                        </div>
                      </fieldset>

                      <.input
                        type="number"
                        label="Max concurrent"
                        min="1"
                        name="role[max_concurrent]"
                        id="role-max-concurrent-input"
                        value={@modal_form["max_concurrent"] || 1}
                      />
                    </div>
                  </section>
                </div>

                <!-- System prompt -->
                <div
                  id="role-panel-prompt"
                  class={["flex h-full flex-col gap-4", @role_tab != :prompt && "hidden"]}
                >
                  <div class="flex items-center justify-between gap-4">
                    <h3 class="text-base font-semibold text-slate-900 dark:text-slate-100">
                      System prompt
                    </h3>
                    <div class="flex items-center gap-3">
                      <span
                        class="font-mono text-xs text-slate-500 dark:text-slate-400"
                        id="role-prompt-chars"
                      >
                        {prompt_chars(@modal_form)} chars
                      </span>
                      <.button
                        size="sm"
                        phx-click="toggle_prompt_preview"
                        id="role-prompt-preview-button"
                      >
                        {if @prompt_preview, do: "Edit", else: "Preview"}
                      </.button>
                    </div>
                  </div>
                  <textarea
                    name="role[system_prompt]"
                    id="role-prompt-input"
                    phx-debounce="300"
                    class={[
                      "min-h-[24rem] w-full flex-1 resize-none rounded-lg border border-slate-200 dark:border-slate-700/80 bg-white dark:bg-slate-950/60 px-5 py-4 font-mono text-sm leading-7 text-slate-900 dark:text-slate-100 shadow-xs focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500",
                      @prompt_preview && "hidden"
                    ]}
                  >{@modal_form["system_prompt"]}</textarea>
                  <div
                    :if={@prompt_preview}
                    id="role-prompt-preview"
                    class="min-h-[24rem] flex-1 overflow-y-auto rounded-lg border border-slate-200 dark:border-slate-700/80 bg-white dark:bg-slate-950/60 px-6 py-5"
                  >
                    <.markdown content={@modal_form["system_prompt"]} />
                  </div>
                  <span
                    :if={@modal_errors[:system_prompt]}
                    class="text-xs text-red-600"
                    id="role-prompt-error"
                  >
                    {@modal_errors[:system_prompt]}
                  </span>
                </div>

                <!-- MCP tools -->
                <div
                  id="role-panel-mcp_tools"
                  class={["space-y-4", @role_tab != :mcp_tools && "hidden"]}
                >
                  <input type="hidden" name="role[mcp_tools][]" value="" />

                  <p
                    :if={@mcp_servers == []}
                    id="role-mcp-empty"
                    class="text-sm text-slate-500 dark:text-slate-400"
                  >
                    No MCP servers registered. Add one in <.link
                      navigate={~p"/settings/mcp-servers"}
                      class="font-medium text-indigo-600 dark:text-indigo-300 hover:underline"
                    >
                      MCP Servers settings
                    </.link>.
                  </p>

                  <div
                    :for={server <- @mcp_servers}
                    id={"role-mcp-server-#{server.name}"}
                    class="overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700/70"
                  >
                    <% all_tools = "#{server.name}__*" in (@modal_form["mcp_tools"] || []) %>
                    <% expanded = MapSet.member?(@expanded_mcp_servers, server.name) %>
                    <div class="flex items-center gap-4 px-5 py-4">
                      <input
                        type="checkbox"
                        name="role[mcp_tools][]"
                        value={"#{server.name}__*"}
                        id={"role-mcp-all-#{server.name}"}
                        checked={all_tools}
                        class="h-5 w-5 rounded border-slate-300 dark:border-slate-600 text-indigo-600 focus:ring-indigo-500"
                      />
                      <label
                        for={"role-mcp-all-#{server.name}"}
                        class="font-semibold text-slate-900 dark:text-slate-100"
                      >
                        {server.name}
                      </label>
                      <span
                        class="text-sm text-slate-500 dark:text-slate-400"
                        id={"role-mcp-summary-#{server.name}"}
                      >
                        {server_tools_summary(server, @modal_form["mcp_tools"])}
                      </span>
                      <button
                        :if={server.tools != []}
                        type="button"
                        phx-click="toggle_mcp_server"
                        phx-value-server={server.name}
                        id={"role-mcp-toggle-#{server.name}"}
                        class="ml-auto text-sm font-medium text-indigo-600 dark:text-indigo-300 hover:underline"
                      >
                        {if expanded, do: "Hide list", else: "Show list"}
                      </button>
                    </div>

                    <p
                      :if={server.tools == []}
                      class="border-t border-slate-200 dark:border-slate-700/70 px-5 py-3 text-xs text-slate-500 dark:text-slate-400"
                    >
                      No tools cached yet. Refresh them in MCP Servers settings.
                    </p>

                    <div
                      :if={server.tools != []}
                      id={"role-mcp-tools-#{server.name}"}
                      class={[
                        "grid grid-cols-1 gap-x-8 gap-y-3 border-t border-slate-200 dark:border-slate-700/70 px-5 py-4 sm:grid-cols-2",
                        !expanded && "hidden"
                      ]}
                    >
                      <label
                        :for={tool <- server.tools}
                        class={[
                          "flex items-center gap-3 font-mono text-sm text-slate-700 dark:text-slate-300",
                          all_tools && "opacity-70"
                        ]}
                        title={tool["description"]}
                      >
                        <input
                          type="checkbox"
                          name="role[mcp_tools][]"
                          value={"#{server.name}__#{tool["name"]}"}
                          id={"role-mcp-tool-#{server.name}__#{tool["name"]}"}
                          checked={
                            all_tools or
                              "#{server.name}__#{tool["name"]}" in (@modal_form["mcp_tools"] || [])
                          }
                          disabled={all_tools}
                          class="h-4 w-4 rounded border-slate-300 dark:border-slate-600 text-indigo-600 focus:ring-indigo-500"
                        />
                        <span class="truncate">{tool["name"]}</span>
                      </label>
                    </div>
                  </div>

                  <p :if={@mcp_servers != []} class="text-sm text-slate-500 dark:text-slate-400">
                    Called through Rail's proxy on the issue assignee's connection.
                  </p>
                </div>
              </div>
            </div>

            <div class="flex items-center justify-between gap-4 border-t border-slate-200 dark:border-slate-700/70 px-8 py-4">
              <% changes = unsaved_changes(@modal_original, @modal_form) %>
              <p
                id="role-unsaved-changes"
                class="flex min-w-0 items-center gap-2 truncate text-sm text-slate-500 dark:text-slate-400"
              >
                <span :if={changes != []} class="h-2 w-2 shrink-0 rounded-full bg-amber-400"></span>
                {unsaved_summary(changes)}
              </p>
              <div class="flex shrink-0 items-center gap-3">
                <.button phx-click="close_modal" id="cancel-role-button">Discard</.button>
                <.button variant="primary" type="submit" id="save-role-button">
                  {if @active_modal == :create_role, do: "Create role", else: "Save role"}
                </.button>
              </div>
            </div>
          </form>
        </div>

        <!-- Delete Role Modal -->
        <div
          :if={@active_modal == :delete_role}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="delete-role-modal"
        >
          <div class="w-full max-w-md rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-4">
            <h2
              class="text-base font-semibold text-slate-900 dark:text-slate-100"
              id="delete-modal-title"
            >
              Delete Role
            </h2>
            <p class="text-sm text-slate-500 dark:text-slate-400" id="delete-modal-message">
              Are you sure you want to delete role <strong id="delete-role-name">{@modal_role.name}</strong>? This action cannot be undone.
            </p>

            <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
              <.button phx-click="close_modal" id="cancel-delete-button">
                Cancel
              </.button>
              <.button variant="danger_solid" phx-click="delete_role" id="confirm-delete-button">
                Delete Role
              </.button>
            </div>
          </div>
        </div>

        <!-- Copy from Project Modal -->
        <div
          :if={@active_modal == :copy_roles}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="copy-roles-modal"
        >
          <div class="w-full max-w-md rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-4">
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-3">
              <h2 class="text-base font-semibold text-slate-900 dark:text-slate-100">
                Copy Roles from Project
              </h2>
              <.button variant="ghost" size="icon" phx-click="close_modal" aria-label="Close">
                <.icon name="pi-x" class="h-4 w-4" />
              </.button>
            </div>

            <form
              phx-submit="copy_roles"
              phx-change="validate_copy"
              id="copy-roles-form"
              class="space-y-4"
            >
              <div>
                <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Source Project</label>
                <select
                  name="source_project_id"
                  id="copy-source-project-select"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                >
                  <option
                    :for={project <- Enum.filter(@projects, &(&1.id != @roles_project_id))}
                    value={project.id}
                  >
                    {project.name}
                  </option>
                </select>
              </div>

              <div class="flex items-center space-x-2">
                <input
                  type="checkbox"
                  name="replace_all"
                  value="true"
                  id="copy-replace-all-checkbox"
                  class="rounded border-slate-200 dark:border-slate-700 text-indigo-600 focus:ring-indigo-500"
                />
                <label
                  for="copy-replace-all-checkbox"
                  class="text-xs text-slate-900 dark:text-slate-100"
                >
                  Replace all existing roles in current project
                </label>
              </div>

              <div class="flex items-center justify-end space-x-3 pt-3 border-t border-slate-200 dark:border-slate-700">
                <.button phx-click="close_modal" id="cancel-copy-button">
                  Cancel
                </.button>
                <.button variant="primary" type="submit" id="confirm-copy-button">
                  Copy Roles
                </.button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("open_create_modal", params, socket) do
    # Every role is stage-bound, so a create opened from the toolbar (no stage
    # param) starts on the first stage that has no role yet.
    stage =
      params["stage"] ||
        List.first(unbound_stages(socket.assigns.canonical_stages, socket.assigns.roles))

    backend = default_backend(socket.assigns.backends)
    models = models_for(backend)
    default_model = default_model_for(backend)

    form_data = %{
      "role_id" => "",
      "name" => stage_default_name(stage),
      "description" => "",
      "stage" => if(stage, do: to_string(stage), else: ""),
      "backend_id" => backend && backend.id,
      "model" => default_model,
      "reasoning_effort" => "high",
      "system_prompt" => "You are an agent persona.",
      "max_concurrent" => 1,
      "mcp_tools" => []
    }

    socket =
      socket
      |> assign(:active_modal, :create_role)
      |> assign(:modal_role, nil)
      |> assign(:modal_form, form_data)
      |> assign(:modal_original, form_data)
      |> assign(:modal_errors, %{})
      |> assign(:available_models, models)
      |> assign(:role_tab, :configuration)
      |> assign(:prompt_preview, false)
      |> assign(:expanded_mcp_servers, MapSet.new())

    {:noreply, socket}
  end

  def handle_event("open_edit_modal", %{"role_id" => role_id}, socket) do
    role = Enum.find(socket.assigns.roles, &(&1.id == role_id))

    if role do
      models = models_for(role.backend)

      form_data = %{
        "role_id" => role.id,
        "name" => role.name,
        "description" => role.description || "",
        "stage" => if(role.stage, do: to_string(role.stage), else: ""),
        "backend_id" => role.backend_id,
        "model" => role.model,
        "reasoning_effort" => if(role.reasoning_effort, do: to_string(role.reasoning_effort), else: "high"),
        "system_prompt" => role.system_prompt,
        "max_concurrent" => role.max_concurrent,
        "mcp_tools" => role.mcp_tools
      }

      socket =
        socket
        |> assign(:active_modal, :edit_role)
        |> assign(:modal_role, role)
        |> assign(:modal_form, form_data)
        |> assign(:modal_original, form_data)
        |> assign(:modal_errors, %{})
        |> assign(:available_models, models)
        |> assign(:role_tab, :configuration)
        |> assign(:prompt_preview, false)
        |> assign(:expanded_mcp_servers, MapSet.new())

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_delete_modal", %{"role_id" => role_id}, socket) do
    role = Enum.find(socket.assigns.roles, &(&1.id == role_id))

    socket =
      if role do
        socket
        |> assign(:active_modal, :delete_role)
        |> assign(:modal_role, role)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("delete_role", _params, socket) do
    scope = socket.assigns.current_scope
    role = socket.assigns.modal_role

    if role do
      {:ok, _role} = Roles.delete_role(scope, role)
      refreshed = Roles.list_roles(socket.assigns.roles_project_id)

      socket =
        socket
        |> assign(:roles, refreshed)
        |> assign(:active_modal, nil)
        |> assign(:modal_role, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_copy_modal", _params, socket) do
    socket = assign(socket, :active_modal, :copy_roles)
    {:noreply, socket}
  end

  def handle_event("validate_copy", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("copy_roles", %{"source_project_id" => source_id} = params, socket) do
    scope = socket.assigns.current_scope
    target_id = socket.assigns.roles_project_id
    replace_all = params["replace_all"] in ["true", true]

    case Roles.copy_roles(scope, target_id, source_id, replace_all: replace_all) do
      {:ok, _roles} ->
        refreshed = Roles.list_roles(target_id)

        socket =
          socket
          |> assign(:roles, refreshed)
          |> assign(:active_modal, nil)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_role", %{"role" => role_params}, socket) do
    backend = backend_by_id(socket.assigns.backends, role_params["backend_id"])
    model_choice = role_params["model_choice"]
    chosen_model = model_choice || default_model_for(backend)

    updated_form =
      socket.assigns.modal_form
      |> Map.merge(role_params)
      |> Map.put("model", chosen_model)

    {:noreply, assign(socket, :modal_form, updated_form)}
  end

  def handle_event("change_backend", %{"role" => %{"backend_id" => backend_id}}, socket) do
    backend = backend_by_id(socket.assigns.backends, backend_id)
    models = models_for(backend)

    updated_form =
      socket.assigns.modal_form
      |> Map.put("backend_id", backend_id)
      |> Map.put("model", default_model_for(backend))

    socket =
      socket
      |> assign(:modal_form, updated_form)
      |> assign(:available_models, models)

    {:noreply, socket}
  end

  def handle_event("save_role", %{"role" => role_params}, socket) do
    scope = socket.assigns.current_scope
    project_id = socket.assigns.roles_project_id
    modal = socket.assigns.active_modal
    existing_role = socket.assigns.modal_role

    attrs =
      build_role_attrs(role_params, existing_role, length(socket.assigns.roles), socket.assigns.backends)

    case execute_role_save(scope, socket.assigns.roles_project, modal, existing_role, attrs) do
      {:ok, _role} ->
        refreshed = Roles.list_roles(project_id)

        socket =
          socket
          |> assign(:roles, refreshed)
          |> assign(:active_modal, nil)
          |> assign(:modal_role, nil)
          |> assign(:modal_form, nil)
          |> assign(:modal_errors, %{})

        {:noreply, socket}

      {:error, changeset} ->
        errors =
          Map.new(changeset.errors, fn {k, {msg, _opts}} ->
            {k, msg}
          end)

        socket =
          socket
          |> assign(:modal_errors, errors)
          |> assign(:role_tab, error_tab(errors))

        {:noreply, socket}
    end
  end

  def handle_event("select_role_tab", %{"tab" => tab}, socket) when tab in ["configuration", "prompt", "mcp_tools"] do
    {:noreply, assign(socket, :role_tab, String.to_existing_atom(tab))}
  end

  def handle_event("toggle_prompt_preview", _params, socket) do
    {:noreply, assign(socket, :prompt_preview, !socket.assigns.prompt_preview)}
  end

  def handle_event("toggle_mcp_server", %{"server" => server_name}, socket) do
    expanded = socket.assigns.expanded_mcp_servers

    expanded =
      if MapSet.member?(expanded, server_name),
        do: MapSet.delete(expanded, server_name),
        else: MapSet.put(expanded, server_name)

    {:noreply, assign(socket, :expanded_mcp_servers, expanded)}
  end

  def handle_event("close_modal", _params, socket) do
    socket =
      socket
      |> assign(:active_modal, nil)
      |> assign(:modal_role, nil)
      |> assign(:modal_form, nil)
      |> assign(:modal_errors, %{})

    {:noreply, socket}
  end

  # The navigation hook subscribes this view to pipeline events it does not use.
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  # A role can hold a model that is no longer in its backend's configured list
  # (renamed model, hand-seeded role). Keep it selectable so opening the edit
  # modal never silently rewrites the stored model.
  defp model_options(available_models, current_model) do
    current = String.trim(to_string(current_model || ""))

    if current == "" or Enum.any?(available_models, &(&1.id == current)) do
      available_models
    else
      Enum.reverse([%{id: current, display_name: current} | Enum.reverse(available_models)])
    end
  end

  defp backend_by_id(backends, id) when is_binary(id) and id != "" do
    Enum.find(backends, &(&1.id == id))
  end

  defp backend_by_id(_backends, _id), do: nil

  # Backends list alphabetically, so the first row is not the one a new role should
  # start on. Claude is the default where it is configured.
  defp default_backend(backends) do
    Enum.find(backends, &(&1.name == :claude)) || List.first(backends)
  end

  defp models_for(%Backend{models: models}), do: models || []
  defp models_for(_unconfigured), do: []

  defp default_model_for(%Backend{name: name}), do: @default_models[name]
  defp default_model_for(_unconfigured), do: nil

  # Two backends of one kind are told apart by what the user called them, then
  # by the account signed in.
  defp backend_label(%Backend{name: name} = backend) do
    kind =
      case name do
        :claude -> "Claude Code (claude -p)"
        :agy -> "Antigravity (agy -p)"
        other -> to_string(other)
      end

    case Enum.find([backend.label, backend.account_label], &(&1 not in [nil, ""])) do
      account when is_binary(account) -> "#{kind} · #{account}"
      nil -> kind
    end
  end

  defp unbound_stages(canonical_stages, roles) do
    Enum.reject(canonical_stages, &role_for_stage(roles, &1))
  end

  defp role_for_stage(roles, stage) do
    Enum.find(roles, &(&1.stage == stage))
  end

  @default_role_names %{
    product: "Product Manager",
    architect: "Architect",
    engineer: "Engineer",
    review: "Reviewer",
    qa: "QA Engineer",
    demo: "Demo Recorder",
    debugger: "Debugger",
    design: "Designer"
  }

  @effort_map %{
    "max" => :high,
    "xhigh" => :high,
    "high" => :high,
    "medium" => :medium,
    "low" => :low
  }

  defp stage_display_name(:qa), do: "QA"

  defp stage_display_name(stage) do
    stage
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp stage_default_name(stage) when stage in [nil, ""], do: ""

  defp stage_default_name(stage) do
    stage_str = to_string(stage)

    atom =
      try do
        String.to_existing_atom(stage_str)
      rescue
        ArgumentError -> nil
      end

    Map.get(@default_role_names, atom, String.capitalize(stage_str))
  end

  defp stage_initials(stage) do
    stage
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp parse_effort(val), do: Map.get(@effort_map, val, :high)

  defp parse_int(val, default) do
    case Integer.parse(to_string(val)) do
      {num, _rem} -> num
      :error -> default
    end
  end

  defp build_role_attrs(role_params, existing_role, roles_count, backends) do
    backend = backend_by_id(backends, role_params["backend_id"])
    final_model = role_params["model_choice"] || default_model_for(backend)

    stage =
      case role_params["stage"] do
        str when is_binary(str) and str != "" -> String.to_existing_atom(str)
        _other -> nil
      end

    %{
      name: String.trim(role_params["name"] || ""),
      description: String.trim(role_params["description"] || ""),
      stage: stage,
      backend_id: backend && backend.id,
      model: String.trim(final_model || ""),
      reasoning_effort: parse_effort(role_params["reasoning_effort"]),
      system_prompt: String.trim(role_params["system_prompt"] || ""),
      max_concurrent: parse_int(role_params["max_concurrent"], 1),
      mcp_tools: parse_mcp_tools(role_params["mcp_tools"]),
      position: if(existing_role, do: existing_role.position, else: roles_count)
    }
  end

  # A server's "all tools" entry already covers each of its tools, so any it
  # makes redundant are dropped rather than stored alongside it.
  defp parse_mcp_tools(values) do
    tools = values |> List.wrap() |> Enum.reject(&(&1 == ""))
    all_tools_servers = for tool <- tools, String.ends_with?(tool, "__*"), do: String.trim_trailing(tool, "__*")

    Enum.reject(tools, fn tool ->
      [server_name, tool_name] = String.split(tool, "__", parts: 2)
      tool_name != "*" and server_name in all_tools_servers
    end)
  end

  @unsaved_fields [
    {"name", "name"},
    {"description", "description"},
    {"stage", "stage"},
    {"backend_id", "backend"},
    {"model", "model"},
    {"reasoning_effort", "reasoning effort"},
    {"system_prompt", "prompt"},
    {"max_concurrent", "max concurrent"},
    {"mcp_tools", "MCP tools"}
  ]

  defp modal_title(:create_role, _form), do: "New role"

  defp modal_title(_edit, form) do
    case String.trim(to_string(form["name"])) do
      "" -> "Untitled role"
      name -> name
    end
  end

  defp tab_title(:configuration), do: "Configuration"
  defp tab_title(:prompt), do: "System prompt"
  defp tab_title(:mcp_tools), do: "MCP tools"

  defp tab_summary(:configuration, form, models, _servers) do
    model = Enum.find_value(models, form["model"], &(&1.id == form["model"] && &1.display_name))

    ["Identity", model, effort_value(form["reasoning_effort"])]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp tab_summary(:prompt, form, _models, _servers), do: "#{prompt_chars(form)} chars"

  defp tab_summary(:mcp_tools, form, _models, servers) do
    enabled =
      Enum.flat_map(servers, fn server ->
        case server_tool_counts(server, form["mcp_tools"]) do
          {0, _total} -> []
          {:all, _total} -> ["#{server.name} · all"]
          {count, total} -> ["#{server.name} · #{count} of #{total}"]
        end
      end)

    if enabled == [], do: "None enabled", else: Enum.join(enabled, ", ")
  end

  # `:all` for a server whose tools are all allowed (even before any are cached),
  # otherwise how many of its cached tools are allowed one by one.
  defp server_tool_counts(server, mcp_tools) do
    mcp_tools = mcp_tools || []
    total = length(server.tools)

    cond do
      "#{server.name}__*" in mcp_tools and total == 0 -> {:all, 0}
      "#{server.name}__*" in mcp_tools -> {total, total}
      true -> {Enum.count(server.tools, &("#{server.name}__#{&1["name"]}" in mcp_tools)), total}
    end
  end

  defp server_tools_summary(server, mcp_tools) do
    case server_tool_counts(server, mcp_tools) do
      {:all, _total} -> "all tools enabled"
      {0, _total} -> "No tools enabled"
      {total, total} -> "all #{total} tools enabled"
      {count, total} -> "#{count} of #{total} tools enabled"
    end
  end

  defp effort_value(effort) when effort in ["low", "medium"], do: effort
  defp effort_value(_high), do: "high"

  defp prompt_chars(form), do: String.length(form["system_prompt"] || "")

  defp short_id(id), do: String.slice(id, 0, 11) <> "…" <> String.slice(id, -6, 6)

  defp unsaved_changes(original, form) do
    for {field, label} <- @unsaved_fields,
        normalize_field(field, original[field]) != normalize_field(field, form[field]),
        do: label
  end

  defp normalize_field("mcp_tools", tools), do: tools |> parse_mcp_tools() |> Enum.sort()
  defp normalize_field("reasoning_effort", effort), do: effort_value(effort)
  defp normalize_field(_field, value), do: value |> to_string() |> String.replace("\r\n", "\n") |> String.trim()

  defp unsaved_summary([]), do: "No unsaved changes"
  defp unsaved_summary([change]), do: "1 unsaved change · #{change}"
  defp unsaved_summary(changes), do: "#{length(changes)} unsaved changes · #{Enum.join(changes, ", ")}"

  defp error_tab(errors) do
    if Map.keys(errors) == [:system_prompt], do: :prompt, else: :configuration
  end

  defp execute_role_save(scope, project, :create_role, _existing_role, attrs) do
    Roles.create_role(scope, project, attrs)
  end

  defp execute_role_save(scope, _project, _modal, existing_role, attrs) do
    Roles.update_role(scope, existing_role, attrs)
  end
end
