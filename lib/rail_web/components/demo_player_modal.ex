defmodule RailWeb.Components.DemoPlayerModal do
  @moduledoc """
  Modal overlay dialog rendering the demo player with frame container,
  scrubber bar, and transport controls. Implements Spec 05 §9.4 & §9.5.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias RailWeb.Components.DemoPlayerState

  attr :player, :any, required: true

  @doc "Renders the demo player modal dialog."
  def demo_player_modal(assigns) do
    player = assigns.player
    segments = player.segments || []
    current_segment = DemoPlayerState.current_segment(player)
    current_frame = DemoPlayerState.current_frame(player)
    total_ms = DemoPlayerState.total_segment_ms(player)
    caption = DemoPlayerState.frame_caption(current_frame)
    frame_url = DemoPlayerState.frame_url(current_frame)

    has_prev_seg = DemoPlayerState.has_prev_segment?(player)
    has_next_seg = DemoPlayerState.has_next_segment?(player)
    has_prev_f = DemoPlayerState.has_prev_frame?(player)
    has_next_f = DemoPlayerState.has_next_frame?(player)

    criterion_idx =
      if current_segment do
        segment_field(current_segment, :criterion_index) || player.segment_index + 1
      else
        1
      end

    criterion_text =
      if current_segment do
        segment_field(current_segment, :criterion) || ""
      else
        ""
      end

    assigns =
      assigns
      |> assign(:segments, segments)
      |> assign(:current_segment, current_segment)
      |> assign(:current_frame, current_frame)
      |> assign(:total_ms, total_ms)
      |> assign(:caption, caption)
      |> assign(:frame_url, frame_url)
      |> assign(:has_prev_seg, has_prev_seg)
      |> assign(:has_next_seg, has_next_seg)
      |> assign(:has_prev_f, has_prev_f)
      |> assign(:has_next_f, has_next_f)
      |> assign(:criterion_idx, criterion_idx)
      |> assign(:criterion_text, criterion_text)

    ~H"""
    <div
      id="demo-player-modal-backdrop"
      data-qa="demo_player_modal_backdrop"
      class="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4 backdrop-blur-xs"
    >
      <div
        id="demo-player-modal"
        data-qa="demo_player_modal"
        phx-hook="DemoPlayer"
        class="bg-[var(--color-surface)] rounded-2xl shadow-2xl flex flex-col overflow-hidden max-w-[960px] max-h-[720px] w-full h-[720px] border border-[var(--color-border)]"
      >
        <%= if @segments == [] do %>
          <!-- Empty State -->
          <div
            id="demo-player-empty-state"
            data-qa="demo_player_empty_state"
            class="p-8 flex flex-col items-center justify-center h-full gap-4 text-center"
          >
            <.icon name="videocam_off_outlined" class="h-12 w-12 text-[var(--color-outline)]" />
            <p class="text-sm font-semibold text-[var(--color-on-surface)]">
              No demo segments available.
            </p>
            <button
              type="button"
              id="demo-player-empty-close-btn"
              data-qa="demo_player_close_btn"
              phx-click="close_demo_player"
              class="px-4 py-2 rounded-lg bg-[var(--color-primary)] text-[var(--color-on-primary)] text-xs font-semibold hover:bg-[var(--color-primary)]/90 transition-colors cursor-pointer"
            >
              Close
            </button>
          </div>
        <% else %>
          <!-- Header (L20 T16 R12 B12) -->
          <div
            id="demo-player-header"
            data-qa="demo_player_header"
            class="pl-5 pt-4 pr-3 pb-3 flex items-center gap-3 border-b border-[var(--color-border)] shrink-0"
          >
            <.icon name="play_circle_outline" class="h-5 w-5 shrink-0 text-[var(--color-primary)]" />

            <div class="flex-1 min-w-0">
              <p
                id="demo-player-criterion-index"
                data-qa="demo_player_criterion_index"
                class="text-xs text-[var(--color-outline)] font-medium"
              >
                {"Criterion #{@criterion_idx} of #{length(@segments)}"}
              </p>
              <h3
                id="demo-player-criterion-text"
                data-qa="demo_player_criterion_text"
                class="text-sm font-bold text-[var(--color-on-surface)] line-clamp-2"
                title={@criterion_text}
              >
                {@criterion_text}
              </h3>
            </div>

            <button
              type="button"
              id="demo-player-close-btn"
              data-qa="demo_player_close_btn"
              phx-click="close_demo_player"
              title="Close"
              class="p-1.5 rounded-lg text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-highest)] transition-colors cursor-pointer"
            >
              <.icon name="close" class="h-5 w-5" />
            </button>
          </div>

          <!-- Frame Area -->
          <div
            id="demo-player-frame-area"
            data-qa="demo_player_frame_area"
            class="flex-1 bg-black relative flex items-center justify-center overflow-hidden min-h-0"
          >
            <%= if is_binary(@frame_url) and @frame_url != "" do %>
              <img
                id="demo-player-frame-img"
                data-qa="demo_player_frame_img"
                src={@frame_url}
                alt={@criterion_text}
                class="max-h-full max-w-full object-contain"
                loading="eager"
                onerror="this.classList.add('hidden'); if(this.nextElementSibling) this.nextElementSibling.classList.remove('hidden');"
              />
              <div class="hidden flex flex-col items-center justify-center gap-2 text-white/55">
                <.icon name="broken_image_outlined" class="h-12 w-12" />
                <span class="text-xs">Error loading frame</span>
              </div>
            <% else %>
              <div class="flex flex-col items-center justify-center gap-2 text-white/55">
                <.icon name="image_not_supported_outlined" class="h-12 w-12" />
              </div>
            <% end %>

            <!-- Caption Overlay -->
            <div
              :if={is_binary(@caption) and @caption != ""}
              id="demo-player-caption-overlay"
              data-qa="demo_player_caption_overlay"
              class="absolute bottom-4 left-4 right-4 bg-black/75 rounded-lg border border-white/25 px-4 py-2.5 text-center text-sm font-medium text-white shadow-lg pointer-events-none"
            >
              {@caption}
            </div>
          </div>

          <!-- Controls (L16 T8 R16 B12) -->
          <div
            id="demo-player-controls"
            data-qa="demo_player_controls"
            class="pl-4 pt-2 pr-4 pb-3 bg-[var(--color-surface)] border-t border-[var(--color-border)] space-y-2 shrink-0"
          >
            <!-- Scrubber Row -->
            <div class="flex items-center gap-3 text-xs text-[var(--color-on-surface-variant)]">
              <span id="demo-player-elapsed-text" class="w-10 font-mono">
                {format_duration(@player.elapsed_ms)}
              </span>

              <form
                id="demo-player-seek-form"
                data-qa="demo_player_seek_form"
                phx-change="player_seek"
                class="flex-1 flex items-center"
              >
                <input
                  type="range"
                  name="ms"
                  id="demo-player-slider"
                  data-qa="demo_player_slider"
                  min="0"
                  max={max(@total_ms, 1)}
                  value={@player.elapsed_ms}
                  class="w-full h-1.5 bg-[var(--color-surface-container-highest)] accent-[var(--color-primary)] rounded cursor-pointer"
                />
              </form>

              <span id="demo-player-total-text" class="w-10 text-right font-mono">
                {format_duration(@total_ms)}
              </span>
            </div>

            <!-- Transport Row -->
            <div class="flex items-center justify-center gap-2">
              <!-- Previous Criterion -->
              <button
                type="button"
                id="demo-player-prev-segment"
                data-qa="player_prev_segment"
                phx-click={if @has_prev_seg, do: "player_prev_segment"}
                disabled={not @has_prev_seg}
                title="Previous criterion"
                class={[
                  "p-2 rounded-full transition-colors",
                  @has_prev_seg &&
                    "text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-highest)] cursor-pointer",
                  not @has_prev_seg &&
                    "text-[var(--color-outline)]/40 cursor-not-allowed"
                ]}
              >
                <.icon name="skip_previous" class="h-5 w-5" />
              </button>

              <!-- Previous Frame -->
              <button
                type="button"
                id="demo-player-prev-frame"
                data-qa="player_prev_frame"
                phx-click={if @has_prev_f, do: "player_prev_frame"}
                disabled={not @has_prev_f}
                title="Previous frame"
                class={[
                  "p-2 rounded-full transition-colors",
                  @has_prev_f &&
                    "text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-highest)] cursor-pointer",
                  not @has_prev_f &&
                    "text-[var(--color-outline)]/40 cursor-not-allowed"
                ]}
              >
                <.icon name="fast_rewind" class="h-5 w-5" />
              </button>

              <!-- Play / Pause Circular Button -->
              <button
                type="button"
                id="demo-player-play-toggle"
                data-qa="player_toggle_play"
                data-playing={if @player.is_playing, do: "true", else: "false"}
                phx-click="player_toggle_play"
                title={if @player.is_playing, do: "Pause", else: "Play"}
                class="p-3 rounded-full bg-[var(--color-primary)] text-[var(--color-on-primary)] hover:bg-[var(--color-primary)]/90 transition-transform active:scale-95 cursor-pointer shadow-md mx-2"
              >
                <.icon
                  name={if @player.is_playing, do: "pause", else: "play_arrow"}
                  class="h-7 w-7"
                />
              </button>

              <!-- Next Frame -->
              <button
                type="button"
                id="demo-player-next-frame"
                data-qa="player_next_frame"
                phx-click={if @has_next_f, do: "player_next_frame"}
                disabled={not @has_next_f}
                title="Next frame"
                class={[
                  "p-2 rounded-full transition-colors",
                  @has_next_f &&
                    "text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-highest)] cursor-pointer",
                  not @has_next_f &&
                    "text-[var(--color-outline)]/40 cursor-not-allowed"
                ]}
              >
                <.icon name="fast_forward" class="h-5 w-5" />
              </button>

              <!-- Next Criterion -->
              <button
                type="button"
                id="demo-player-next-segment"
                data-qa="player_next_segment"
                phx-click={if @has_next_seg, do: "player_next_segment"}
                disabled={not @has_next_seg}
                title="Next criterion"
                class={[
                  "p-2 rounded-full transition-colors",
                  @has_next_seg &&
                    "text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-highest)] cursor-pointer",
                  not @has_next_seg &&
                    "text-[var(--color-outline)]/40 cursor-not-allowed"
                ]}
              >
                <.icon name="skip_next" class="h-5 w-5" />
              </button>

              <!-- Loop Toggle Button -->
              <button
                type="button"
                id="demo-player-loop-toggle"
                data-qa="player_toggle_loop"
                phx-click="player_toggle_loop"
                title={if @player.loop, do: "Looping on", else: "Looping off"}
                class={[
                  "p-2 rounded-full transition-colors ml-4",
                  @player.loop &&
                    "text-[var(--color-primary)] bg-[var(--color-primary)]/10 hover:bg-[var(--color-primary)]/20 cursor-pointer",
                  not @player.loop &&
                    "text-[var(--color-outline)] hover:bg-[var(--color-surface-container-highest)] cursor-pointer"
                ]}
              >
                <.icon name="repeat" class="h-5 w-5" />
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Private Helpers ---

  defp segment_field(seg, key) when is_map(seg) do
    Map.get(seg, key) || Map.get(seg, to_string(key))
  end

  defp segment_field(_other, _key), do: nil

  defp format_duration(ms) when is_integer(ms) and ms >= 0 do
    "~.1f"
    |> :io_lib.format([ms / 1000.0])
    |> IO.iodata_to_binary()
    |> Kernel.<>("s")
  end

  defp format_duration(_other), do: "0.0s"
end
