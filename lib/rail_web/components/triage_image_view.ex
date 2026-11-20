defmodule RailWeb.Components.TriageImageView do
  @moduledoc """
  A triage image enlarged over the page, with Previous and Next through the other images of the same message.
  """
  use RailWeb, :html

  alias Phoenix.LiveView.JS
  alias Rail.Triage.Schemas.Message.Image

  attr :message_id, :string, required: true
  attr :image, Image, required: true
  attr :position, :integer, required: true
  attr :count, :integer, required: true

  def triage_image_view(assigns) do
    assigns =
      assigns
      |> assign(:src, ~p"/triage/messages/#{assigns.message_id}/images/#{assigns.image.external_id}")
      # The server re-renders this after every step, so closing focuses the tile of the image on screen.
      |> assign(
        :close,
        JS.push(JS.focus(to: "#triage-image-open-#{assigns.message_id}-#{assigns.image.external_id}"), "close_image")
      )

    ~H"""
    <.image_view
      prefix="triage"
      key={@image.external_id}
      name={@image.name}
      src={@src}
      close={@close}
      position={@position}
      count={@count}
    />
    """
  end
end
