defmodule RailWeb.Components.DemoPanel do
  @moduledoc """
  Component rendering the demo panel, criterion cards, and actions.
  Implements Spec 05 §9.2.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias Rail.Domain.Embeds.DemoSegment
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Components.DemoPlayerState

  attr :demo, :any, required: true
  attr :task, :any, required: true

  @doc "Renders the demo panel."
  def demo_panel(assigns) do
    demo = assigns.demo
    task = assigns.task

    outcome = demo |> demo_field(:outcome) |> to_string()
    version = demo_field(demo, :version) || 1
    commit = demo_field(demo, :commit)
    stale = stale?(demo)
    note = demo_field(demo, :note)
    segments = demo_field(demo, :segments) || []

    is_declined = outcome == "declined"
    shown_count = Enum.count(segments, fn s -> segment_outcome(s) == "recorded" end)
    criteria_count = length(segments)
    can_rerecord = can_rerecord?(task)
    can_play = not is_declined and segments != []

    assigns =
      assigns
      |> assign(:outcome, outcome)
      |> assign(:version, version)
      |> assign(:commit, commit)
      |> assign(:stale, stale)
      |> assign(:note, note)
      |> assign(:segments, segments)
      |> assign(:is_declined, is_declined)
      |> assign(:shown_count, shown_count)
      |> assign(:criteria_count, criteria_count)
      |> assign(:can_rerecord, can_rerecord)
      |> assign(:can_play, can_play)

    ~H"""
    <div
      id="demo-panel"
      data-qa="demo-panel demo_panel"
      class="p-4 rounded-xl bg-[var(--color-surface)] border border-[var(--color-border)] space-y-3"
    >
      <!-- Header Wrap -->
      <div
        class="flex items-center gap-2 flex-wrap"
        id="demo-panel-header"
        data-qa="demo_panel_header"
      >
        <!-- Title -->
        <h3
          id="demo-panel-title"
          data-qa="demo_panel_title"
          class="text-base font-bold text-[var(--color-on-surface)]"
        >
          {if @is_declined, do: "Demo declined", else: "Recorded demo"}
        </h3>

        <!-- Version Pill -->
        <span
          id="demo-version-pill"
          data-qa="demo_version_pill"
          class="bg-[var(--color-secondary-container)] text-[var(--color-on-secondary-container)] rounded-full px-2 py-0.5 text-xs font-bold"
        >
          {"v#{@version}"}
        </span>

        <!-- Recorded Count Pill (Omitted if declined) -->
        <span
          :if={not @is_declined}
          id="demo-recorded-count-pill"
          data-qa="demo_recorded_count_pill"
          class="bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface-variant)] rounded-full px-2 py-0.5 text-xs"
        >
          {"#{@shown_count}/#{@criteria_count} recorded"}
        </span>

        <!-- Commit Freshness Pill -->
        <span
          :if={is_binary(@commit) and @commit != ""}
          id="demo-commit-pill"
          data-qa="demo_commit_pill"
          class={[
            "rounded-full px-2 py-0.5 text-xs",
            @stale &&
              "bg-[var(--color-error-container)] text-[var(--color-on-error-container)] font-bold",
            not @stale &&
              "bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface-variant)]"
          ]}
        >
          {if @stale, do: "Out of date (#{@commit})", else: "Matches #{@commit}"}
        </span>

        <!-- Header Trailing Action Buttons -->
        <div class="ml-auto flex items-center gap-2">
          <!-- Play All Button -->
          <button
            :if={@can_play}
            type="button"
            id="demo-play-all-btn"
            data-qa="demo-play-button demo_play_all_btn"
            phx-click={if not @stale, do: "play_demo"}
            phx-value-segment="0"
            disabled={@stale}
            class={[
              "inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded-lg transition-colors",
              @stale &&
                "bg-[var(--color-surface-container-highest)] text-[var(--color-outline)] cursor-not-allowed opacity-60",
              not @stale &&
                "bg-[var(--color-primary)] text-[var(--color-on-primary)] hover:bg-[var(--color-primary)]/90 cursor-pointer shadow-xs"
            ]}
          >
            <.icon name="play_arrow" class="h-4 w-4 shrink-0" />
            <span>Play all</span>
          </button>

          <!-- Re-record Button -->
          <button
            :if={@can_rerecord}
            type="button"
            id="demo-rerecord-btn"
            data-qa="demo_rerecord_btn"
            phx-click="rerecord_demo"
            class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded-lg border border-[var(--color-outline)] text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-highest)] transition-colors cursor-pointer"
          >
            <.icon name="videocam_outlined" class="h-4 w-4 shrink-0" />
            <span>Re-record</span>
          </button>
        </div>
      </div>

      <!-- Declined Note Card -->
      <div
        :if={@is_declined and is_binary(@note) and @note != ""}
        id="demo-declined-card"
        data-qa="demo_declined_card"
        class="p-3 rounded-lg bg-[var(--color-surface-container-highest)] flex items-center gap-2 text-xs text-[var(--color-on-surface)]"
      >
        <.icon name="info_outline" class="h-4 w-4 shrink-0 text-[var(--color-outline)]" />
        <span class="font-medium">{"Demo declined: #{@note}"}</span>
      </div>

      <!-- Criterion Cards -->
      <div class="space-y-2 pt-1" id="demo-criteria-list" data-qa="demo_criteria_list">
        <%= for {segment, idx} <- Enum.with_index(@segments) do %>
          <% seg_outcome = segment_outcome(segment) %>
          <% criterion_idx = segment_field(segment, :criterion_index) || idx + 1 %>
          <% criterion_text = segment_field(segment, :criterion) %>
          <% seg_note = segment_field(segment, :note) %>
          <% frames = segment_frames(segment) %>
          <% duration_ms = segment_duration(segment) %>
          <% duration_str = format_duration(duration_ms) %>
          <% first_frame = List.first(frames) %>
          <% first_frame_url = if first_frame, do: DemoPlayerState.frame_url(first_frame), else: "" %>

          <div
            id={"demo-criterion-card-#{idx}"}
            data-qa="demo-card demo_criterion_card"
            class={[
              "p-3 rounded-xl border border-[var(--color-outline-variant)]/50 bg-[var(--color-surface)] flex items-start gap-3.5 transition-opacity",
              @stale && "opacity-50"
            ]}
          >
            <!-- Poster (120x75) -->
            <div
              class="w-[120px] h-[75px] rounded-lg bg-black/85 relative overflow-hidden shrink-0 flex items-center justify-center text-white"
              id={"demo-criterion-poster-#{idx}"}
            >
              <%= if seg_outcome == "recorded" and frames != [] do %>
                <!-- First Frame Image -->
                <img
                  :if={is_binary(first_frame_url) and first_frame_url != ""}
                  src={first_frame_url}
                  alt={criterion_text}
                  class="w-full h-full object-cover"
                  loading="lazy"
                />

                <!-- Play Button Overlay -->
                <button
                  type="button"
                  id={"demo-criterion-play-btn-#{idx}"}
                  data-qa="demo-play-button criterion_play_btn"
                  phx-click={if not @stale, do: "play_demo"}
                  phx-value-segment={idx}
                  disabled={@stale}
                  title={if @stale, do: "Demo is out of date", else: "Play segment"}
                  class={[
                    "absolute inset-0 flex items-center justify-center bg-black/30 hover:bg-black/40 transition-colors",
                    @stale && "cursor-not-allowed opacity-0 hover:opacity-0",
                    not @stale && "cursor-pointer"
                  ]}
                >
                  <span class="p-1 rounded-full bg-black/60 text-white flex items-center justify-center">
                    <.icon name="play_arrow" class="h-5 w-5" />
                  </span>
                </button>

                <!-- Duration Badge -->
                <span class="absolute bottom-1 right-1 px-1 py-0.5 bg-black/85 rounded text-[10px] font-bold text-white leading-none">
                  {duration_str}
                </span>
              <% else %>
                <!-- Non-recorded State Icons -->
                <%= if seg_outcome in ["not_filmable", "notFilmable"] do %>
                  <.icon name="visibility_off_outlined" class="h-7 w-7 text-white/55" />
                <% else %>
                  <.icon name="error_outline" class="h-7 w-7 text-white/55" />
                <% end %>
              <% end %>
            </div>

            <!-- Body Column -->
            <div class="flex-1 min-w-0 space-y-1">
              <!-- Criterion index & outcome badge -->
              <div class="flex items-center gap-2">
                <span class="text-xs font-bold text-[var(--color-outline)]">
                  {"Criterion #{criterion_idx}"}
                </span>

                <%= case seg_outcome do %>
                  <% "recorded" -> %>
                    <span class="bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] rounded-md px-1.5 py-0.5 text-xs font-bold">
                      Recorded
                    </span>
                  <% o when o in ["not_filmable", "notFilmable"] -> %>
                    <span class="bg-[var(--color-surface-container-highest)] text-[var(--color-on-surface-variant)] rounded-md px-1.5 py-0.5 text-xs font-bold">
                      Not filmable
                    </span>
                  <% _ -> %>
                    <span class="bg-[var(--color-error-container)] text-[var(--color-on-error-container)] rounded-md px-1.5 py-0.5 text-xs font-bold">
                      Failed
                    </span>
                <% end %>
              </div>

              <!-- Criterion Text -->
              <p class="text-sm font-medium text-[var(--color-on-surface)] leading-snug">
                {criterion_text}
              </p>

              <!-- Note -->
              <p
                :if={is_binary(seg_note) and seg_note != ""}
                class="text-xs text-[var(--color-outline)] leading-relaxed"
              >
                {seg_note}
              </p>

              <!-- Frames & duration subtext -->
              <p
                :if={seg_outcome == "recorded" and frames != []}
                class="text-xs text-[var(--color-outline)]"
              >
                {"#{length(frames)} frames • #{duration_str}"}
              </p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Private Helpers ---

  defp stale?(demo) do
    demo_field(demo, :stale) == true
  end

  defp segment_outcome(seg) do
    case segment_field(seg, :outcome) do
      outcome when is_atom(outcome) and outcome != nil -> Atom.to_string(outcome)
      outcome when is_binary(outcome) -> outcome
      _other -> "recorded"
    end
  end

  defp segment_frames(seg) do
    case segment_field(seg, :frames) do
      frames when is_list(frames) -> frames
      _other -> []
    end
  end

  defp segment_duration(%DemoSegment{} = seg), do: DemoSegment.duration_ms(seg)

  defp segment_duration(seg) when is_map(seg) do
    case segment_field(seg, :duration_ms) do
      ms when is_integer(ms) ->
        ms

      _other ->
        case segment_frames(seg) do
          [] -> 1000
          frames -> Enum.reduce(frames, 0, fn f, acc -> acc + DemoPlayerState.frame_hold_ms(f) end)
        end
    end
  end

  defp segment_duration(_other), do: nil

  defp format_duration(ms) when is_integer(ms) and ms >= 0 do
    "~.1f"
    |> :io_lib.format([ms / 1000.0])
    |> IO.iodata_to_binary()
    |> Kernel.<>("s")
  end

  defp format_duration(_other), do: "0.0s"

  defp can_rerecord?(%Task{} = task), do: Pipeline.can_rerecord_demo?(task)

  defp can_rerecord?(task) when is_map(task) do
    struct = struct(Task, task)
    Pipeline.can_rerecord_demo?(struct)
  end

  defp can_rerecord?(_other), do: false

  defp demo_field(demo, key) when is_map(demo) do
    Map.get(demo, key) || Map.get(demo, to_string(key))
  end

  defp demo_field(_other, _key), do: nil

  defp segment_field(seg, key) when is_map(seg) do
    Map.get(seg, key) || Map.get(seg, to_string(key))
  end

  defp segment_field(_other, _key), do: nil
end
