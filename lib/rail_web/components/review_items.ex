defmodule RailWeb.Components.ReviewItems do
  @moduledoc """
  Review's slim rail: Findings, Demo and Browser, each an icon over a short label, the picked one filled
  blue. Each item's state is its hover title and its screen-reader text; Findings carries the amber count
  still to rule, and a dot marks anything running, red while recording. Under 576px of main column it is
  one row across the top.
  """
  use RailWeb, :html

  attr :items, :list,
    required: true,
    doc: "`%{key:, label:, icon:, picked_icon:, state:, badge:, dot:, mark:}`, `dot` `:running`, `:recording` or nil"

  attr :picked, :atom, required: true
  attr :target, :any, required: true

  def review_items(assigns) do
    ~H"""
    <nav
      id="review-items"
      aria-label="Review"
      class="shrink-0 flex @xl:flex-col gap-1 p-1.5 @xl:w-[76px] border-b @xl:border-b-0 @xl:border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30"
    >
      <button
        :for={item <- @items}
        type="button"
        id={"review-item-#{item.key}"}
        data-qa="review_item"
        aria-current={to_string(item.key == @picked)}
        title={"#{item.label}: #{item.state}"}
        phx-click="pick_item"
        phx-value-item={item.key}
        phx-target={@target}
        class={[
          "flex-1 @xl:flex-none min-w-0 flex flex-col items-center gap-1 px-1 py-2 rounded-lg cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
          item.key == @picked &&
            "bg-blue-50 dark:bg-blue-950/40 ring-1 ring-blue-200 dark:ring-blue-800 text-blue-800 dark:text-blue-200",
          item.key != @picked &&
            "text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800/60"
        ]}
      >
        <span class="relative">
          <.icon name={if item.key == @picked, do: item.picked_icon, else: item.icon} class="size-5" />
          <span
            :if={item.badge}
            data-qa="review_item_badge"
            class="absolute -top-1.5 -right-2.5 inline-flex items-center justify-center min-w-[1.1rem] h-[1.1rem] px-1 rounded-full text-[10px] font-bold bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200 ring-2 ring-slate-50 dark:ring-slate-900"
          >
            {item.badge}
          </span>
          <span
            :if={item.dot && !item.badge}
            data-qa={"review_item_#{item.dot}"}
            class="absolute -top-0.5 -right-1 flex size-2.5"
          >
            <span class={[
              "absolute inline-flex size-full rounded-full opacity-75 motion-safe:animate-ping",
              item.dot == :recording && "bg-red-400",
              item.dot == :running && "bg-blue-400"
            ]} />
            <span class={[
              "relative inline-flex size-2.5 rounded-full ring-2 ring-slate-50 dark:ring-slate-900",
              item.dot == :recording && "bg-red-500",
              item.dot == :running && "bg-blue-500"
            ]} />
          </span>
          <span
            :if={item.mark && !item.dot && !item.badge}
            data-qa={"review_item_#{item.mark}"}
            class="absolute -top-1 -right-1.5 grid place-items-center size-3.5 rounded-full bg-slate-50 dark:bg-slate-900"
          >
            <.icon
              :if={item.mark == :done}
              name="pi-check-circle-fill"
              class="size-3.5 text-emerald-500"
            />
            <.icon
              :if={item.mark == :failed}
              name="pi-warning-circle-fill"
              class="size-3.5 text-red-500"
            />
          </span>
        </span>
        <span class={[
          "max-w-full truncate text-[11px]",
          item.key == @picked && "font-bold",
          item.key != @picked && "font-semibold"
        ]}>
          {item.label}
        </span>
        <span class="sr-only">{item.state}</span>
      </button>
    </nav>
    """
  end
end
