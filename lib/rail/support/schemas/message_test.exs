defmodule Rail.Support.Schemas.MessageTest do
  use Rail.DataCase, async: true

  alias Rail.Support.Schemas.Message
  alias Rail.Support.Schemas.Message.Attachment

  test "a customer's part becomes a row with its text, author, time and attachments" do
    part = %{
      "id" => 501,
      "created_at" => 1_790_000_000,
      "author" => %{"type" => "user", "name" => "Marta Kowalczyk"},
      "body" => "<p>Hi there</p><p>See <b>this</b>:</p><img src=\"https://downloads.intercomcdn.com/i/shot.png?x=1\">",
      "attachments" => [
        %{
          "url" => "https://downloads.intercomcdn.com/r.pdf",
          "name" => "r.pdf",
          "content_type" => "application/pdf",
          "filesize" => 188_416
        },
        %{"name" => "no address"}
      ]
    }

    assert %{
             external_id: "501",
             kind: :customer,
             author_name: "Marta Kowalczyk",
             text: "Hi there\n\nSee this:",
             posted_at: ~U[2026-09-21 14:13:20.000000Z],
             attachments: [
               %Attachment{
                 name: "shot.png",
                 url: "https://downloads.intercomcdn.com/i/shot.png?x=1",
                 content_type: "image/*"
               },
               %Attachment{name: "r.pdf", content_type: "application/pdf", size: 188_416}
             ]
           } = Message.build_attrs(part, "comment")
  end

  test "keeps only https images and files" do
    part = %{
      "id" => 9,
      "created_at" => 1_790_000_000,
      "author" => %{"type" => "user", "name" => "Marta"},
      "body" =>
        ~s(<p>See</p><img src="http://x.example/a.png"><img src="data:image/png;base64,AA"><img src="https://downloads.intercomcdn.com/i/b.png">),
      "attachments" => [
        %{"url" => "javascript:alert(1)", "name" => "x"},
        %{"url" => "https://downloads.intercomcdn.com/r.pdf", "name" => "r.pdf"}
      ]
    }

    assert %{
             attachments: [
               %Attachment{url: "https://downloads.intercomcdn.com/i/b.png"},
               %Attachment{name: "r.pdf"}
             ]
           } = Message.build_attrs(part, "comment")
  end

  test "a screenshot both inline and listed as an attachment is kept once, as the listed file" do
    part = %{
      "id" => 503,
      "created_at" => 1,
      "author" => %{"type" => "user", "name" => "Marta"},
      "body" =>
        ~s(<p>Look</p><img src="https://downloads.intercomcdn.com/i/o/ws/28/ab/image.png?expires=1&signature=a&req=x"><img src="https://downloads.intercomcdn.com/i/o/ws/29/cd/other.png?req=y">),
      "attachments" => [
        %{
          "url" => "https://acme.intercom-attachments-3.com/i/o/ws/28/ab/image.png?expires=2&signature=b&req=z",
          "name" => "image.png",
          "content_type" => "image/png",
          "filesize" => 28_889
        }
      ]
    }

    assert %{
             attachments: [
               %Attachment{name: "other.png", content_type: "image/*"},
               %Attachment{
                 name: "image.png",
                 url: "https://acme.intercom-attachments-3.com/i/o/ws/28/ab/image.png?expires=2&signature=b&req=z",
                 content_type: "image/png",
                 size: 28_889
               }
             ]
           } = Message.build_attrs(part, "comment")
  end

  test "an author with no name is named by email, then by kind" do
    assert %{author_name: "v@example.com", kind: :customer} =
             Message.build_attrs(
               %{
                 "id" => 1,
                 "created_at" => 1,
                 "body" => "hello",
                 "author" => %{"type" => "lead", "name" => " ", "email" => "v@example.com"}
               },
               "source"
             )

    assert %{author_name: "Customer"} =
             Message.build_attrs(
               %{"id" => 1, "created_at" => 1, "body" => "hi", "author" => %{"type" => "contact"}},
               "source"
             )

    assert %{author_name: "Bot", kind: :bot} =
             Message.build_attrs(%{"id" => 1, "created_at" => 1, "body" => "hi"}, "comment")

    assert %{author_name: "Teammate", kind: :note} =
             Message.build_attrs(
               %{"id" => 1, "created_at" => 1, "body" => "hi", "author" => %{"type" => "admin"}},
               "note"
             )
  end

  test "a part with nothing to show, or not shaped as a part, is nil" do
    assert nil ==
             Message.build_attrs(
               %{"id" => 1, "created_at" => 1, "body" => nil, "author" => %{"type" => "admin"}},
               "assignment"
             )

    assert nil == Message.build_attrs(%{"id" => 1, "created_at" => 1, "body" => "<p> </p>"}, "comment")
    assert nil == Message.build_attrs(%{"id" => 1}, "comment")
    assert nil == Message.build_attrs(nil, "source")
  end

  test "plain text with no blocks keeps its text, and odd markup does not crash" do
    assert %{text: "just words"} = Message.build_attrs(%{"id" => 1, "created_at" => 1, "body" => "just words"}, "comment")

    assert %{text: "a < b"} =
             Message.build_attrs(%{"id" => 1, "created_at" => 1, "body" => "<p>a < b</p><div"}, "comment")
  end

  test "a line break or list item is a new line, and a nested block is read once" do
    body = "<p>one<br>two</p><ul><li>a</li><li>b</li></ul><blockquote><p>quoted</p></blockquote><!-- c -->"

    assert %{text: "one\ntwo\n\na\nb\n\nquoted"} =
             Message.build_attrs(%{"id" => 1, "created_at" => 1, "body" => body}, "comment")
  end

  test "authors read as customer, note, teammate or bot" do
    assert :customer = Message.calculate_kind("user", "comment")
    assert :note = Message.calculate_kind("admin", "note")
    assert :teammate = Message.calculate_kind("admin", "comment")
    assert :teammate = Message.calculate_kind("team", "comment")
    assert :bot = Message.calculate_kind("bot", "comment")
    assert :bot = Message.calculate_kind("something_new", "comment")
    assert [:customer, :teammate, :bot, :note] = Message.kinds()
  end

  test "an attachment is an image by its content type" do
    assert Message.image?(%Attachment{content_type: "image/png"})
    refute Message.image?(%Attachment{content_type: "application/pdf"})
    refute Message.image?(%Attachment{content_type: nil})
  end

  test "initials come from the first two names, or a question mark" do
    assert "MK" = Message.initials(%Message{author_name: "marta kowalczyk smith"})
    assert "?" = Message.initials(%Message{author_name: ""})
    assert "?" = Message.initials(%Message{author_name: nil})
  end
end
