defmodule RailWeb.Settings.AppearanceLive do
  @moduledoc false
  use RailWeb, :live_view

  def mount(_params, _session, socket) do
    theme = socket.assigns[:theme] || "dark"

    socket =
      socket
      |> assign(:page_title, "Appearance Settings")
      |> assign(:current_section, :appearance)
      |> assign(:selected_theme, theme)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> assign(:page_title, "Appearance Settings")
      |> assign(:current_section, :appearance)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="appearance-settings">
      <div>
        <h1 class="text-2xl font-bold tracking-tight text-zinc-900" id="appearance-title">
          Appearance
        </h1>
        <p class="mt-1 text-sm text-zinc-500" id="appearance-subtitle">
          Customize the interface appearance and theme mode.
        </p>
      </div>

      <.settings_nav current_scope={@current_scope} active_tab={:appearance} />

      <!-- Appearance Card -->
      <section
        class="bg-white shadow rounded-lg p-6 border border-zinc-200 space-y-4"
        id="appearance-card"
        data-qa="appearance_card"
      >
        <div>
          <h2 class="text-base font-semibold text-zinc-900" id="appearance-card-title">
            Appearance
          </h2>
          <p class="text-xs text-zinc-500 mt-0.5">
            Select how Rail displays on your device.
          </p>
        </div>

        <!-- Segmented Button for System, Light, Dark -->
        <div
          class="inline-flex rounded-lg border border-zinc-200 bg-zinc-50 p-1 space-x-1 select-none"
          role="group"
          aria-label="Theme selection"
          id="theme-segmented-button"
        >
          <button
            type="button"
            id="theme-segment-system"
            data-qa="theme_segment_system"
            phx-click="select_theme"
            phx-value-theme="system"
            class={[
              "flex items-center space-x-2 px-4 py-2 rounded-md text-sm font-medium transition-colors",
              @selected_theme == "system" && "bg-white text-zinc-900 shadow-xs font-semibold",
              @selected_theme != "system" && "text-zinc-500 hover:text-zinc-900 hover:bg-zinc-100"
            ]}
          >
            <.icon name="brightness_auto" class="h-4 w-4" />
            <span>System</span>
          </button>

          <button
            type="button"
            id="theme-segment-light"
            data-qa="theme_segment_light"
            phx-click="select_theme"
            phx-value-theme="light"
            class={[
              "flex items-center space-x-2 px-4 py-2 rounded-md text-sm font-medium transition-colors",
              @selected_theme == "light" && "bg-white text-zinc-900 shadow-xs font-semibold",
              @selected_theme != "light" && "text-zinc-500 hover:text-zinc-900 hover:bg-zinc-100"
            ]}
          >
            <.icon name="light_mode" class="h-4 w-4 text-amber-500" />
            <span>Light</span>
          </button>

          <button
            type="button"
            id="theme-segment-dark"
            data-qa="theme_segment_dark"
            phx-click="select_theme"
            phx-value-theme="dark"
            class={[
              "flex items-center space-x-2 px-4 py-2 rounded-md text-sm font-medium transition-colors",
              @selected_theme == "dark" && "bg-white text-zinc-900 shadow-xs font-semibold",
              @selected_theme != "dark" && "text-zinc-500 hover:text-zinc-900 hover:bg-zinc-100"
            ]}
          >
            <.icon name="dark_mode" class="h-4 w-4 text-indigo-500" />
            <span>Dark</span>
          </button>
        </div>
      </section>
    </div>
    """
  end

  def handle_event("select_theme", %{"theme" => theme}, socket) do
    valid_theme =
      case theme do
        "system" -> "system"
        "light" -> "light"
        _other -> "dark"
      end

    socket =
      socket
      |> assign(:selected_theme, valid_theme)
      |> assign(:theme, valid_theme)
      |> push_event("set_theme", %{theme: valid_theme})

    {:noreply, socket}
  end
end
