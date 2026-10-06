defmodule RailWeb.Components.ChildSwitcher do
  @moduledoc """
  The row above a child's title: a menu of every child of its split with where each stands, the
  previous and next child, and how many of the others need a person.
  """
  use RailWeb, :html

  # Each entry is `RailWeb.Utils.ChildStatus.child_status/2` for one child, in order.
  attr :statuses, :list, required: true
  attr :current_id, :string, required: true
  attr :parent, :any, required: true

  def child_switcher(assigns) do
    index = Enum.find_index(assigns.statuses, &(&1.task.id == assigns.current_id))
    current = Enum.at(assigns.statuses, index)

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:position, index + 1)
      |> assign(:previous, if(index > 0, do: Enum.at(assigns.statuses, index - 1)))
      |> assign(:next, Enum.at(assigns.statuses, index + 1))
      |> assign(:others_waiting, Enum.count(assigns.statuses, &(&1.needs_attention and &1.task.id != assigns.current_id)))

    ~H"""
    <div id="child-switcher" data-qa="child-switcher" class="flex items-center gap-2 text-sm min-w-0">
      <div
        class="relative"
        phx-click-away={JS.hide(to: "#child-switcher-menu")}
        phx-window-keydown={JS.hide(to: "#child-switcher-menu")}
        phx-key="Escape"
      >
        <button
          type="button"
          id="child-switcher-button"
          phx-click={JS.toggle(to: "#child-switcher-menu")}
          class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border border-slate-300 dark:border-slate-600 bg-slate-100 dark:bg-slate-700 text-xs font-medium text-slate-900 dark:text-slate-100 cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500"
        >
          <span class="font-mono">{@current.identifier}</span>
          <span class="text-slate-500 dark:text-slate-400">{@position} of {length(@statuses)}</span>
          <.icon name="pi-caret-up-down" class="size-3.5 text-slate-500" />
        </button>

        <div
          id="child-switcher-menu"
          class="hidden absolute left-0 top-full mt-2 w-[440px] max-w-[calc(100vw-2rem)] rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800 p-1.5 shadow-xl z-50"
        >
          <.link
            phx-click={pick(~p"/tasks/#{@parent.id}?tab=children")}
            id="child-switcher-all"
            class="flex items-center gap-2.5 px-2.5 py-2 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-700 text-[13px] font-semibold text-slate-700 dark:text-slate-200"
          >
            <.icon name="pi-squares-four" class="size-[15px] text-slate-400" />
            All children of {@parent.issue.identifier}
          </.link>
          <div class="h-px my-1 bg-slate-200 dark:bg-slate-700" />
          <.link
            :for={status <- @statuses}
            phx-click={pick(~p"/tasks/#{@parent.id}?child=#{status.identifier}")}
            id={"child-switcher-#{status.identifier}"}
            data-qa="child-switcher-item"
            aria-current={to_string(status.task.id == @current_id)}
            class={[
              "flex items-center gap-2.5 px-2.5 py-2 rounded-lg",
              status.task.id == @current_id && "bg-blue-100 dark:bg-blue-900",
              status.task.id != @current_id && "hover:bg-slate-100 dark:hover:bg-slate-700"
            ]}
          >
            <.icon name={status.icon} class={["size-[15px]", status.text_class]} />
            <span class="font-mono text-[11.5px] text-slate-500 dark:text-slate-400 shrink-0">
              {status.identifier}
            </span>
            <span class="min-w-0 flex-1">
              <span class="block truncate text-[13px] font-medium text-slate-900 dark:text-slate-100">
                {status.task.issue.title}
              </span>
              <span class={["block truncate text-[11.5px]", status.text_class]}>{status.label}</span>
            </span>
            <span
              :if={is_integer(status.badge)}
              aria-label={"#{status.badge} waiting on you"}
              class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1.5 rounded-full text-[11px] font-semibold bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200"
            >
              {status.badge}
            </span>
            <span
              :if={status.badge == :dot}
              aria-label="Waiting on you"
              class="size-2 shrink-0 rounded-full bg-amber-500"
            />
          </.link>
        </div>
      </div>

      <.step
        to={@previous && ~p"/tasks/#{@parent.id}?child=#{@previous.identifier}"}
        id="child-previous"
        label="Previous child"
        icon="pi-caret-left"
      />
      <.step
        to={@next && ~p"/tasks/#{@parent.id}?child=#{@next.identifier}"}
        id="child-next"
        label="Next child"
        icon="pi-caret-right"
        class="-ml-1.5"
      />

      <span
        :if={@others_waiting > 0}
        id="child-switcher-waiting"
        class="ml-auto text-xs text-amber-700 dark:text-amber-300 shrink-0"
      >
        {@others_waiting} other {if @others_waiting == 1, do: "child needs", else: "children need"} you
      </span>
    </div>
    """
  end

  # A patch keeps what JS did to the page, so the menu is closed on the way.
  defp pick(path), do: [to: "#child-switcher-menu"] |> JS.hide() |> JS.patch(path)

  attr :to, :string, default: nil
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :class, :string, default: nil

  # The first child has no previous one and the last no next, so those ends read as disabled.
  defp step(assigns) do
    ~H"""
    <.link
      :if={@to}
      patch={@to}
      id={@id}
      aria-label={@label}
      class={[
        "size-7 rounded-md flex items-center justify-center text-slate-500 hover:bg-slate-200 dark:hover:bg-slate-700",
        @class
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
    </.link>
    <span
      :if={!@to}
      id={@id}
      aria-label={@label}
      aria-disabled="true"
      class={[
        "size-7 rounded-md flex items-center justify-center text-slate-300 dark:text-slate-600",
        @class
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
    </span>
    """
  end
end
