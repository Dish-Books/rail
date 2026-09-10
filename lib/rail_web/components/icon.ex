defmodule RailWeb.Components.Icon do
  @moduledoc """
  Renders a [Phosphor Icon](https://phosphoricons.com).

  Phosphor icons come in multiple weights - thin, light, regular, bold, fill, duotone.
  Regular is the bare name; other weights carry a suffix, e.g. `pi-gear-fill`.

  Size and color come from the element itself: the icon is drawn as a CSS mask filled
  with `currentColor`, so width/height and text color classes control it.

  Icons are extracted from `assets/node_modules/@phosphor-icons/core/assets` and bundled
  into the compiled app.css by the plugin in `assets/vendor/phosphor-icons.js`.

  ## Examples

      <.icon name="pi-x" />
      <.icon name="pi-arrows-clockwise" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  use Phoenix.Component

  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :class, :any, default: "h-5 w-5"

  def icon(%{name: "pi-" <> _icon_name} = assigns) do
    ~H"""
    <span id={@id} class={["shrink-0", @name, @class]} aria-hidden="true" />
    """
  end
end
