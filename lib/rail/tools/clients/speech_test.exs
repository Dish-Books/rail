defmodule Rail.Tools.Clients.SpeechTest do
  use Rail.DataCase, async: true

  alias Rail.Tools.Clients.Speech

  @audio %{"inlineData" => %{"mimeType" => "audio/L16;codec=pcm;rate=24000", "data" => Base.encode64("pcm bytes")}}

  setup do
    stub(Rail, :goth_enabled?, fn -> true end)
    stub(Goth, :fetch, fn Rail.Goth -> {:ok, %Goth.Token{token: "test_token"}} end)
    stub(Goth.Config, :get, fn :project_id -> {:ok, "rail-testing"} end)
    :ok
  end

  test "speaks the line at the global endpoint under Goth's project, on its token, as raw PCM" do
    Req.Test.expect(Speech, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path ==
               "/v1/projects/rail-testing/locations/global/publishers/google/models/gemini-3.8-flash-tts:generateContent"

      assert ["Bearer test_token"] = Plug.Conn.get_req_header(conn, "authorization")

      assert %{
               "contents" => [%{"parts" => [%{"text" => text}]}],
               "generationConfig" => %{"responseModalities" => ["AUDIO"], "speechConfig" => %{"voiceConfig" => _voice}}
             } = Jason.decode!(body)

      assert text =~ "Saved exactly as entered."
      Req.Test.json(conn, %{"candidates" => [%{"content" => %{"parts" => [@audio]}}]})
    end)

    assert {:ok, "pcm bytes"} = Speech.synthesize("Saved exactly as entered.")
    assert Speech.rate() == 24_000
  end

  test "an answer with no audio, audio of another format, or an error status is an error" do
    Req.Test.stub(Speech, &Req.Test.json(&1, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}]}))
    assert {:error, :no_audio} = Speech.synthesize("Line.")

    wav = %{"inlineData" => %{"mimeType" => "audio/wav", "data" => ""}}
    Req.Test.stub(Speech, &Req.Test.json(&1, %{"candidates" => [%{"content" => %{"parts" => [wav]}}]}))
    assert {:error, {:unexpected_audio, "audio/wav"}} = Speech.synthesize("Line.")

    Req.Test.stub(Speech, &Plug.Conn.send_resp(&1, 429, "slow down"))
    assert {:error, {:speech_error, 429, "slow down"}} = Speech.synthesize("Line.")

    Req.Test.stub(Speech, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Speech.synthesize("Line.")
  end

  test "with Goth off, failing, or with no project it returns an error and sends nothing" do
    Req.Test.stub(Speech, fn _conn -> flunk("a request was sent without a token") end)

    stub(Goth, :fetch, fn Rail.Goth -> exit(:timeout) end)
    assert {:error, {:goth_unavailable, :timeout}} = Speech.synthesize("Line.")

    stub(Goth, :fetch, fn Rail.Goth -> {:error, :refused} end)
    assert {:error, {:goth_unavailable, :refused}} = Speech.synthesize("Line.")

    stub(Goth, :fetch, fn Rail.Goth -> {:ok, %Goth.Token{token: "test_token"}} end)
    stub(Goth.Config, :get, fn :project_id -> :error end)
    assert {:error, :no_project_id} = Speech.synthesize("Line.")

    stub(Goth.Config, :get, fn :project_id -> raise "no credentials" end)
    assert {:error, {:goth_unavailable, %RuntimeError{}}} = Speech.synthesize("Line.")

    stub(Rail, :goth_enabled?, fn -> false end)
    assert {:error, :goth_disabled} = Speech.synthesize("Line.")
  end
end
