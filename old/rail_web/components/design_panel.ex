defmodule RailWeb.Components.DesignPanel do
  @moduledoc """
  Component rendering design directions explored by the designer.
  Implements Spec 05 §10: shows all directions or only the picked direction,
  stills with 16:10 aspect ratio and cache-busting, canvas link, and version pill.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.Embeds.DesignDirection

  attr :design, :any, required: true

  @doc "Renders the design panel."
  def design_panel(assigns) do
    design = assigns.design
    shown_directions = resolve_shown_directions(design)
    picked_key = design_field(design, :picked_key)
    version = design_field(design, :version) || 1
    canvas_url = design_field(design, :canvas_url)

    assigns =
      assigns
      |> assign(:shown_directions, shown_directions)
      |> assign(:picked_key, picked_key)
      |> assign(:version, version)
      |> assign(:canvas_url, canvas_url)

    ~H"""
    <div
      id="design-panel"
      data-qa="design-panel design_panel"
      class="p-4 rounded-xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 space-y-3"
    >
      <!-- Header Row -->
      <div class="flex items-center gap-2 flex-wrap" id="design-panel-header">
        <h3
          id="design-panel-title"
          data-qa="design_panel_title"
          class="text-base font-bold text-slate-900 dark:text-slate-100"
        >
          Design directions
        </h3>

        <span
          id="design-version-pill"
          data-qa="design_version_pill"
          class="bg-slate-100 dark:bg-slate-700 text-slate-800 dark:text-slate-200 rounded-full px-2 py-0.5 text-xs font-bold"
        >
          {"v#{@version}"}
        </span>

        <a
          :if={is_binary(@canvas_url) and @canvas_url != ""}
          id="design-canvas-link"
          data-qa="design_canvas_link"
          href={@canvas_url}
          target="_blank"
          rel="noopener noreferrer"
          class="ml-auto inline-flex items-center gap-1 text-xs text-blue-600 dark:text-blue-500 hover:underline truncate max-w-md"
        >
          <.icon name="pi-arrow-square-out" class="h-3.5 w-3.5 shrink-0" />
          <span class="truncate underline">{@canvas_url}</span>
        </a>
      </div>

      <!-- Direction Cards Wrap -->
      <div class="flex flex-wrap gap-4" id="design-directions-wrap" data-qa="design_directions_wrap">
        <%= for dir <- @shown_directions do %>
          <% key = direction_field(dir, :key) %>
          <% title = direction_field(dir, :title) %>
          <% notes = direction_field(dir, :notes) %>
          <% is_picked = is_binary(@picked_key) and @picked_key != "" and key == @picked_key %>
          <% img_url = direction_image_url(dir, @version) %>

          <div
            id={"design-direction-card-#{key}"}
            data-qa="design-card design_direction_card"
            data-picked={if is_picked, do: "true", else: "false"}
            class={[
              "min-w-[260px] max-w-[340px] flex-1 rounded-xl overflow-hidden bg-white dark:bg-slate-900 p-3 flex flex-col gap-3",
              is_picked && "border-2 border-blue-600 dark:border-blue-500 shadow-sm",
              not is_picked && "border border-slate-300 dark:border-slate-600"
            ]}
          >
            <!-- Still Container (16/10 Aspect Ratio) -->
            <div
              class="w-full aspect-[16/10] rounded-lg overflow-hidden bg-slate-200 dark:bg-slate-600 relative flex items-center justify-center"
              id={"design-still-wrap-#{key}"}
            >
              <%= if is_binary(img_url) and img_url != "" do %>
                <img
                  id={"design-still-img-#{key}"}
                  data-qa="design_still_img"
                  src={img_url}
                  alt={title}
                  class="w-full h-full object-cover"
                  loading="lazy"
                  onerror="this.classList.add('hidden'); if(this.nextElementSibling) this.nextElementSibling.classList.remove('hidden');"
                />
                <div class="hidden flex flex-col items-center justify-center w-full h-full text-slate-500 dark:text-slate-400">
                  <.icon name="pi-image-broken" class="h-8 w-8 shrink-0" />
                </div>
              <% else %>
                <div class="flex flex-col items-center justify-center w-full h-full text-slate-500 dark:text-slate-400">
                  <.icon name="pi-image-broken" class="h-8 w-8 shrink-0" />
                </div>
              <% end %>
            </div>

            <!-- Title & Picked Badge -->
            <div class="flex items-center gap-2">
              <h4
                id={"design-direction-title-#{key}"}
                data-qa="design_direction_title"
                class="text-sm font-bold text-slate-900 dark:text-slate-100 flex-1 truncate"
                title={title}
              >
                {title}
              </h4>

              <span
                :if={is_picked}
                id={"design-direction-picked-#{key}"}
                data-qa="design_direction_picked"
                class="bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 rounded-md px-1.5 py-0.5 text-xs font-bold shrink-0"
              >
                Picked
              </span>
            </div>

            <!-- Notes -->
            <p
              :if={is_binary(notes) and notes != ""}
              id={"design-direction-notes-#{key}"}
              data-qa="design_direction_notes"
              class="text-xs text-slate-600 dark:text-slate-300 leading-relaxed whitespace-pre-wrap"
            >
              {notes}
            </p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Private Helpers ---

  defp resolve_shown_directions(nil), do: []

  defp resolve_shown_directions(design) do
    directions = design_field(design, :directions) || []
    picked_key = design_field(design, :picked_key)

    if is_binary(picked_key) and picked_key != "" do
      case Enum.find(directions, fn d -> direction_field(d, :key) == picked_key end) do
        %{} = picked -> [picked]
        nil -> directions
      end
    else
      directions
    end
  end

  defp direction_image_url(direction, version) do
    base =
      cond do
        is_binary(direction_field(direction, :linear_asset_id)) and
            direction_field(direction, :linear_asset_id) != "" ->
          Rail.Artifacts.asset_url(:design, direction_field(direction, :linear_asset_id))

        is_binary(direction_field(direction, :still_url)) and
            direction_field(direction, :still_url) != "" ->
          direction_field(direction, :still_url)

        true ->
          ""
      end

    if base == "" do
      ""
    else
      sep = if String.contains?(base, "?"), do: "&", else: "?"
      "#{base}#{sep}v=#{version || 1}"
    end
  end

  defp design_field(%Design{} = design, key), do: Map.get(design, key)

  defp design_field(design, key) when is_map(design) do
    Map.get(design, key) || Map.get(design, to_string(key))
  end

  defp design_field(_other, _key), do: nil

  defp direction_field(%DesignDirection{} = dir, key), do: Map.get(dir, key)

  defp direction_field(dir, key) when is_map(dir) do
    Map.get(dir, key) || Map.get(dir, to_string(key))
  end

  defp direction_field(_other, _key), do: nil
end
