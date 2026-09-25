defmodule RailWeb.Layouts do
  @moduledoc """
  Holds the layouts used by the application.

  `root.html.heex` is the HTML skeleton; `app/1` is the in-page chrome every
  authenticated LiveView wraps its content in.
  """
  use RailWeb, :html

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
  attr :current_scope, Rail.Scope, required: true
  attr :is_rail_extended, :boolean, required: true
  attr :attention_count, :integer, required: true
  attr :current_project_id, :string, required: true
  attr :projects, :list, required: true
  attr :theme, :string, required: true
  attr :show_project_switcher, :boolean, required: true

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen w-screen overflow-hidden bg-white dark:bg-slate-900" id="app-scaffold">
      <.nav
        current_section={@current_section}
        is_rail_extended={@is_rail_extended}
        attention_count={@attention_count}
      />

      <div class="flex flex-col flex-1 min-w-0 h-full overflow-hidden">
        <.top_app_bar
          current_section={@current_section}
          current_scope={@current_scope}
          current_project_id={@current_project_id}
          projects={@projects}
          theme={@theme}
          show_project_switcher={@show_project_switcher}
        />

        <main class="flex-1 overflow-y-auto p-6" id="main-content">
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="fixed top-16 right-5 z-50 space-y-2 max-w-sm">
        <div
          :for={{kind, message} <- @flash}
          id={"flash-#{kind}"}
          role="alert"
          phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: kind})}
          class={[
            "px-4 py-3 rounded-xl border text-sm shadow-lg cursor-pointer",
            kind == "error" &&
              "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950 text-red-800 dark:text-red-200",
            kind != "error" &&
              "border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 text-slate-800 dark:text-slate-200"
          ]}
        >
          {message}
        </div>
      </div>
    </div>
    """
  end
end
