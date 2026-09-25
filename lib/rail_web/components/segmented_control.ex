defmodule RailWeb.Components.SegmentedControl do
  @moduledoc """
  A row of buttons where exactly one option is pressed, for switching a view.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :options, :list, required: true, doc: "`{value, label}` pairs, in the order they are drawn"
  attr :selected, :any, required: true
  attr :event, :string, required: true
  attr :value_name, :string, required: true, doc: "the `phx-value-*` the chosen value is sent as"
  attr :target, :any, default: nil
  attr :option_id, :string, default: nil, doc: "prefix for each option's id, when it is not the control's own"
  attr :option_qa, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def segmented_control(assigns) do
    ~H"""
    <div
      id={@id}
      class={["inline-flex rounded-lg bg-slate-100 dark:bg-slate-800 p-0.5", @class]}
      {@rest}
    >
      <button
        :for={{value, label} <- @options}
        type="button"
        id={"#{@option_id || @id}-#{value}"}
        data-qa={@option_qa}
        phx-click={@event}
        phx-target={@target}
        aria-pressed={to_string(@selected == value)}
        class={[
          "px-3 py-1 rounded-md text-xs font-semibold cursor-pointer",
          @selected == value &&
            "bg-white dark:bg-slate-700 text-slate-900 dark:text-slate-100 shadow-xs",
          @selected != value &&
            "text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
        ]}
        {[{"phx-value-#{@value_name}", value}]}
      >
        {label}
      </button>
    </div>
    """
  end
end
