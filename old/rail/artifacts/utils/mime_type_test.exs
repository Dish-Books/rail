defmodule Rail.Artifacts.Utils.MimeTypeTest do
  use ExUnit.Case, async: true

  import Rail.Artifacts.Utils.MimeType

  describe "mime_type/1" do
    test "correctly infers MIME content types" do
      assert mime_type("image.png") == "image/png"
      assert mime_type("https://example.com/assets/photo.jpg") == "image/jpeg"
      assert mime_type("photo.jpeg") == "image/jpeg"
      assert mime_type("graphic.webp") == "image/webp"
      assert mime_type("animation.gif") == "image/gif"
      assert mime_type("document.pdf") == "application/octet-stream"
      assert mime_type(nil) == "application/octet-stream"
    end
  end
end
