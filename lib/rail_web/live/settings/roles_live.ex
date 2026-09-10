defmodule RailWeb.Settings.RolesLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Backends
  alias Rail.Backends.Schemas.Backend
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.RoleInstructionProposal
  alias Rail.Roles.Schemas.Role

  @default_models %{
    claude: "claude-3-7-sonnet",
    agy: "gemini-3.8-flash-high"
  }

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    projects = Projects.list_projects(scope)

    socket =
      socket
      |> assign(:page_title, "Agent Roles")
      |> assign(:current_section, :roles)
      |> assign(:projects, projects)
      |> assign(:current_project_id, nil)
      |> assign(:current_project, nil)
      |> assign(:roles, [])
      |> assign(:canonical_stages, Role.canonical_stages())
      |> assign(:active_modal, nil)
      |> assign(:modal_role, nil)
      |> assign(:modal_form, nil)
      |> assign(:modal_errors, %{})
      |> assign(:available_models, [])
      |> assign(:improve_step, :setup)
      |> assign(:improve_runs, [])
      |> assign(:improve_model, nil)
      |> assign(:improve_logs, [])
      |> assign(:improve_proposal, nil)
      |> assign(:improve_error, nil)
      |> assign(:improve_task, nil)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    projects = socket.assigns.projects

    selected_project_id =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" ->
          id

        _other ->
          case Enum.find(projects, & &1.active) || List.first(projects) do
            %{id: id} -> id
            nil -> nil
          end
      end

    current_project = Enum.find(projects, &(&1.id == selected_project_id))
    roles = if selected_project_id, do: Roles.list_roles(scope, selected_project_id), else: []

    socket =
      socket
      |> assign(:page_title, "Agent Roles")
      |> assign(:current_section, :roles)
      |> assign(:current_project_id, selected_project_id)
      |> assign(:current_project, current_project)
      |> assign(:roles, roles)

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
      <div class="max-w-5xl mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="roles-settings">
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
                  selected={project.id == @current_project_id}
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
              disabled={is_nil(@current_project_id) or length(@projects) < 2}
            >
              <.icon name="pi-copy" class="h-3.5 w-3.5" /> Copy From...
            </.button>

            <.button
              variant="primary"
              size="sm"
              phx-click="open_create_modal"
              id="add-custom-role-button"
              disabled={
                is_nil(@current_project_id) or Enum.empty?(unbound_stages(@canonical_stages, @roles))
              }
              title={
                if @current_project_id && Enum.empty?(unbound_stages(@canonical_stages, @roles)),
                  do: "Every stage already has a role",
                  else: nil
              }
            >
              <.icon name="pi-plus" class="h-3.5 w-3.5" /> Add Role
            </.button>
          </div>
        </div>

        <div
          :if={is_nil(@current_project_id)}
          class="p-8 text-center text-slate-500 dark:text-slate-400 text-sm bg-slate-50 dark:bg-slate-800 rounded-lg border border-slate-200 dark:border-slate-700"
          id="no-projects-message"
        >
          No projects registered yet. Register a project in the Projects tab first.
        </div>

        <!-- Pipeline Stage List Section -->
        <section
          :if={@current_project_id}
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
                >
                  {stage_initials(stage)}
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
                      {bound_role.cli_backend}
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
                    variant="accent"
                    size="sm"
                    class="h-7"
                    id={"improve-role-button-#{bound_role.id}"}
                    data-qa={"improve_role_button_#{bound_role.id}"}
                    phx-click="open_improve_modal"
                    phx-value-role_id={bound_role.id}
                  >
                    <.icon name="pi-magic-wand" class="h-3.5 w-3.5" /> Improve
                  </.button>

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
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="role-editor-modal"
          data-qa="role-editor"
        >
          <div class="w-full max-w-2xl max-h-[90vh] overflow-y-auto rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-6">
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-4">
              <h2
                class="text-lg font-semibold text-slate-900 dark:text-slate-100"
                id="role-modal-title"
              >
                {if @active_modal == :create_role,
                  do: "Create New Role",
                  else: "Edit Role: #{@modal_role.name}"}
              </h2>
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

            <form phx-change="validate_role" phx-submit="save_role" id="role-form" class="space-y-4">
              <!-- Identifier -->
              <div>
                <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Role Identifier</label>
                <input
                  type="text"
                  name="role[role_id]"
                  id="role-identifier-input"
                  value={@modal_form["role_id"]}
                  disabled={@active_modal == :edit_role}
                  placeholder="e.g. security_auditor"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs disabled:bg-slate-100 dark:disabled:bg-slate-700 disabled:text-slate-500 dark:disabled:text-slate-400"
                />
              </div>

              <!-- Name -->
              <div>
                <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Role Display Name *</label>
                <input
                  type="text"
                  name="role[name]"
                  id="role-name-input"
                  value={@modal_form["name"]}
                  required
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs"
                />
                <span :if={@modal_errors[:name]} class="text-xs text-red-600" id="role-name-error">
                  {@modal_errors[:name]}
                </span>
              </div>

              <!-- Description -->
              <div>
                <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Description</label>
                <input
                  type="text"
                  name="role[description]"
                  id="role-description-input"
                  value={@modal_form["description"]}
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs"
                />
              </div>

              <div class="grid grid-cols-2 gap-4">
                <!-- Stage Binding -->
                <div>
                  <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Stage Binding</label>
                  <select
                    name="role[stage]"
                    id="role-stage-select"
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs capitalize"
                  >
                    <option
                      :for={stage <- @canonical_stages}
                      value={to_string(stage)}
                      selected={to_string(@modal_form["stage"]) == to_string(stage)}
                    >
                      {stage_display_name(stage)}
                    </option>
                  </select>
                </div>

                <!-- CLI Backend -->
                <div>
                  <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">CLI Backend</label>
                  <select
                    name="role[cli_backend]"
                    id="role-backend-select"
                    phx-change="change_backend"
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs"
                  >
                    <option value="claude" selected={@modal_form["cli_backend"] == "claude"}>
                      Claude Code (claude -p)
                    </option>
                    <option value="agy" selected={@modal_form["cli_backend"] == "agy"}>
                      Antigravity (agy -p)
                    </option>
                  </select>
                </div>
              </div>

              <!-- Model Dropdown + Custom Field -->
              <div class="space-y-2">
                <div class="flex items-center justify-between">
                  <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Model *</label>
                  <.link
                    navigate={~p"/settings/backends"}
                    id="manage-models-link"
                    class="text-[11px] text-indigo-600 hover:text-indigo-800"
                  >
                    Manage models
                  </.link>
                </div>

                <select
                  name="role[model_choice]"
                  id="role-model-select"
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs"
                >
                  <option
                    :for={model <- model_options(@available_models, @modal_form["model"])}
                    value={model.id}
                    selected={@modal_form["model"] == model.id}
                  >
                    {model.display_name}
                  </option>
                </select>
                <span :if={@modal_errors[:model]} class="text-xs text-red-600" id="role-model-error">
                  {@modal_errors[:model]}
                </span>
              </div>

              <div class="grid grid-cols-2 gap-4">
                <!-- Reasoning Effort -->
                <div>
                  <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Reasoning Effort</label>
                  <select
                    name="role[reasoning_effort]"
                    id="role-effort-select"
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs"
                  >
                    <option value="max" selected={@modal_form["reasoning_effort"] == "max"}>
                      Max (Correctness over cost)
                    </option>
                    <option value="xhigh" selected={@modal_form["reasoning_effort"] == "xhigh"}>
                      X-High (Best for agentic work)
                    </option>
                    <option
                      value="high"
                      selected={@modal_form["reasoning_effort"] in ["high", nil, ""]}
                    >
                      High (Deep reasoning)
                    </option>
                    <option value="medium" selected={@modal_form["reasoning_effort"] == "medium"}>
                      Medium
                    </option>
                    <option value="low" selected={@modal_form["reasoning_effort"] == "low"}>
                      Low (Fast)
                    </option>
                  </select>
                </div>

                <!-- Max Concurrent -->
                <div>
                  <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Max Concurrent</label>
                  <input
                    type="number"
                    min="1"
                    name="role[max_concurrent]"
                    id="role-max-concurrent-input"
                    value={@modal_form["max_concurrent"] || 1}
                    class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs"
                  />
                </div>
              </div>

              <!-- System Prompt Textarea -->
              <div>
                <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">
                  System Prompt Instructions & Guidelines *
                </label>
                <textarea
                  name="role[system_prompt]"
                  id="role-prompt-input"
                  rows="12"
                  required
                  class="mt-1 block w-full font-mono text-xs rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500"
                >{@modal_form["system_prompt"]}</textarea>
                <span
                  :if={@modal_errors[:system_prompt]}
                  class="text-xs text-red-600"
                  id="role-prompt-error"
                >
                  {@modal_errors[:system_prompt]}
                </span>
              </div>

              <!-- Modal Footer -->
              <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
                <.button phx-click="close_modal" id="cancel-role-button">
                  Cancel
                </.button>
                <.button variant="primary" type="submit" id="save-role-button">
                  Save Role Config
                </.button>
              </div>
            </form>
          </div>
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
                    :for={project <- Enum.filter(@projects, &(&1.id != @current_project_id))}
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

        <!-- Improve Role Modal (3-Step Flow) -->
        <div
          :if={@active_modal == :improve_role}
          class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
          id="improve-role-modal"
          data-qa="improve_role_modal"
        >
          <div class="w-full max-w-3xl max-h-[90vh] flex flex-col rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-4">
            <!-- Modal Header -->
            <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-3 shrink-0">
              <div class="flex items-center space-x-2">
                <.icon name="pi-magic-wand" class="h-5 w-5 text-indigo-600" />
                <h2
                  class="text-lg font-semibold text-slate-900 dark:text-slate-100"
                  id="improve-modal-header-title"
                >
                  {case @improve_step do
                    :setup -> "Improve #{@modal_role.name} Instructions"
                    :running -> "Improving #{@modal_role.name} Instructions..."
                    :proposal -> "Proposed Instructions for #{@modal_role.name}"
                  end}
                </h2>
              </div>
              <.button
                variant="ghost"
                size="icon"
                phx-click="cancel_improvement"
                id="close-improve-modal-button"
                aria-label="Close"
              >
                <.icon name="pi-x" class="h-4 w-4" />
              </.button>
            </div>

            <!-- Error Banner if any -->
            <div
              :if={@improve_error}
              class="p-3 bg-red-50 text-xs text-red-700 rounded-md shrink-0"
              id="improve-error-banner"
            >
              {@improve_error}
            </div>

            <!-- STEP 1: SETUP -->
            <div
              :if={@improve_step == :setup}
              class="space-y-4 overflow-y-auto flex-1"
              id="improve-step-setup"
            >
              <!-- Empty Evidence State -->
              <div
                :if={Enum.empty?(@improve_runs)}
                class="p-8 text-center space-y-3"
                id="no-runs-evidence-state"
              >
                <.icon
                  name="pi-clock-counter-clockwise"
                  class="h-12 w-12 text-slate-500 dark:text-slate-400 mx-auto"
                />
                <h3
                  class="text-base font-semibold text-slate-900 dark:text-slate-100"
                  id="no-runs-title"
                >
                  No finished runs for this role yet
                </h3>
                <p
                  class="text-xs text-slate-500 dark:text-slate-400 max-w-sm mx-auto"
                  id="no-runs-message"
                >
                  Run some tasks with {@modal_role.name} to generate evidence for role improvements.
                </p>
              </div>

              <!-- Populated Evidence State -->
              <div
                :if={not Enum.empty?(@improve_runs)}
                class="space-y-4"
                id="populated-runs-evidence-state"
              >
                <div
                  class="p-3 bg-indigo-50 border border-indigo-100 rounded-lg flex items-center space-x-2"
                  id="evidence-found-banner"
                >
                  <.icon name="pi-chart-line-up" class="h-5 w-5 text-indigo-600 shrink-0" />
                  <span class="text-xs font-semibold text-indigo-900" id="evidence-found-text">
                    Found {length(@improve_runs)} recent finished {if length(@improve_runs) == 1,
                      do: "run",
                      else: "runs"} to learn from.
                  </span>
                </div>

                <!-- Model Selector -->
                <div class="space-y-1">
                  <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">Improvement Model</label>
                  <p class="text-[11px] text-slate-500 dark:text-slate-400">
                    Select the model to analyze past runs and propose refined instructions:
                  </p>
                  <form phx-change="select_improve_model" id="improve-model-form">
                    <select
                      name="improve_model"
                      id="improve-model-select"
                      class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs"
                    >
                      <option
                        :for={model <- @available_models}
                        value={model.id}
                        selected={@improve_model == model.id}
                      >
                        {model.display_name}
                      </option>
                    </select>
                  </form>
                </div>

                <!-- Evidence Runs List -->
                <div class="space-y-2">
                  <h4 class="text-xs font-semibold text-slate-900 dark:text-slate-100">
                    Evidence to be analyzed:
                  </h4>
                  <ul
                    class="divide-y divide-slate-200 dark:divide-slate-700 border border-slate-200 dark:border-slate-700 rounded-md overflow-hidden"
                    id="evidence-runs-list"
                  >
                    <li
                      :for={run <- @improve_runs}
                      class="p-3 flex items-center space-x-3 text-xs"
                      id={"evidence-run-#{run.task_id}"}
                    >
                      <.icon
                        name={
                          if run.status in [:finished, :completed],
                            do: "pi-check-circle-fill",
                            else: "pi-x-circle-fill"
                        }
                        class={[
                          "h-4 w-4 shrink-0",
                          if(run.status in [:finished, :completed],
                            do: "text-green-600",
                            else: "text-red-600"
                          )
                        ]}
                      />
                      <div class="min-w-0 flex-1">
                        <p class="font-medium text-slate-900 dark:text-slate-100 truncate">
                          {run.title}
                        </p>
                        <p class="text-[11px] text-slate-500 dark:text-slate-400 mt-0.5">
                          Finished {format_run_time(run.completed_at)} • Status: {run.status} • Stage: {run.stage}
                        </p>
                      </div>
                    </li>
                  </ul>
                </div>
              </div>
            </div>

            <!-- STEP 2: RUNNING -->
            <div
              :if={@improve_step == :running}
              class="space-y-4 overflow-y-auto flex-1"
              id="improve-step-running"
            >
              <div class="flex items-center space-x-3 p-3 bg-indigo-50 rounded-lg">
                <.icon name="pi-arrow-clockwise" class="h-5 w-5 text-indigo-600 animate-spin" />
                <span class="text-sm font-medium text-indigo-900" id="running-analysis-message">
                  Running analysis and drafting proposed instructions...
                </span>
              </div>

              <div
                class="p-3 bg-zinc-900 text-zinc-100 rounded-lg font-mono text-xs h-64 overflow-y-auto space-y-1"
                id="improve-log-box"
              >
                <div
                  :if={Enum.empty?(@improve_logs)}
                  class="text-slate-500 dark:text-slate-400 italic"
                >
                  Waiting for CLI output...
                </div>
                <div :for={log <- @improve_logs} class="whitespace-pre-wrap">{log}</div>
              </div>
            </div>

            <!-- STEP 3: PROPOSAL -->
            <div
              :if={@improve_step == :proposal && @improve_proposal}
              class="space-y-4 overflow-y-auto flex-1"
              id="improve-step-proposal"
            >
              <!-- Warnings -->
              <% is_role_missing = is_nil(Enum.find(@roles, &(&1.id == @modal_role.id))) %>
              <% current_role = Enum.find(@roles, &(&1.id == @modal_role.id)) %>
              <% was_modified_on_disk =
                !is_role_missing && current_role.system_prompt != @improve_proposal.current %>

              <div
                :if={is_role_missing}
                class="p-3 bg-red-50 text-xs text-red-700 border border-red-200 rounded-md"
                id="role-missing-warning"
              >
                Role "{@modal_role.name}" was removed on disk. Cannot approve changes.
              </div>

              <div
                :if={was_modified_on_disk}
                class="p-3 bg-amber-50 text-xs text-amber-800 border border-amber-200 rounded-md"
                id="modified-on-disk-warning"
              >
                Role instructions were modified on disk during the run. The diff below is shown against current saved instructions.
              </div>

              <!-- Sources Chips -->
              <div
                :if={@improve_proposal.sources != []}
                class="p-3 bg-slate-100 dark:bg-slate-700 rounded-md space-y-1.5"
                id="proposal-sources-box"
              >
                <span class="text-xs font-semibold text-slate-900 dark:text-slate-100">
                  Drawn from {length(@improve_proposal.sources)} past {if length(
                                                                            @improve_proposal.sources
                                                                          ) == 1,
                                                                          do: "run",
                                                                          else: "runs"}:
                </span>
                <div class="flex flex-wrap gap-1.5">
                  <span
                    :for={src <- @improve_proposal.sources}
                    class="inline-flex items-center px-2 py-0.5 rounded text-[11px] font-medium bg-slate-50 dark:bg-slate-800 border border-slate-200 dark:border-slate-700 text-slate-900 dark:text-slate-100"
                  >
                    {src.title}
                  </span>
                </div>
              </div>

              <!-- Token Usage -->
              <div
                :if={@improve_proposal.usage && map_size(@improve_proposal.usage) > 0}
                class="text-xs text-slate-500 dark:text-slate-400 flex items-center space-x-1"
                id="proposal-usage-chip"
              >
                <.icon name="pi-chart-donut" class="h-3.5 w-3.5" />
                <span>
                  Improvement run cost: {@improve_proposal.usage["input_tokens"] || 0} input, {@improve_proposal.usage[
                    "output_tokens"
                  ] || 0} output tokens
                </span>
              </div>

              <!-- Rationale -->
              <div
                :if={@improve_proposal.rationale}
                class="p-3 bg-slate-100 dark:bg-slate-700 border border-slate-200 dark:border-slate-700 rounded-md"
                id="proposal-rationale-box"
              >
                <h4 class="text-xs font-bold uppercase tracking-wider text-slate-500 dark:text-slate-400 mb-1">
                  Rationale
                </h4>
                <p
                  class="text-xs text-slate-900 dark:text-slate-100 line-clamp-3"
                  id="proposal-rationale-text"
                >
                  {@improve_proposal.rationale}
                </p>
              </div>

              <!-- Diff Pane -->
              <div class="space-y-1" id="instruction-diff-container">
                <h4 class="text-xs font-semibold text-slate-900 dark:text-slate-100">
                  Instruction Changes (Diff)
                </h4>
                <pre
                  class="p-3 bg-zinc-900 text-zinc-100 rounded-md font-mono text-xs overflow-x-auto max-h-72"
                  id="instruction-diff-content"
                >{@improve_proposal.diff || "No changes between current and proposed instructions."}</pre>
              </div>
            </div>

            <!-- Improve Modal Footer -->
            <div class="flex items-center justify-end space-x-3 pt-3 border-t border-slate-200 dark:border-slate-700 shrink-0">
              <.button
                :if={@improve_step in [:setup, :proposal]}
                phx-click="cancel_improvement"
                id="improve-cancel-button"
              >
                {if @improve_step == :proposal, do: "Reject", else: "Cancel"}
              </.button>

              <.button
                :if={@improve_step == :running}
                variant="danger"
                phx-click="cancel_improvement"
                id="running-cancel-button"
              >
                Cancel
              </.button>

              <.button
                :if={@improve_step == :setup && not Enum.empty?(@improve_runs)}
                variant="primary"
                phx-click="start_improvement"
                id="start-improvement-button"
              >
                <.icon name="pi-magic-wand" class="h-4 w-4" /> Start
              </.button>

              <.button
                :if={@improve_step == :proposal}
                variant="success"
                phx-click="approve_proposal"
                id="approve-proposal-button"
                disabled={is_nil(Enum.find(@roles, &(&1.id == @modal_role.id)))}
              >
                Approve
              </.button>
            </div>
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

    backend = :claude
    models = fetch_models_for_backend(backend)
    default_model = @default_models[backend]

    form_data = %{
      "role_id" => "",
      "name" => stage_default_name(stage),
      "description" => "",
      "stage" => if(stage, do: to_string(stage), else: ""),
      "cli_backend" => to_string(backend),
      "model" => default_model,
      "reasoning_effort" => "high",
      "system_prompt" => "You are an agent persona.",
      "max_concurrent" => 1
    }

    socket =
      socket
      |> assign(:active_modal, :create_role)
      |> assign(:modal_role, nil)
      |> assign(:modal_form, form_data)
      |> assign(:modal_errors, %{})
      |> assign(:available_models, models)

    {:noreply, socket}
  end

  def handle_event("open_edit_modal", %{"role_id" => role_id}, socket) do
    role = Enum.find(socket.assigns.roles, &(&1.id == role_id))

    if role do
      backend = role.cli_backend
      models = fetch_models_for_backend(backend)

      form_data = %{
        "role_id" => role.id,
        "name" => role.name,
        "description" => role.description || "",
        "stage" => if(role.stage, do: to_string(role.stage), else: ""),
        "cli_backend" => to_string(role.cli_backend),
        "model" => role.model,
        "reasoning_effort" => if(role.reasoning_effort, do: to_string(role.reasoning_effort), else: "high"),
        "system_prompt" => role.system_prompt,
        "max_concurrent" => role.max_concurrent
      }

      socket =
        socket
        |> assign(:active_modal, :edit_role)
        |> assign(:modal_role, role)
        |> assign(:modal_form, form_data)
        |> assign(:modal_errors, %{})
        |> assign(:available_models, models)

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
      refreshed = Roles.list_roles(scope, socket.assigns.current_project_id)

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
    target_id = socket.assigns.current_project_id
    replace_all = params["replace_all"] in ["true", true]

    case Roles.copy_roles(scope, target_id, source_id, replace_all: replace_all) do
      {:ok, _roles} ->
        refreshed = Roles.list_roles(scope, target_id)

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
    backend = String.to_existing_atom(role_params["cli_backend"] || "claude")
    model_choice = role_params["model_choice"]
    chosen_model = model_choice || @default_models[backend]

    updated_form =
      socket.assigns.modal_form
      |> Map.merge(role_params)
      |> Map.put("model", chosen_model)

    {:noreply, assign(socket, :modal_form, updated_form)}
  end

  def handle_event("change_backend", %{"role" => %{"cli_backend" => backend_str}}, socket) do
    backend = String.to_existing_atom(backend_str)
    models = fetch_models_for_backend(backend)
    default_model = @default_models[backend]

    updated_form =
      socket.assigns.modal_form
      |> Map.put("cli_backend", backend_str)
      |> Map.put("model", default_model)

    socket =
      socket
      |> assign(:modal_form, updated_form)
      |> assign(:available_models, models)

    {:noreply, socket}
  end

  def handle_event("save_role", %{"role" => role_params}, socket) do
    scope = socket.assigns.current_scope
    project_id = socket.assigns.current_project_id
    modal = socket.assigns.active_modal
    existing_role = socket.assigns.modal_role

    attrs = build_role_attrs(role_params, existing_role, length(socket.assigns.roles))

    case execute_role_save(scope, project_id, modal, existing_role, attrs) do
      {:ok, _role} ->
        refreshed = Roles.list_roles(scope, project_id)

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

        socket = assign(socket, :modal_errors, errors)
        {:noreply, socket}
    end
  end

  def handle_event("open_improve_modal", %{"role_id" => role_id}, socket) do
    scope = socket.assigns.current_scope
    role = Enum.find(socket.assigns.roles, &(&1.id == role_id))

    if role do
      models = fetch_models_for_backend(role.cli_backend)
      runs = Roles.recent_finished_runs(scope, role.id)

      selected_model =
        if Enum.any?(models, &(&1.id == role.model)), do: role.model, else: List.first(models) && List.first(models).id

      socket =
        socket
        |> assign(:active_modal, :improve_role)
        |> assign(:modal_role, role)
        |> assign(:improve_step, :setup)
        |> assign(:improve_runs, runs)
        |> assign(:improve_model, selected_model || role.model)
        |> assign(:available_models, models)
        |> assign(:improve_logs, [])
        |> assign(:improve_proposal, nil)
        |> assign(:improve_error, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_improve_model", %{"improve_model" => model_id}, socket) do
    {:noreply, assign(socket, :improve_model, model_id)}
  end

  def handle_event("start_improvement", _params, socket) do
    scope = socket.assigns.current_scope
    role = socket.assigns.modal_role
    model = socket.assigns.improve_model || role.model

    task =
      Task.Supervisor.async_nolink(Rail.TaskSupervisor, fn ->
        Roles.improve_role(scope, role, model)
      end)

    socket =
      socket
      |> assign(:improve_step, :running)
      |> assign(:improve_task, task)
      |> assign(:improve_logs, ["Starting analysis with model #{model}..."])

    {:noreply, socket}
  end

  def handle_event("cancel_improvement", _params, socket) do
    if socket.assigns.improve_task do
      Task.shutdown(socket.assigns.improve_task, 1_000)
    end

    socket =
      socket
      |> assign(:active_modal, nil)
      |> assign(:improve_task, nil)
      |> assign(:improve_step, :setup)
      |> assign(:improve_proposal, nil)

    {:noreply, socket}
  end

  def handle_event("approve_proposal", _params, socket) do
    scope = socket.assigns.current_scope
    role_id = socket.assigns.modal_role.id
    current_role = Enum.find(socket.assigns.roles, &(&1.id == role_id))
    proposal = socket.assigns.improve_proposal

    if current_role && proposal do
      case Roles.apply_improved_instructions(scope, current_role, proposal.proposed) do
        {:ok, _updated_role} ->
          refreshed = Roles.list_roles(scope, socket.assigns.current_project_id)

          socket =
            socket
            |> assign(:roles, refreshed)
            |> assign(:active_modal, nil)
            |> assign(:improve_proposal, nil)

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, assign(socket, :improve_error, "Failed to apply improved instructions.")}
      end
    else
      {:noreply, assign(socket, :improve_error, "Role no longer exists.")}
    end
  end

  def handle_event("close_modal", _params, socket) do
    if socket.assigns.improve_task do
      Task.shutdown(socket.assigns.improve_task, 1_000)
    end

    socket =
      socket
      |> assign(:active_modal, nil)
      |> assign(:modal_role, nil)
      |> assign(:modal_form, nil)
      |> assign(:modal_errors, %{})
      |> assign(:improve_task, nil)

    {:noreply, socket}
  end

  def handle_info({ref, {:ok, %RoleInstructionProposal{} = proposal}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    roles = Roles.list_roles(socket.assigns.current_scope, socket.assigns.current_project_id)

    socket =
      socket
      |> assign(:roles, roles)
      |> assign(:improve_step, :proposal)
      |> assign(:improve_proposal, proposal)
      |> assign(:improve_task, nil)

    {:noreply, socket}
  end

  def handle_info({ref, {:error, reason}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    error_msg = "Improvement failed: #{inspect(reason)}"

    socket =
      socket
      |> assign(:improve_step, :setup)
      |> assign(:improve_error, error_msg)
      |> assign(:improve_task, nil)

    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
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
      available_models ++ [%{id: current, display_name: current}]
    end
  end

  defp fetch_models_for_backend(backend) do
    case Backends.get_backend(backend) do
      %Backend{models: models} -> models
      _unconfigured -> []
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
    qa_lead: "QA Lead",
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
  defp stage_display_name(:qa_lead), do: "QA Lead"

  defp stage_display_name(stage) do
    stage
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp stage_default_name(nil), do: ""
  defp stage_default_name(""), do: ""

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

  defp build_role_attrs(role_params, existing_role, roles_count) do
    backend = String.to_existing_atom(role_params["cli_backend"] || "claude")
    final_model = role_params["model_choice"] || @default_models[backend]

    stage =
      case role_params["stage"] do
        str when is_binary(str) and str != "" -> String.to_existing_atom(str)
        _other -> nil
      end

    %{
      name: String.trim(role_params["name"] || ""),
      description: String.trim(role_params["description"] || ""),
      stage: stage,
      cli_backend: backend,
      model: String.trim(final_model),
      reasoning_effort: parse_effort(role_params["reasoning_effort"]),
      system_prompt: String.trim(role_params["system_prompt"] || ""),
      max_concurrent: parse_int(role_params["max_concurrent"], 1),
      position: if(existing_role, do: existing_role.position, else: roles_count)
    }
  end

  defp execute_role_save(scope, project_id, :create_role, _existing_role, attrs) do
    Roles.create_role(scope, project_id, attrs)
  end

  defp execute_role_save(scope, _project_id, _modal, existing_role, attrs) do
    Roles.update_role(scope, existing_role, attrs)
  end

  defp format_run_time(nil), do: "recently"

  defp format_run_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
