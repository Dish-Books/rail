defmodule RailWeb.Layouts do
  @moduledoc """
  Holds the layouts used by the application.

  `root.html.heex` is the HTML skeleton; `app/1` is the in-page chrome every
  authenticated LiveView wraps its content in.
  """
  use RailWeb, :html

  import RailWeb.Components.Nav

  embed_templates "layouts/*"

  @doc """
  Renders the authenticated app layout: navigation rail, top bar, and content.

  ## Examples

      <Layouts.app flash={@flash} current_section={:overview} ...>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_section, :atom, required: true
  attr :is_rail_extended, :boolean, required: true
  attr :attention_count, :integer, required: true
  attr :current_project_id, :string, required: true
  attr :projects, :list, required: true
  attr :theme, :string, required: true
  attr :show_project_switcher, :boolean, required: true
  attr :show_new_issue_modal, :boolean, required: true
  attr :capture_ask, :string, required: true
  attr :capture_project_id, :string, required: true
  attr :capture_priority, :any, required: true
  attr :capture_error, :string, required: true
  attr :capture_submitting, :boolean, required: true

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen w-screen overflow-hidden bg-white dark:bg-slate-900" id="app-scaffold">
      <.nav
        current_section={@current_section}
        is_rail_extended={@is_rail_extended}
        attention_count={@attention_count}
        current_project_id={@current_project_id}
      />

      <div class="flex flex-col flex-1 min-w-0 h-full overflow-hidden">
        <.top_app_bar
          current_section={@current_section}
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
        />

        <main class="flex-1 overflow-y-auto p-6" id="main-content">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end
end
