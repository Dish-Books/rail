defmodule RailWeb.Components.LearningFormModal do
  @moduledoc """
  The form a person adds a rule with, or edits a rule or a proposal's draft
  with. A project is only asked for when adding under All projects.
  """
  use RailWeb, :html

  alias Rail.Learnings.Schemas.Learning

  attr :changeset, Ecto.Changeset, required: true
  attr :title, :string, required: true
  attr :projects, :list, default: []
  attr :project_id, :string, default: nil
  attr :show_project_picker, :boolean, default: false

  def learning_form_modal(assigns) do
    changeset = assigns.changeset

    errors =
      if changeset.action, do: Map.new(changeset.errors, fn {field, {message, _opts}} -> {field, message} end), else: %{}

    assigns =
      assigns
      |> assign(:errors, errors)
      |> assign(:roles, Ecto.Changeset.get_field(changeset, :roles) || [])
      |> assign(:kind, Ecto.Changeset.get_field(changeset, :kind))
      |> assign(:pinned, Ecto.Changeset.get_field(changeset, :pinned))
      |> assign(:project_options, for(project <- assigns.projects, project.active, do: {project.name, project.id}))

    ~H"""
    <div
      id="learning-form-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
      phx-window-keydown="close_form"
      phx-key="Escape"
    >
      <div class="w-full max-w-xl max-h-full overflow-y-auto rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-6">
        <div class="flex items-center justify-between border-b border-slate-200 dark:border-slate-700 pb-4">
          <h2 class="text-lg font-semibold text-slate-900 dark:text-slate-100">{@title}</h2>
          <button
            type="button"
            phx-click="close_form"
            id="close-learning-form"
            aria-label="Close"
            class="text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer"
          >
            <.icon name="pi-x" class="size-4" />
          </button>
        </div>

        <form
          id="learning-form"
          phx-change="validate_learning"
          phx-submit="save_learning"
          class="space-y-4"
        >
          <.input
            :if={@show_project_picker}
            type="select"
            label="Project"
            name="learning[project_id]"
            id="learning-project"
            options={@project_options}
            value={@project_id}
          />

          <.input
            type="textarea"
            label="Rule"
            name="learning[rule]"
            id="learning-rule-input"
            rows="3"
            value={Ecto.Changeset.get_field(@changeset, :rule)}
            placeholder="One instruction an agent can follow"
            errors={List.wrap(@errors[:rule])}
            phx-mounted={JS.focus()}
          />

          <.input
            type="textarea"
            label="Why"
            name="learning[why]"
            id="learning-why-input"
            rows="3"
            value={Ecto.Changeset.get_field(@changeset, :why)}
            placeholder="What breaks without it"
          />

          <div class="grid grid-cols-2 gap-4">
            <.input
              type="select"
              label="Kind"
              name="learning[kind]"
              id="learning-kind-input"
              options={Enum.map(Learning.kinds(), &{Learning.kind_label(&1), &1})}
              value={@kind}
              errors={List.wrap(@errors[:kind])}
            />
            <.input
              label="Path glob"
              name="learning[path_glob]"
              id="learning-glob-input"
              value={Ecto.Changeset.get_field(@changeset, :path_glob)}
              placeholder="lib/rail_web/**"
              class="font-mono"
            />
          </div>

          <fieldset>
            <legend class="text-xs font-medium text-slate-500 dark:text-slate-400 mb-1.5">
              Roles, none for every role
            </legend>
            <input type="hidden" name="learning[roles][]" value="" />
            <div class="flex flex-wrap gap-x-4 gap-y-2">
              <label
                :for={role <- Learning.roles()}
                class="inline-flex items-center gap-1.5 text-xs text-slate-700 dark:text-slate-200 cursor-pointer"
              >
                <input
                  type="checkbox"
                  name="learning[roles][]"
                  id={"learning-role-#{role}"}
                  value={role}
                  checked={role in @roles}
                  class="rounded border-slate-300 dark:border-slate-600"
                />
                {Learning.role_label(role)}
              </label>
            </div>
          </fieldset>

          <label class="inline-flex items-center gap-2 text-xs text-slate-600 dark:text-slate-300 cursor-pointer">
            <input type="hidden" name="learning[pinned]" value="false" />
            <input
              type="checkbox"
              role="switch"
              name="learning[pinned]"
              id="learning-pinned-input"
              value="true"
              checked={@pinned}
              class="peer sr-only"
            />
            <span class="relative h-5 w-9 shrink-0 rounded-full bg-slate-300 dark:bg-slate-600 transition-colors peer-checked:bg-indigo-600 after:absolute after:top-0.5 after:left-0.5 after:size-4 after:rounded-full after:bg-white after:transition-transform peer-checked:after:translate-x-4"></span>
            Pinned: every run of these roles is given it, whatever it is working on
          </label>

          <div class="flex items-center justify-end gap-3 pt-4 border-t border-slate-200 dark:border-slate-700">
            <.button type="button" phx-click="close_form" id="cancel-learning-button">Cancel</.button>
            <.button
              variant="primary"
              type="submit"
              id="save-learning-button"
              phx-disable-with="Saving…"
            >
              Save rule
            </.button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
