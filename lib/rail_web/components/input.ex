defmodule RailWeb.Components.Input do
  @moduledoc """
  Renders a form control with its label and error message.

  Modeled on Dishbooks' input: the bordered frame, label and errors live here, so
  every form reads the same. `class` goes on the control itself (fonts, resizing),
  `container_class` on the wrapper (spacing).

  ## Types

    * `"select"` renders `options` (anything `Phoenix.HTML.Form.options_for_select/2`
      takes) with `value` selected, and an optional disabled `prompt` first
    * `"textarea"` renders `value` as its content
    * `"hidden"` renders a bare hidden input
    * every other type renders an `<input>` of that type

  ## Examples

      <.input label="Display name" name="role[name]" id="role-name" value={@name} errors={@errors} />
      <.input type="select" label="Stage" name="role[stage]" id="role-stage" options={@stages} value={@stage} />
  """
  use RailWeb, :html

  @frame "rounded-lg border bg-white dark:bg-slate-950/60 shadow-xs focus-within:ring-1"
  @frame_ok "border-slate-200 dark:border-slate-700/80 focus-within:border-indigo-500 focus-within:ring-indigo-500"
  @frame_error "border-red-500 dark:border-red-500/80 focus-within:border-red-500 focus-within:ring-red-500"
  @control "block w-full border-0 bg-transparent p-0 text-slate-900 dark:text-slate-100 placeholder:text-slate-400 dark:placeholder:text-slate-500 focus:outline-none focus:ring-0"

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :size, :string, default: "large", values: ["small", "large"]

  attr :type, :string,
    default: "text",
    values: ["email", "hidden", "number", "password", "search", "select", "text", "textarea", "url"]

  attr :errors, :list, default: []
  attr :prompt, :string, default: nil, doc: "a disabled first option for select inputs"
  attr :options, :list, default: [], doc: "the options for select inputs"
  attr :class, :any, default: nil, doc: "classes for the control itself"
  attr :container_class, :any, default: nil, doc: "classes for the wrapper around label, control and errors"

  attr :rest, :global,
    include: [
      "autocomplete",
      "disabled",
      "max",
      "maxlength",
      "min",
      "placeholder",
      "readonly",
      "required",
      "rows",
      "step"
    ]

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(assigns) do
    assigns
    |> assign(:frame, [@frame, if(assigns.errors == [], do: @frame_ok, else: @frame_error)])
    |> assign(:padding, padding(assigns.size))
    |> assign(:control, @control)
    |> control()
  end

  defp control(%{type: "select"} = assigns) do
    ~H"""
    <div class={@container_class}>
      <.label id={@id} label={@label} />
      <div class={["relative", @frame]}>
        <select
          id={@id}
          name={@name}
          class={[@control, "cursor-pointer appearance-none bg-none pr-10", @padding, @class]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-error"}
          {@rest}
        >
          <option :if={@prompt} value="" disabled selected={@value in [nil, ""]}>{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
        <.icon
          name="pi-caret-down"
          class="pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400"
        />
      </div>
      <.errors id={@id} errors={@errors} />
    </div>
    """
  end

  defp control(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={@container_class}>
      <.label id={@id} label={@label} />
      <textarea
        id={@id}
        name={@name}
        class={[@frame, @control, "leading-6 focus:ring-1", @padding, @class]}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={@errors != [] && "#{@id}-error"}
        {@rest}
      >{@value}</textarea>
      <.errors id={@id} errors={@errors} />
    </div>
    """
  end

  defp control(assigns) do
    ~H"""
    <div class={@container_class}>
      <.label id={@id} label={@label} />
      <div class={@frame}>
        <input
          type={@type}
          id={@id}
          name={@name}
          value={@value}
          class={[@control, @padding, @class]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && "#{@id}-error"}
          {@rest}
        />
      </div>
      <.errors id={@id} errors={@errors} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, default: nil

  defp label(assigns) do
    ~H"""
    <label
      :if={@label}
      for={@id}
      class="mb-1.5 block text-sm font-medium text-slate-700 dark:text-slate-200"
    >
      {@label}
    </label>
    """
  end

  attr :id, :string, required: true
  attr :errors, :list, required: true

  defp errors(assigns) do
    ~H"""
    <p :if={@errors != []} id={"#{@id}-error"} class="mt-1.5 text-xs text-red-600 dark:text-red-400">
      {Enum.join(@errors, ", ")}
    </p>
    """
  end

  defp padding("small"), do: "px-2.5 py-1.5 text-sm leading-5"
  defp padding("large"), do: "px-3.5 py-2.5 text-[15px] leading-[22px]"
end
