defmodule RailWeb.Components.LocalTime do
  @moduledoc """
  A moment shown in the viewer's own clock, with a short date when it was not
  today, through the `LocalTime` hook. The server renders UTC until it runs.
  """
  use RailWeb, :html

  attr :id, :string, required: true
  attr :at, DateTime, required: true
  attr :class, :any, default: nil

  def local_time(assigns) do
    ~H"""
    <time
      id={@id}
      phx-hook="LocalTime"
      datetime={DateTime.to_iso8601(@at)}
      data-at={DateTime.to_iso8601(@at)}
      data-format="date-time"
      class={@class}
    >{Calendar.strftime(@at, "%b %-d, %-I:%M %p UTC")}</time>
    """
  end
end
